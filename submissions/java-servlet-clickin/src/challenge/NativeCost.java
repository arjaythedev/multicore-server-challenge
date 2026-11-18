package challenge;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.concurrent.CyclicBarrier;

/**
 * The bcrypt cost loop (2^cost rounds of the key and salt expansions, nearly
 * all of a hash) in native/, called through FFM: generated x86-64 assembly
 * (tools/gen-bcrypt-x86.py) or, without BMI2 or on another architecture, C.
 * C2 can't keep six interleaved Blowfish lanes in registers the way hand
 * scheduled code does (EPYC: 21.8 ms/hash for the best Java kernel, 11.7 ms
 * in C). Java keeps the password encoding, salted expansion, final encryption
 * and formatting; only the expanded integer state crosses over, and is wiped
 * after every call. Per-worker scratch: an instance must not be used
 * concurrently.
 */
final class NativeCost {
    /** The kernels native/bcrypt_cost.c can run, by its style number. */
    enum Kernel {
        C(0),
        AH(1),
        BEXTR(2),
        SHRX(3);

        final int style;

        Kernel(int style) {
            this.style = style;
        }
    }

    private static final int STATE_WORDS = 1042;
    private static final int INPUT_WORDS = 22;
    private static final long WORD_BYTES = Integer.BYTES;
    private static final MethodHandle[] HANDLES = bind();
    private static final MethodHandle COST = HANDLES == null ? null : HANDLES[0];
    /** False when build.sh could not build the library: BCrypt runs its Java kernels. */
    static final boolean AVAILABLE = COST != null;
    private static final int SUPPORTED = supported();
    // the C kernel until calibrate() has timed the others on this box
    private static volatile Kernel kernel = Kernel.C;

    private static MethodHandle[] bind() {
        Path path = Path.of(System.getProperty("bcrypt.native.library", "build/native/libbcrypt.so"));
        if (!Files.isReadable(path)) {
            System.err.println("bcrypt: no " + path + ", using the Java kernels");
            return null;
        }
        try {
            SymbolLookup lib = SymbolLookup.libraryLookup(path, Arena.global());
            Linker linker = Linker.nativeLinker();
            return new MethodHandle[] {linker.downcallHandle(lib.find("bcrypt_cost_loop").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_LONG, ValueLayout.ADDRESS, ValueLayout.ADDRESS)),
                    linker.downcallHandle(lib.find("bcrypt_styles").orElseThrow(), FunctionDescriptor.of(ValueLayout.JAVA_INT))};
        } catch (RuntimeException | LinkageError e) {
            System.err.println("bcrypt: " + path + " unusable (" + e + "), using the Java kernels");
            return null;
        }
    }

    private static int supported() {
        if (HANDLES == null) {
            return 0;
        }
        try {
            return (int) HANDLES[1].invokeExact();
        } catch (Throwable e) {
            throw new IllegalStateException("bcrypt_styles failed", e);
        }
    }

    private final Arena arena = Arena.ofAuto();
    private final MemorySegment states = arena.allocate(6L * STATE_WORDS * WORD_BYTES, 64);
    private final MemorySegment inputs = arena.allocate(6L * INPUT_WORDS * WORD_BYTES, 64);

    void run(int lanes, long rounds, int[][] p, int[][] s, int[][] key, int[][] salt) {
        run(kernel, lanes, rounds, p, s, key, salt);
    }

    void run(Kernel k, int lanes, long rounds, int[][] p, int[][] s, int[][] key, int[][] salt) {
        try {
            for (int lane = 0; lane < lanes; lane++) {
                long state = (long) lane * STATE_WORDS * WORD_BYTES;
                long input = (long) lane * INPUT_WORDS * WORD_BYTES;
                MemorySegment.copy(p[lane], 0, states, ValueLayout.JAVA_INT, state, 18);
                MemorySegment.copy(s[lane], 0, states, ValueLayout.JAVA_INT, state + 18 * WORD_BYTES, 1024);
                MemorySegment.copy(key[lane], 0, inputs, ValueLayout.JAVA_INT, input, 18);
                MemorySegment.copy(salt[lane], 0, inputs, ValueLayout.JAVA_INT, input + 18 * WORD_BYTES, 4);
            }
            call(k, lanes, rounds);
            for (int lane = 0; lane < lanes; lane++) {
                long state = (long) lane * STATE_WORDS * WORD_BYTES;
                MemorySegment.copy(states, ValueLayout.JAVA_INT, state, p[lane], 0, 18);
                MemorySegment.copy(states, ValueLayout.JAVA_INT, state + 18 * WORD_BYTES, s[lane], 0, 1024);
            }
        } finally {
            states.fill((byte) 0);
            inputs.fill((byte) 0);
        }
    }

    private void call(Kernel k, int lanes, long rounds) {
        int rc;
        try {
            rc = (int) COST.invokeExact(lanes, k.style, rounds, states, inputs);
        } catch (Throwable e) {
            throw new IllegalStateException("native bcrypt failed", e);
        }
        if (rc != 0) {
            throw new IllegalStateException("native bcrypt rejected " + k + " x" + lanes);
        }
    }

    /**
     * Times every kernel this CPU runs at every width with all CPUs hashing at
     * once (hyperthreads share a core's L1 and ports under load, which changes
     * the best width), keeps the fastest per hash for run() and returns its
     * width. A wider or later kernel must win by 3%. BCRYPT_KERNEL (c, ah,
     * bextr, shrx) limits the choice to one kernel.
     */
    static int calibrate(StringBuilder curve) {
        int threads = Runtime.getRuntime().availableProcessors();
        Kernel best = Kernel.C;
        int bestLanes = 1;
        double bestNanos = Double.MAX_VALUE;
        String forced = System.getenv().getOrDefault("BCRYPT_KERNEL", "auto");
        for (Kernel k : Kernel.values()) {
            if ((SUPPORTED >> k.style & 1) == 0 || !forced.equals("auto") && !forced.equalsIgnoreCase(k.name())) {
                continue;
            }
            curve.append(' ').append(k.name().toLowerCase()).append(':');
            for (int lanes = 1; lanes <= BCryptLanes.MAX; lanes++) {
                double perHash = timeAllCpus(k, lanes, threads);
                curve.append(String.format(" %d:%.1fms", lanes, perHash / 1e6));
                if (perHash < bestNanos * 0.97) {
                    best = k;
                    bestLanes = lanes;
                    bestNanos = perHash;
                }
            }
        }
        kernel = best;
        curve.append(" -> ").append(best.name().toLowerCase());
        return bestLanes;
    }

    /** Nanoseconds per hash at cost 10 (1024 rounds): the median of 5 runs of 64 rounds on every CPU at once. */
    private static double timeAllCpus(Kernel k, int lanes, int threads) {
        final long rounds = 64;
        long[] times = new long[5];
        CyclicBarrier barrier = new CyclicBarrier(threads);
        Thread[] workers = new Thread[threads];
        for (int t = 0; t < threads; t++) {
            boolean timer = t == 0;
            workers[t] = new Thread(() -> {
                NativeCost scratch = new NativeCost();
                scratch.states.fill((byte) 0x5a);
                try {
                    // the first run warms caches and is not kept
                    for (int rep = -1; rep < times.length; rep++) {
                        barrier.await();
                        long start = System.nanoTime();
                        scratch.call(k, lanes, rounds);
                        barrier.await();
                        if (timer && rep >= 0) {
                            times[rep] = System.nanoTime() - start;
                        }
                    }
                } catch (Exception e) {
                    throw new IllegalStateException(e);
                }
            }, "bcrypt-timing");
            workers[t].start();
        }
        for (Thread w : workers) {
            try {
                w.join();
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException(e);
            }
        }
        Arrays.sort(times);
        return (double) times[times.length / 2] * (1024.0 / rounds) / lanes;
    }

    static boolean supports(Kernel k) {
        return (SUPPORTED >> k.style & 1) != 0;
    }
}
