package conduit.crypto

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemorySegment
import java.lang.foreign.SymbolLookup
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.invoke.MethodHandle
import java.nio.file.Files
import java.nio.file.Path

/**
 * JVM: native/conduit-bcrypt.c as `libconduit-bcrypt.so` next to conduit.jar (built by build.sh with the system C
 * compiler, -O3), called through the FFM API: one downcall per batch, a few hundred ns of copying against ~100 ms
 * of hashing. The calling thread is in native state meanwhile, so safepoints and GC don't wait for it. Needs
 * --enable-native-access=ALL-UNNAMED (start.sh). `-Dconduit.bcrypt.lib=<path>` overrides the location (tests).
 */
internal actual object BcryptC {
    const val LIBRARY = "libconduit-bcrypt.so"

    private var lanesFn: MethodHandle? = null

    actual fun open(): String? {
        val path = System.getProperty("conduit.bcrypt.lib") ?: besideJar() ?: return "no $LIBRARY beside the jar"
        return openAt(path)
    }

    /** Loads the library at [path] (for good) and runs its self-test. Null on success, else the reason. */
    fun openAt(path: String): String? {
        val file = Path.of(path)
        if (!Files.isRegularFile(file)) return "$path not found"
        return try {
            val lib = SymbolLookup.libraryLookup(file, Arena.global())
            val linker = Linker.nativeLinker()
            val selfTest = linker.downcallHandle(
                lib.find("conduit_bf_self_test").orElseThrow(),
                FunctionDescriptor.of(JAVA_INT),
            )
            val lanes = linker.downcallHandle(
                lib.find("conduit_bf_lanes").orElseThrow(),
                FunctionDescriptor.of(JAVA_INT, JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS),
            )
            val rc = selfTest.invokeWithArguments() as Int
            if (rc != 0) {
                "$path: self-test failed ($rc)"
            } else {
                lanesFn = lanes
                null
            }
        } catch (t: Throwable) {
            "$path: $t"
        }
    }

    /** build/jvm/libconduit-bcrypt.so when running from build/jvm/conduit.jar. */
    private fun besideJar(): String? = try {
        val jar = Path.of(BcryptC::class.java.protectionDomain.codeSource.location.toURI())
        if (Files.isRegularFile(jar)) jar.resolveSibling(LIBRARY).toString() else null
    } catch (_: Exception) {
        null
    }

    actual fun lanes(n: Int, keys: IntArray, salts: IntArray, cost: Int, out: IntArray) {
        val fn = checkNotNull(lanesFn) { "bcrypt C kernel not opened" }
        Arena.ofConfined().use { arena ->
            val k = arena.allocate(JAVA_INT, n * 18L)
            val s = arena.allocate(JAVA_INT, n * 4L)
            val o = arena.allocate(JAVA_INT, n * 6L)
            MemorySegment.copy(keys, 0, k, JAVA_INT, 0L, n * 18)
            MemorySegment.copy(salts, 0, s, JAVA_INT, 0L, n * 4)
            try {
                val ok = fn.invokeWithArguments(n, k, s, cost, o) as Int
                check(ok == 1) { "conduit_bf_lanes($n, cost $cost) failed" }
                MemorySegment.copy(o, JAVA_INT, 0L, out, 0, n * 6)
            } finally {
                k.fill(0)
            }
        }
    }
}
