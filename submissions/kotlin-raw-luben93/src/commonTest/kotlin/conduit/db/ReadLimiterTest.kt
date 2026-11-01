package conduit.db

import kotlin.test.Test
import kotlin.test.assertEquals

class ReadLimiterTest {
    private val sec = 1_000_000_000L
    private val ms = 1_000_000L

    private fun limiter() = ReadLimiter(floor = 2, cap = 8, kinds = 2)

    /** [n] batches of kind 0 / size 16 in one tick, each [rttMs] long, [lagMs] late. */
    private fun feed(l: ReadLimiter, n: Int, rttMs: Long, lagMs: Long = 0, kind: Int = 0) {
        repeat(n) { l.onBatch(kind, 16, rttMs * ms, lagMs * ms) }
    }

    @Test
    fun sizeClasses() {
        assertEquals(0, ReadLimiter.sizeClass(1))
        assertEquals(1, ReadLimiter.sizeClass(3))
        assertEquals(2, ReadLimiter.sizeClass(4))
        assertEquals(4, ReadLimiter.sizeClass(31))
        assertEquals(6, ReadLimiter.sizeClass(64))
        assertEquals(6, ReadLimiter.sizeClass(1000))
        assertEquals(0, ReadLimiter.sizeClass(0))
    }

    @Test
    fun decideRule() {
        val l = limiter()
        // 8 batches on connections, 2x slower than the best: diff = 4 > beta, limit binds: lower
        assertEquals(7, l.decide(8, 8.0, 2.0, 0.0, 100.0))
        assertEquals(2, l.decide(2, 2.0, 3.0, 0.0, 100.0)) // floored
        // in the band (alpha..beta): keep
        assertEquals(6, l.decide(6, 6.0, 1.25, 0.0, 100.0)) // diff 1.2
        // no inflation: raise, capped
        assertEquals(7, l.decide(6, 6.0, 1.05, 0.0, 100.0))
        assertEquals(8, l.decide(8, 8.0, 1.0, 0.0, 100.0))
        // the limit is not what limits (few batches in flight): do not lower
        assertEquals(8, l.decide(8, 3.0, 4.0, 0.0, 100.0))
        // queue delay above half a round trip raises it whatever the inflation says
        assertEquals(6, l.decide(5, 5.0, 3.0, 60.0, 100.0))
        assertEquals(4, l.decide(5, 5.0, 3.0, 50.0, 100.0)) // exactly half: the guard does not fire, the inflation lowers it
    }

    @Test
    fun lowersOneStepPerTickWhileServiceInflates() {
        val l = limiter()
        // the best round trip of this kind and size is 100 ms (seen once), the batches now take 300 ms: slowdown ~3
        l.onBatch(0, 16, 100 * ms, 0)
        var expect = 8
        repeat(10) {
            feed(l, 30, 300)
            // inflight = 30 * 300 ms / 1 s = 9 (all connections busy), diff well above beta
            val got = l.tick(sec)
            expect = maxOf(2, expect - 1)
            assertEquals(expect, got)
        }
        assertEquals(2, l.limit)
    }

    @Test
    fun raisesBackWhenInflationGoes() {
        val l = limiter()
        l.limit = 3
        l.onBatch(0, 16, 100 * ms, 0)
        feed(l, 30, 100) // as fast as the best: slowdown 1, diff 0
        assertEquals(4, l.tick(sec))
        feed(l, 30, 100)
        assertEquals(5, l.tick(sec))
    }

    @Test
    fun holdsWithoutEnoughBatches() {
        val l = limiter()
        l.limit = 5
        feed(l, 19, 500)
        assertEquals(5, l.tick(sec))
        assertEquals(5, l.tick(sec)) // nothing at all
    }

    @Test
    fun lagGuardRaisesAnInflatedLimit() {
        val l = limiter()
        l.limit = 4
        l.onBatch(0, 16, 100 * ms, 0)
        feed(l, 30, 300, lagMs = 200) // inflated, but requests wait 200 ms for a slot (> half of 300)
        assertEquals(5, l.tick(sec))
    }

    @Test
    fun baselineIsPerKindAndSizeClass() {
        val l = limiter()
        // kind 1 is slow by nature (400 ms at size 16): that is its baseline, not inflation
        repeat(30) { l.onBatch(1, 16, 400 * ms, 0) }
        l.limit = 4
        assertEquals(5, l.tick(sec)) // slowdown 1: raise
        // size class matters: big batches take longer without being inflated
        repeat(30) { l.onBatch(0, 64, 300 * ms, 0) }
        repeat(30) { l.onBatch(0, 2, 20 * ms, 0) }
        assertEquals(6, l.tick(sec))
    }

    @Test
    fun baselineExpiresAfterTwoWindows() {
        val l = ReadLimiter(floor = 2, cap = 8, kinds = 1, genTicks = 3)
        l.limit = 4
        l.onBatch(0, 16, 50 * ms, 0) // one lucky fast batch
        // while it is remembered, 300 ms batches look 6x inflated
        feed(l, 30, 300)
        assertEquals(3, l.tick(sec))
        feed(l, 30, 300)
        assertEquals(2, l.tick(sec))
        feed(l, 30, 300)
        assertEquals(2, l.tick(sec)) // window 1 ends: the 50 ms moves to the previous window, still counted
        repeat(3) { feed(l, 30, 300); l.tick(sec) } // ticks 4-6: still inflated, and the window rotates again after tick 6
        // the lucky batch is gone now: 300 ms is the best seen, slowdown 1, raise
        feed(l, 30, 300)
        assertEquals(3, l.tick(sec))
    }
}
