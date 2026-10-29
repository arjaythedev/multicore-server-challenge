package conduit.pg

import kotlin.test.Test
import kotlin.test.assertEquals

/** date_part('epoch', ts) as float8 (TsSql.epoch) must give back the exact microseconds Row.micros would read. */
class EpochMicrosTest {
    private val pgEpochMicros = 946_684_800_000_000L

    @Test
    fun float8EpochRoundTripsExactly() {
        val r = Row()
        val rnd = java.util.Random(42)
        repeat(200_000) {
            // 2000 .. 2100, any microsecond (Postgres timestamps are whole microseconds)
            val micros = (rnd.nextDouble() * 3_155_760_000_000_000.0).toLong()
            // what Postgres sends for date_part('epoch', ts): the closest double to the exact seconds value
            val epochSeconds = java.math.BigDecimal(micros + pgEpochMicros).movePointLeft(6).toDouble()
            r.objs = arrayOf(epochSeconds)
            assertEquals(micros, r.micros(0), "micros $micros")
        }
        r.objs = arrayOf(123_456_789L) // a plain Long (e.g. converted from OffsetDateTime) passes through
        assertEquals(123_456_789L, r.micros(0))
    }
}
