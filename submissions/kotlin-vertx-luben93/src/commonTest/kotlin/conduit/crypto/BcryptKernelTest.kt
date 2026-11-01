package conduit.crypto

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** The seed's hash of "password123" (every seeded user has it). */
private const val SEED = "\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"

private fun hex(s: String) = ByteArray(s.length / 2) { s.substring(2 * it, 2 * it + 2).toInt(16).toByte() }

/** Passwords of every kind: empty, ASCII, UTF-8, embedded NULs, the 71/72/73-byte cutoff, high and 0xff bytes. */
private val KEYS: List<ByteArray> = listOf(
    "password123".encodeToByteArray(),
    ByteArray(0),
    "é🙂 hunter2".encodeToByteArray(),
    "a\u0000b".encodeToByteArray(),
    "\u0000".encodeToByteArray(),
    "p".repeat(71).encodeToByteArray(),
    "p".repeat(72).encodeToByteArray(),
    "q".repeat(73).encodeToByteArray(),
    hex("ffa334ffffffa3333435"),
    "password124".encodeToByteArray(),
    ByteArray(90) { (it * 37 + 1).toByte() },
)

private fun salt(i: Int) = ByteArray(16) { (it * 13 + i * 7 + 1).toByte() }

class BcryptKernelTest {
    @Test
    fun cKernelOpensAndPassesItsChecks() {
        assertNull(BcryptC.open()) // JVM: Gradle builds the library for the tests; Native: always linked in
        assertTrue(BcryptKernel.select(null).startsWith("C lanes"))
        assertTrue(BcryptKernel.native)
        assertEquals(8, BcryptKernel.maxLanes)
    }

    @Test
    fun cMatchesKotlinForEveryLaneCount() {
        assertNull(BcryptC.open())
        for (n in 1..BcryptKernel.MAX_LANES) {
            for (rot in KEYS.indices step 3) {
                val idx = IntArray(n) { (it + rot) % KEYS.size }
                val keys = Array(n) { Bcrypt.keyWords(KEYS[idx[it]]) }
                val salts = Array(n) { Bcrypt.saltWords(salt(idx[it])) }
                val c = Array(n) { ByteArray(24) }
                BcryptKernel.hashLanesC(n, keys, salts, 4, c)
                for (i in 0 until n) {
                    val k = Array(1) { ByteArray(24) }
                    Bcrypt.hashLanes(1, arrayOf(keys[i]), arrayOf(salts[i]), 4, k)
                    assertContentEquals(k[0], c[i], "n=$n lane $i key ${idx[i]}")
                }
            }
        }
    }

    @Test
    fun embeddedNulIsPartOfTheKey() {
        assertNull(BcryptC.open())
        val pws = listOf("a\u0000b", "a", "a\u0000c", "a\u0000")
        val outs = Array(4) { ByteArray(24) }
        val s = Bcrypt.saltWords(salt(1))
        BcryptKernel.hashLanesC(4, Array(4) { Bcrypt.keyWords(pws[it].encodeToByteArray()) }, Array(4) { s }, 4, outs)
        // crypt(3) would see "a" four times; the key words carry every byte
        for (i in 0 until 4) for (j in i + 1 until 4) assertFalse(outs[i].contentEquals(outs[j]), "${pws[i]} vs ${pws[j]}")
    }

    @Test
    fun seedHashInEveryLaneOfEveryLaneCount() {
        assertNull(BcryptC.open())
        val seed = Bcrypt.parse(SEED)!!
        for (n in 1..BcryptKernel.MAX_LANES) {
            val right = n - 1 - (n / 3) // somewhere in the middle or at the end
            val keys = Array(n) { Bcrypt.keyWords((if (it == right) "password123" else "wrong$it").encodeToByteArray()) }
            val outs = Array(n) { ByteArray(24) }
            BcryptKernel.hashLanesC(n, keys, Array(n) { seed.salt }, 10, outs)
            for (i in 0 until n) assertEquals(i == right, Bcrypt.matches(outs[i], seed.expected), "n=$n lane $i")
        }
    }

    @Test
    fun cMatchesKotlinAtCost10() {
        assertNull(BcryptC.open())
        val c = Array(8) { ByteArray(24) }
        val keys = Array(8) { Bcrypt.keyWords(KEYS[it]) }
        val salts = Array(8) { Bcrypt.saltWords(salt(it)) }
        BcryptKernel.hashLanesC(8, keys, salts, 10, c)
        val k = Array(8) { ByteArray(24) }
        BcryptKernel.hashLanesKotlin(8, keys, salts, 10, k) // two 4-lane batches
        for (i in 0 until 8) {
            assertContentEquals(k[i], c[i], "lane $i")
            assertEquals(Bcrypt.hash(KEYS[i], salt(i), 10), Bcrypt.format(10, salt(i), c[i]))
        }
    }

    @Test
    fun kotlinLanesTakeUpToEight() {
        for (n in 1..8) {
            val keys = Array(n) { Bcrypt.keyWords(KEYS[it]) }
            val salts = Array(n) { Bcrypt.saltWords(salt(it)) }
            val outs = Array(n) { ByteArray(24) }
            BcryptKernel.hashLanesKotlin(n, keys, salts, 4, outs)
            for (i in 0 until n) {
                val one = Array(1) { ByteArray(24) }
                Bcrypt.hashLanes(1, arrayOf(keys[i]), arrayOf(salts[i]), 4, one)
                assertContentEquals(one[0], outs[i], "n=$n lane $i")
            }
        }
    }

    @Test
    fun fallsBackToKotlinWhenTheKernelIsUnavailable() {
        try {
            val d = BcryptKernel.select("library missing")
            assertTrue(d.startsWith("Kotlin lanes") && "library missing" in d, d)
            assertFalse(BcryptKernel.native)
            assertEquals(Bcrypt.MAX_LANES, BcryptKernel.maxLanes)
            val seed = Bcrypt.parse(SEED)!!
            val outs = Array(2) { ByteArray(24) }
            BcryptKernel.hashLanes(2, Array(2) { Bcrypt.keyWords("password12${it + 2}".encodeToByteArray()) }, Array(2) { seed.salt }, 10, outs)
            assertFalse(Bcrypt.matches(outs[0], seed.expected))
            assertTrue(Bcrypt.matches(outs[1], seed.expected))
        } finally {
            BcryptKernel.select(BcryptC.open())
        }
        assertTrue(BcryptKernel.native)
    }
}
