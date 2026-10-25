package conduit

import io.netty.buffer.UnpooledByteBufAllocator

import java.nio.charset.StandardCharsets.{US_ASCII, UTF_8}
import java.time.Instant

class OutSuite extends munit.FunSuite:
  private val alloc = UnpooledByteBufAllocator(false)

  /** Microseconds since 2000-01-01, as Postgres sends a `timestamptz`. */
  private def micros(iso: String): Long =
    val i = Instant.parse(iso)
    (i.getEpochSecond - 946_684_800L) * 1_000_000L + i.getNano / 1000

  private def timestamp(pgMicros: Long): String =
    val out = Out()
    out.timestamp(pgMicros)
    out.body

  test("timestamps in UTC with exactly 3 fractional digits, truncated"):
    assertEquals(timestamp(0), "\"2000-01-01T00:00:00.000Z\"")
    assertEquals(timestamp(micros("2025-04-01T12:00:00.123999Z")), "\"2025-04-01T12:00:00.123Z\"")
    assertEquals(timestamp(micros("2024-02-29T23:59:59.999999Z")), "\"2024-02-29T23:59:59.999Z\"")
    assertEquals(timestamp(-1), "\"1999-12-31T23:59:59.999Z\"")
    assertEquals(timestamp(micros("1970-01-01T00:00:00Z")), "\"1970-01-01T00:00:00.000Z\"")
    assertEquals(timestamp(micros("2100-03-01T01:02:03.004Z")), "\"2100-03-01T01:02:03.004Z\"")

  test("agrees with java.time on many instants"):
    val random = scala.util.Random(7)
    for _ <- 0 until 10_000 do
      val ms = random.between(-2_000_000_000_000L, 4_000_000_000_000L)
      val pg = (ms - 946_684_800_000L) * 1000 + random.nextInt(1000)
      val formatted = timestamp(pg)
      val back = Instant.parse(formatted.drop(1).dropRight(1))
      assertEquals(back.toEpochMilli, ms, formatted)
      assert(formatted.length == 26, formatted)

  test("JSON strings escaped like JSON.stringify"):
    val out = Out()
    out.jsonString("a\"b\\c\nd\u0001é€")
    assertEquals(out.body, "\"a\\\"b\\\\c\\nd\\u0001é€\"")

  test("a response: status line, content type and length, then the body"):
    val out = Out()
    out.bytes("{}".getBytes(UTF_8))
    val r = out.response(alloc, Status.Created, Out.Ending.KeepAlive)
    assertEquals(r.toString(US_ASCII), "HTTP/1.1 201 Created\r\ncontent-type: application/json\r\ncontent-length: 2\r\n\r\n{}")
    out.reset()
    val closing = out.response(alloc, Status.NoContent, Out.Ending.Close)
    assertEquals(closing.toString(US_ASCII), "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n")
