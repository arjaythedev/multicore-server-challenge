package conduit.util

import conduit.platform.isOutOfMemory
import kotlin.concurrent.atomics.AtomicInt

/** What [logSafe] prints for an OutOfMemoryError: a constant, so that printing it builds nothing. */
internal const val OOM_LINE = "conduit: OutOfMemoryError on an error path (heap exhausted); details not logged"

/** Calls (of each kind) logged in full; after that only every [LOG_EVERY]th one is, so a flood costs almost nothing. */
internal const val LOG_FULL = 10
internal const val LOG_EVERY = 1000

internal val errorLogs = AtomicInt(0)
internal val oomLogs = AtomicInt(0)

/**
 * Logs `msg(): e` from an error path that must not fail: the catch of a thread that has to survive whatever it
 * caught. Never throws (a message that cannot be built is just not logged). For an OutOfMemoryError, where any
 * allocation can throw again, it prints [OOM_LINE] and builds nothing. Rate-limited like the handler error log was:
 * the first [LOG_FULL] calls get the stack trace, then one line per [LOG_EVERY] with the running count.
 *
 * Inline, so that the caller's [msg] (a lambda capturing variables) is not allocated outside the try either.
 */
internal inline fun logSafe(msg: () -> String, e: Throwable) {
    try {
        if (isOutOfMemory(e)) {
            val n = oomLogs.addAndFetch(1)
            if (n <= LOG_FULL || n % LOG_EVERY == 0) println(OOM_LINE)
        } else {
            val n = errorLogs.addAndFetch(1)
            if (n <= LOG_FULL) println(msg() + ": " + e.stackTraceToString())
            else if (n % LOG_EVERY == 0) println(msg() + ": " + e + " (error log #" + n + ")")
        }
    } catch (_: Throwable) {
    }
}
