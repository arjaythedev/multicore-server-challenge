package conduit.db

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class GatherTunerTest {
    private val tuner = GatherTuner(floorMs = 30, maxMs = 100, stepMs = 10, highPct = 75, lowPct = 60)

    @Test
    fun widensWhileBusyAndNarrowsWhenQuiet() {
        assertEquals(40, tuner.decide(30, 90))
        assertEquals(100, tuner.decide(95, 99)) // capped
        assertEquals(100, tuner.decide(100, 99))
        assertEquals(50, tuner.decide(60, 55))
        assertEquals(30, tuner.decide(35, 10)) // floored
        assertEquals(60, tuner.decide(60, 68)) // inside the band: unchanged
        assertEquals(60, tuner.decide(60, -1)) // no sample: unchanged
    }

    @Test
    fun allowedCpuList() {
        assertEquals((0..7).toSet(), BoxCpu.allowedCpus("Name:\tx\nCpus_allowed_list:\t0-7\nMems_allowed:\t1"))
        assertEquals(setOf(0, 2, 3, 9), BoxCpu.allowedCpus("Cpus_allowed_list:\t0,2-3,9\n"))
        assertNull(BoxCpu.allowedCpus("Name:\tx\n"))
        assertNull(BoxCpu.allowedCpus(null))
    }

    @Test
    fun busyIsNonIdleOfTheAllowedCpus() {
        val stat = """
            cpu  300 0 100 500 100 0 0 0 0 0
            cpu0 100 0 50 200 50 0 0 0 0 0
            cpu1 200 0 50 300 50 0 0 0 0 0
            intr 12345
        """.trimIndent()
        // both CPUs: total 1000 (user+system+idle+iowait), idle 600 (idle+iowait) -> busy 400
        assertEquals(400L to 1000L, BoxCpu.busyAndTotal(stat, null))
        // cpu0 only: total 300+... = 100+50+200+50 = 400, idle 250 -> busy 150
        assertEquals(150L to 400L, BoxCpu.busyAndTotal(stat, setOf(0)))
        assertNull(BoxCpu.busyAndTotal(stat, setOf(5)))
    }
}
