package conduit.db

import kotlin.jvm.JvmField

/**
 * READ_LIMIT_AUTO (default on): how many read batches may be in flight at once, between [floor] and [cap] (the number
 * of read connections, which stay open). A batch that cannot go out waits in its kind's queue and leaves bigger when a
 * connection frees, so fewer concurrent backends means bigger batches and less contention for the CPUs the server and
 * Postgres share; what it costs is queue delay. Which side wins depends on the machine (CPU speed, app:Postgres CPU
 * ratio, runtime: 6 vs 8 read connections flipped between the JVM and Native builds), so the limit is found from two
 * measured signals instead of a setting. Decided once per second by [tick], Vegas style:
 *
 * - service inflation: each batch's round trip against the best round trip of the same kind and size class seen in the
 *   last one to two [genTicks] windows ([slowdown] >= 1, the same work at the same size, only slower). With
 *   [inflight] (mean batches on a connection, Little's law) the estimate [diff] = inflight * (1 - 1 / slowdown) is how many
 *   of our own batches sit queued inside Postgres and the CPUs. Above [beta] while the limit is the binding constraint:
 *   lower it by one. Below [alpha]: raise it by one. In between: keep.
 * - queue delay guard: a batch that went out later than its gather window ended waited for a slot ([lag]). While the mean
 *   lag is above half the mean round trip, the limit is raised whatever the inflation says, so the limiter cannot trade
 *   more latency than one service time for efficiency.
 *
 * Not enough batches in a tick ([minBatches]) holds the limit. Starts at [cap] (no limit), so a missing sensor or an idle
 * server behaves like a server without the limiter. Not thread-safe: the pool calls it under its lock.
 */
internal class ReadLimiter(
    @JvmField val floor: Int,
    @JvmField val cap: Int,
    kinds: Int,
    private val alpha: Double = 1.0,
    private val beta: Double = 2.0,
    private val genTicks: Int = 30,
    private val minBatches: Int = 20,
) {
    /** Batches allowed in flight now. */
    @JvmField var limit = cap

    // best round trip per (kind, size class): the current and the previous window; the baseline is the smaller
    private val curMin = LongArray(kinds * BUCKETS) { Long.MAX_VALUE }
    private val prevMin = LongArray(kinds * BUCKETS) { Long.MAX_VALUE }

    // this tick's batches
    private val count = IntArray(kinds * BUCKETS)
    private var batches = 0
    private var sumRtt = 0L
    private var sumLag = 0L
    private var ticks = 0

    /** The last decision's inputs, for the statistics line. */
    var slowdown = 1.0
        private set
    var inflight = 0.0
        private set
    var lagMs = 0.0
        private set

    /** A finished batch of [n] requests of read kind [kind]: [rttNs] sent until its reply was read, [lagNs] queue delay past its gather window. */
    fun onBatch(kind: Int, n: Int, rttNs: Long, lagNs: Long) {
        val key = kind * BUCKETS + sizeClass(n)
        if (rttNs < curMin[key]) curMin[key] = rttNs
        count[key]++
        batches++
        sumRtt += rttNs
        sumLag += lagNs
    }

    /** One decision from the batches since the last call (the interval was [intervalNs] long); returns the new [limit]. */
    fun tick(intervalNs: Long): Int {
        if (batches >= minBatches && intervalNs > 0) {
            var expected = 0L
            for (k in count.indices) {
                val c = count[k]
                if (c > 0) expected += c * minOf(curMin[k], prevMin[k])
            }
            slowdown = if (expected > 0) maxOf(1.0, sumRtt.toDouble() / expected) else 1.0
            inflight = sumRtt.toDouble() / intervalNs
            val meanRtt = sumRtt.toDouble() / batches
            val meanLag = sumLag.toDouble() / batches
            lagMs = meanLag / 1e6
            limit = decide(limit, inflight, slowdown, meanLag, meanRtt)
        }
        count.fill(0)
        batches = 0
        sumRtt = 0L
        sumLag = 0L
        if (++ticks % genTicks == 0) {
            curMin.copyInto(prevMin)
            curMin.fill(Long.MAX_VALUE)
        }
        return limit
    }

    /** The new limit given the current one and one tick's signals ([meanLag] and [meanRtt] in the same unit). */
    fun decide(current: Int, inflight: Double, slowdown: Double, meanLag: Double, meanRtt: Double): Int {
        val diff = inflight * (1.0 - 1.0 / slowdown)
        return when {
            meanLag > meanRtt / 2 -> minOf(cap, current + 1)
            diff > beta && inflight >= 0.75 * current -> maxOf(floor, current - 1)
            diff < alpha -> minOf(cap, current + 1)
            else -> current
        }
    }

    companion object {
        /** Size classes 1, 2-3, 4-7, ... 64+ (the same buckets as the pool's batch size statistics). */
        const val BUCKETS = 7

        fun sizeClass(n: Int): Int = minOf(BUCKETS - 1, 31 - maxOf(1, n).countLeadingZeroBits())
    }
}
