package conduit;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * bcrypt's cost loop in native/ (generated assembly on x86-64, C elsewhere), called through the FFM API. The call leaves
 * the thread in native state, so a hash in progress never holds up a garbage collection. Everything else about a hash
 * stays in BCrypt. If the library wasn't built, the server runs on the Java kernels.
 */
final class BCryptNative {
    private static final MethodHandle STYLE_OK, COST_LOOP;
    /** The style the cost loop runs by default; chosen at startup by Lanes.Hasher.measure. */
    static volatile int style;

    static {
        MethodHandle ok = null, loop = null;
        String path = System.getProperty("conduit.native");
        if (path != null && Files.isReadable(Path.of(path))) {
            try {
                Linker linker = Linker.nativeLinker();
                SymbolLookup lib = SymbolLookup.libraryLookup(Path.of(path), Arena.global());
                ok = linker.downcallHandle(lib.findOrThrow("bc_style_ok"), FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.JAVA_INT));
                loop = linker.downcallHandle(lib.findOrThrow("bc_cost_loop"), FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS,
                        ValueLayout.JAVA_INT, ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.JAVA_LONG));
            } catch (RuntimeException | LinkageError e) {
                System.err.println("bcrypt: native kernels unavailable: " + e);
                ok = null;
                loop = null;
            }
        }
        STYLE_OK = ok;
        COST_LOOP = loop;
        // until measured: the fastest kind in general
        List<Integer> st = styles();
        style = st.isEmpty() ? BCrypt.JAVA : st.get(st.size() - 1);
    }

    private BCryptNative() {}

    static boolean available() {
        return COST_LOOP != null;
    }

    /** The native styles this CPU can run, from the plain C kernels up. */
    static List<Integer> styles() {
        List<Integer> out = new ArrayList<>();
        if (STYLE_OK == null) return out;
        try {
            for (int s = 0; s <= 2; s++) if ((int) STYLE_OK.invokeExact(s) != 0) out.add(s);
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
        return out;
    }

    static String name(int style) {
        return switch (style) {
            case BCrypt.JAVA -> "java";
            case 0 -> "c";
            case 1 -> "ah";
            case 2 -> "bextr";
            default -> "style " + style;
        };
    }

    /** Runs the 2^cost rounds on n lanes laid out as in BCryptLanes: a is copied in, and back out. */
    static void costLoop(int[] a, int n, int style, int[][] kw, int[][] swk, long rounds) {
        int stride = BCryptLanes.STRIDE;
        try (Arena arena = Arena.ofConfined()) {
            // aligned so that the lanes' place in the L1 doesn't depend on where the allocator put them
            MemorySegment st = arena.allocate(4L * n * stride, 4096);
            MemorySegment k = arena.allocate(4L * n * 18, 64), s = arena.allocate(4L * n * 18, 64);
            MemorySegment.copy(a, 0, st, ValueLayout.JAVA_INT, 0, n * stride);
            for (int i = 0; i < n; i++) {
                MemorySegment.copy(kw[i], 0, k, ValueLayout.JAVA_INT, 4L * i * 18, 18);
                MemorySegment.copy(swk[i], 0, s, ValueLayout.JAVA_INT, 4L * i * 18, 18);
            }
            int rc = (int) COST_LOOP.invokeExact(st, n, style, k, s, rounds);
            if (rc != 0) throw new IllegalStateException("bc_cost_loop: " + rc);
            MemorySegment.copy(st, ValueLayout.JAVA_INT, 0, a, 0, n * stride);
        } catch (RuntimeException | Error e) {
            throw e;
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }
}
