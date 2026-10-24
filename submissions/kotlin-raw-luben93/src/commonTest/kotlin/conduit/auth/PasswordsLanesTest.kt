package conduit.auth

import conduit.crypto.BcryptC
import conduit.crypto.BcryptKernel
import conduit.platform.Monitor
import conduit.platform.locked
import conduit.platform.nanoTime
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.test.fail

private const val SEED = "\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"
private const val COST4 = "\$2b\$04\$abcdefghijklmnopqrstuuK7Sjs7rFYArh/ytIZsOeM/z4RV2Fw2i" // password123

/** Passwords through the pool with up to 8 lanes per batch (C kernel) and with the Kotlin fallback. */
class PasswordsLanesTest {
    init {
        Passwords.warmUpCalls = 2
        Passwords.start(threads = 2, batchWindowMs = 30)
    }

    /** Starts every block as its own coroutine at once and waits for all of them. */
    private fun <T> runAll(blocks: List<suspend () -> T>): List<T> {
        val m = Monitor()
        val results = arrayOfNulls<Result<T>>(blocks.size)
        var left = blocks.size
        for ((i, b) in blocks.withIndex()) {
            b.startCoroutine(Continuation(EmptyCoroutineContext) { r ->
                m.locked {
                    results[i] = r
                    left--
                    m.signalAll()
                }
            })
        }
        val deadline = nanoTime() + 300_000_000_000L
        m.locked {
            while (left > 0) {
                val wait = deadline - nanoTime()
                if (wait <= 0) fail("Passwords jobs did not complete")
                m.awaitNanos(wait)
            }
        }
        return results.map { it!!.getOrThrow() }
    }

    @Test
    fun fullBatchesWithEveryKindOfPassword() {
        assertTrue(BcryptKernel.native, "the C kernel should be in use")
        val pws = listOf("a\u0000b", "p".repeat(80), "é🙂 hunter2", "", "password123")
        val hashes = runAll(pws.map { pw -> suspend { Passwords.hash(pw) } })
        for (h in hashes) assertTrue(h.startsWith("\$2b\$10\$") && h.length == 60, h)
        val jobs = ArrayList<Pair<Boolean, suspend () -> Boolean>>()
        for (i in 0 until 4) jobs.add(true to suspend { Passwords.verify("password123", SEED) })
        jobs.add(false to suspend { Passwords.verify("password124", SEED) })
        for ((i, pw) in pws.withIndex()) jobs.add(true to suspend { Passwords.verify(pw, hashes[i]) })
        jobs.add(false to suspend { Passwords.verify("a", hashes[0]) }) // the NUL and what follows count
        jobs.add(false to suspend { Passwords.verify("a\u0000c", hashes[0]) })
        jobs.add(true to suspend { Passwords.verify("p".repeat(72), hashes[1]) }) // bcrypt uses 72 bytes
        jobs.add(false to suspend { Passwords.verify("p".repeat(71), hashes[1]) })
        jobs.add(true to suspend { Passwords.verify("password123", COST4) }) // another cost: its own batch
        assertEquals(jobs.map { it.first }, runAll(jobs.map { it.second }))
    }

    @Test
    fun kotlinFallbackThroughThePool() {
        try {
            BcryptKernel.select("test: forced")
            val got = runAll(
                listOf(
                    suspend { Passwords.verify("password123", COST4) },
                    suspend { Passwords.verify("password124", COST4) },
                    suspend { Passwords.verify("password123", COST4) },
                    suspend { Passwords.verify("password123", COST4) },
                    suspend { Passwords.verify("nope", COST4) },
                    suspend { Passwords.verify("password123", COST4) },
                ),
            )
            assertEquals(listOf(true, false, true, true, false, true), got)
        } finally {
            BcryptKernel.select(BcryptC.open())
        }
    }
}
