package conduit.auth

import conduit.platform.Monitor
import conduit.platform.locked
import conduit.platform.nanoTime
import conduit.platform.threadScratch
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.coroutines.startCoroutine
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue
import kotlin.test.fail

private const val SEED = "\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"

class PasswordsTest {
    init {
        Passwords.warmUpCalls = 2 // the JIT warm-up only costs test time
        Passwords.start(threads = 2, batchWindowMs = 30)
    }

    /**
     * Starts every block as its own coroutine at once, waits for all, and checks that each one completed on a
     * thread other than this one (Passwords must suspend and resume on a bcrypt worker, never inline).
     */
    private fun <T> runAll(vararg blocks: suspend () -> T): List<T> {
        val m = Monitor()
        val results = arrayOfNulls<Result<T>>(blocks.size)
        var left = blocks.size
        var inline = 0
        val mine = threadScratch()
        for ((i, b) in blocks.withIndex()) {
            b.startCoroutine(Continuation(EmptyCoroutineContext) { r ->
                val here = threadScratch() === mine
                m.locked {
                    results[i] = r
                    if (here) inline++
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
        assertEquals(0, inline, "resumed inline on the caller's thread")
        return results.map { it!!.getOrThrow() }
    }

    @Test
    fun verifyAndHash() {
        val (ok, wrong, malformed, h) = runAll(
            { Passwords.verify("password123", SEED) },
            { Passwords.verify("password124", SEED) },
            { Passwords.verify("password123", "not-a-bcrypt-hash") },
            { Passwords.hash("hunter2 é🙂") },
        )
        assertEquals(true, ok)
        assertEquals(false, wrong)
        assertEquals(false, malformed)
        val hash = h as String
        assertTrue(hash.startsWith("\$2b\$10\$") && hash.length == 60, hash)
        assertEquals(listOf<Any>(true, false), runAll({ Passwords.verify("hunter2 é🙂", hash) }, { Passwords.verify("hunter2", hash) }))
    }

    @Test
    fun moreJobsThanLanesAndMixedCosts() {
        val cost4 = "\$2b\$04\$abcdefghijklmnopqrstuuK7Sjs7rFYArh/ytIZsOeM/z4RV2Fw2i" // password123
        val got = runAll(
            { Passwords.verify("password123", SEED) },
            { Passwords.verify("password123", cost4) },
            { Passwords.verify("nope", SEED) },
            { Passwords.verify("password123", SEED) },
            { Passwords.verify("nope", cost4) },
            { Passwords.verify("password123", SEED) },
            { Passwords.verify("password123", SEED.replaceRange(2, 3, "y")) },
        )
        assertEquals(listOf(true, true, false, true, false, true, true), got)
    }

    @Test
    fun freshSaltEveryHash() {
        val (a, b) = runAll({ Passwords.hash("same") }, { Passwords.hash("same") })
        assertNotEquals(a, b)
        assertEquals(listOf(true, true), runAll({ Passwords.verify("same", a) }, { Passwords.verify("same", b) }))
    }
}
