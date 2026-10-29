package conduit.util

import kotlin.jvm.JvmField

/**
 * Durations of one statistics interval (DB_STATS_S): count, sum and max, in nanoseconds. Not thread-safe: guarded by
 * the lock of whatever it measures.
 */
internal class Timing {
    @JvmField var n = 0L
    @JvmField var sum = 0L
    @JvmField var max = 0L

    fun add(nanos: Long) {
        n++
        sum += nanos
        if (nanos > max) max = nanos
    }

    /** "mean/max" in ms ("-" when empty), then starts the next interval. */
    fun take(): String {
        val s = if (n == 0L) "-" else ms(sum / n) + "/" + ms(max)
        n = 0
        sum = 0
        max = 0
        return s
    }
}

/** [nanos] as milliseconds with one decimal. */
internal fun ms(nanos: Long): String {
    val tenths = nanos / 100_000
    return "${tenths / 10}.${tenths % 10}"
}
