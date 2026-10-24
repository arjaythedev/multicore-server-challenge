package conduit.crypto

import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Loading the C kernel through FFM, and the fallback when the library is missing or not ours. */
class BcryptCJvmTest {
    @Test
    fun libraryBuiltForTheTestsLoads() {
        val path = System.getProperty("conduit.bcrypt.lib")
        assertNotNull(path, "build.gradle.kts passes -Dconduit.bcrypt.lib")
        assertNull(BcryptC.openAt(path))
    }

    @Test
    fun missingOrForeignLibraryIsRefused() {
        val missing = BcryptC.openAt("/nonexistent/libconduit-bcrypt.so")
        assertTrue(missing != null && "not found" in missing, missing)
        val libc = listOf("/lib/x86_64-linux-gnu/libc.so.6", "/usr/lib/x86_64-linux-gnu/libc.so.6")
            .firstOrNull { Files.isRegularFile(Path.of(it)) }
        if (libc != null) assertNotNull(BcryptC.openAt(libc)) // loads, but has no conduit_bf_* symbols
    }

    @Test
    fun fallsBackToKotlinWhenTheLibraryIsAbsent() {
        try {
            val d = BcryptKernel.select(BcryptC.openAt("/nonexistent/libconduit-bcrypt.so"))
            assertTrue(d.startsWith("Kotlin lanes") && "not found" in d, d)
            assertFalse(BcryptKernel.native)
            assertEquals(Bcrypt.MAX_LANES, BcryptKernel.maxLanes)
            val h = "\$2b\$04\$abcdefghijklmnopqrstuuK7Sjs7rFYArh/ytIZsOeM/z4RV2Fw2i" // password123
            val s = Bcrypt.parse(h)!!
            val outs = Array(3) { ByteArray(24) }
            val pws = listOf("password123", "password124", "password123")
            BcryptKernel.hashLanes(3, Array(3) { Bcrypt.keyWords(pws[it].encodeToByteArray()) }, Array(3) { s.salt }, 4, outs)
            assertEquals(listOf(true, false, true), outs.map { Bcrypt.matches(it, s.expected) })
        } finally {
            BcryptKernel.select(BcryptC.open())
        }
        assertTrue(BcryptKernel.native)
    }
}
