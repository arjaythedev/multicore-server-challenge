package conduit.security;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * bcrypt's inner loop in C (native/bcrypt_lanes.c, compiled by build.sh into target/libconduit-bcrypt.so), called
 * through the Foreign Function and Memory API: one call per batch, a few hundred nanoseconds of copying against
 * ~100 ms of hashing. Up to six hashes run interleaved, about 14 ms of CPU each at cost 10 instead of the Java
 * code's 20 ms. The calling thread is in native code meanwhile, so it never holds up the garbage collector.
 *
 * <p>If the library is missing (no C compiler), fails to load, or disagrees with the Java implementation on the
 * startup self-test, it is not used and {@link BCrypt} computes in Java.
 */
final class NativeBcrypt {
    /** Hashes per native call: the C kernel's sweet spot (8 lanes start to spill registers). */
    static final int LANES = 6;
    private static final String LIBRARY = "libconduit-bcrypt.so";

    private static MethodHandle lanes;

    private NativeBcrypt() {
    }

    static boolean available() {
        return lanes != null;
    }

    /** Loads the library next to conduit.jar and hands it Blowfish's initial state. Null on success, else why not. */
    static String load(int[] initialState) {
        try {
            Path jar = Path.of(NativeBcrypt.class.getProtectionDomain().getCodeSource().getLocation().toURI());
            Path library = jar.resolveSibling(LIBRARY);
            if (!Files.isRegularFile(library)) return library + " not found";
            Linker linker = Linker.nativeLinker();
            SymbolLookup symbols = SymbolLookup.libraryLookup(library, Arena.global());
            MethodHandle init = linker.downcallHandle(symbols.find("conduit_bcrypt_init").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS));
            MethodHandle compute = linker.downcallHandle(symbols.find("conduit_bcrypt_lanes").orElseThrow(),
                    FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.JAVA_INT,
                            ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.ADDRESS));
            try (Arena arena = Arena.ofConfined()) {
                MemorySegment state = arena.allocateFrom(ValueLayout.JAVA_INT, initialState);
                if ((int) init.invokeExact(state) != 1) return "conduit_bcrypt_init failed";
            }
            lanes = compute;
            return null;
        } catch (Throwable e) {
            return e.toString();
        }
    }

    /** Computes jobs[first, first + count) (count <= LANES, all of the same cost) in one native call. */
    static void compute(BCrypt.Job[] jobs, int first, int count) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment keys = arena.allocate(ValueLayout.JAVA_INT, 18L * count);
            MemorySegment salts = arena.allocate(ValueLayout.JAVA_INT, 4L * count);
            MemorySegment out = arena.allocate(ValueLayout.JAVA_INT, 6L * count);
            for (int k = 0; k < count; k++) {
                MemorySegment.copy(jobs[first + k].keyWords, 0, keys, ValueLayout.JAVA_INT, 72L * k, 18);
                MemorySegment.copy(jobs[first + k].saltWords, 0, salts, ValueLayout.JAVA_INT, 16L * k, 4);
            }
            int ok = (int) lanes.invokeExact(count, jobs[first].cost, keys, salts, out);
            keys.fill((byte) 0);                                   // no key material left behind
            if (ok != 1) throw new IllegalStateException("conduit_bcrypt_lanes failed");
            for (int k = 0; k < count; k++) {
                byte[] output = jobs[first + k].output;
                for (int i = 0; i < output.length; i++) {
                    int word = out.getAtIndex(ValueLayout.JAVA_INT, 6L * k + i / 4);
                    output[i] = (byte) (word >>> (24 - 8 * (i % 4)));
                }
            }
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable e) {
            throw new IllegalStateException(e);
        }
    }

    /** Stops using the library (when it disagreed with the Java implementation). */
    static void disable() {
        lanes = null;
    }
}
