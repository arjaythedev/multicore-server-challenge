package conduit

import io.netty.buffer.{ByteBuf, ByteBufAllocator}

import java.nio.charset.StandardCharsets.{US_ASCII, UTF_8}
import java.util.Arrays

/** A response status, with its status line and fixed headers pre-encoded. */
enum Status(val code: Int, reason: String):
  case Ok extends Status(200, "OK")
  case Created extends Status(201, "Created")
  case NoContent extends Status(204, "No Content")
  case BadRequest extends Status(400, "Bad Request")
  case Unauthorized extends Status(401, "Unauthorized")
  case Forbidden extends Status(403, "Forbidden")
  case NotFound extends Status(404, "Not Found")
  case Unprocessable extends Status(422, "Unprocessable Content")
  case InternalServerError extends Status(500, "Internal Server Error")
  case ServiceUnavailable extends Status(503, "Service Unavailable")

  /** Whether the response has a body (a 204 has none, and no content headers). */
  def hasBody: Boolean = code != 204

  /** Everything up to the content length's digits, or for a 204 the status line without its line end. */
  private[conduit] val head: Array[Byte] =
    if code == 204 then s"HTTP/1.1 $code $reason".getBytes(US_ASCII)
    else s"HTTP/1.1 $code $reason\r\ncontent-type: application/json\r\ncontent-length: ".getBytes(US_ASCII)

/** Builds one response body. The JSON is written after some headroom; [[response]] then puts the status line and
  * headers right in front of it and copies the whole response into one buffer, for a single socket write. A request
  * holds one while it waits for Postgres, and gives it back to its loop's [[Out.Pool]] once answered, so it must
  * stay on that loop's thread.
  */
final class Out:
  import Out.*

  private var buf = new Array[Byte](16 * 1024)
  private var pos = Headroom

  /** Starts a new body. */
  def reset(): Unit = pos = Headroom

  /** The body's length so far. */
  def length: Int = pos - Headroom

  def byte(b: Int): Out =
    ensure(1)
    buf(pos) = b.toByte
    pos += 1
    this

  def bytes(a: Array[Byte]): Out = bytes(a, 0, a.length)

  def bytes(a: Array[Byte], from: Int, length: Int): Out =
    ensure(length)
    System.arraycopy(a, from, buf, pos, length)
    pos += length
    this

  /** `length` bytes of another [[Out]]'s body, from `from` (one of its [[length]]s). */
  def bytes(other: Out, from: Int, length: Int): Out = bytes(other.buf, Headroom + from, length)

  /** Bytes copied from a Netty buffer as they are: a value Postgres sent that needs no escaping. */
  def bytes(from: ByteBuf, index: Int, length: Int): Out =
    ensure(length)
    from.getBytes(index, buf, pos, length)
    pos += length
    this

  def bool(value: Boolean): Out = bytes(if value then True else False)

  def nul(): Out = bytes(Null)

  def long(value: Long): Out =
    if value < 0 then bytes(java.lang.Long.toString(value).getBytes(US_ASCII))
    else
      val n = digitCount(value)
      ensure(n)
      writeDigits(buf, pos, value, n)
      pos += n
      this

  def jsonString(s: String): Out = jsonString(s.getBytes(UTF_8))

  /** A JSON string from UTF-8 bytes. Escapes `"`, `\` and control characters like JSON.stringify; every other
    * byte, multi-byte UTF-8 sequences included, is copied as is.
    */
  def jsonString(utf8: Array[Byte]): Out = jsonString(utf8, 0, utf8.length)

  def jsonString(utf8: Array[Byte], from: Int, until: Int): Out =
    ensure(until - from + 2)
    buf(pos) = '"'
    pos += 1
    var start = from
    var i = from
    while i < until do
      val b = utf8(i) & 0xff
      if b < 0x20 || b == '"' || b == '\\' then
        bytes(utf8, start, i - start)
        b.toChar match
          case '"' | '\\' => byte('\\').byte(b)
          case '\b' => byte('\\').byte('b')
          case '\f' => byte('\\').byte('f')
          case '\n' => byte('\\').byte('n')
          case '\r' => byte('\\').byte('r')
          case '\t' => byte('\\').byte('t')
          case _ => byte('\\').byte('u').byte('0').byte('0').byte(Hex(b >> 4)).byte(Hex(b & 0xf))
        start = i + 1
      i += 1
    bytes(utf8, start, until - start)
    byte('"')

  /** A JSON string from `length` bytes of UTF-8 at `index` in `from`, a value in Postgres's reply. They are copied
    * as they are and then checked, since text rarely needs escaping; if it does, the copy is written again through
    * the escaping [[jsonString]].
    */
  def jsonString(from: ByteBuf, index: Int, length: Int): Out =
    val start = pos
    ensure(length + 2)
    buf(pos) = '"'
    pos += 1
    from.getBytes(index, buf, pos, length)
    val end = pos + length
    var i = pos
    while i < end && { val b = buf(i) & 0xff; b >= 0x20 && b != '"' && b != '\\' } do i += 1
    if i == end then
      pos = end
      byte('"')
    else
      val raw = Arrays.copyOfRange(buf, start + 1, end)
      pos = start
      jsonString(raw)

  /** A timestamp as JSON: RFC 3339 in UTC with exactly 3 fractional digits, truncated, from Postgres's binary
    * `timestamptz` (microseconds since 2000-01-01 UTC).
    */
  def timestamp(pgMicros: Long): Out =
    val ms = Math.floorDiv(pgMicros, 1000L) + PgEpochMillis
    val days = Math.floorDiv(ms, MillisPerDay)
    var msOfDay = Math.floorMod(ms, MillisPerDay).toInt
    // Days since 1970-01-01 to a civil date (Howard Hinnant's days_from_civil, inverted).
    val z = days + 719468
    val era = Math.floorDiv(z, 146097L)
    val doe = (z - era * 146097).toInt
    val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    val mp = (5 * doy + 2) / 153
    val day = doy - (153 * mp + 2) / 5 + 1
    val month = if mp < 10 then mp + 3 else mp - 9
    val year = (yoe + era * 400 + (if month <= 2 then 1 else 0)).toInt
    ensure(26)
    val b = buf
    var p = pos
    b(p) = '"'
    digits(b, p + 1, year, 4)
    b(p + 5) = '-'
    digits(b, p + 6, month, 2)
    b(p + 8) = '-'
    digits(b, p + 9, day, 2)
    b(p + 11) = 'T'
    val hours = msOfDay / 3_600_000
    msOfDay -= hours * 3_600_000
    val minutes = msOfDay / 60_000
    msOfDay -= minutes * 60_000
    val seconds = msOfDay / 1000
    digits(b, p + 12, hours, 2)
    b(p + 14) = ':'
    digits(b, p + 15, minutes, 2)
    b(p + 17) = ':'
    digits(b, p + 18, seconds, 2)
    b(p + 20) = '.'
    digits(b, p + 21, msOfDay - seconds * 1000, 3)
    b(p + 24) = 'Z'
    b(p + 25) = '"'
    p += 26
    pos = p
    this

  /** The whole response: status line and headers, then the body written since [[reset]] (none for a 204). */
  def response(alloc: ByteBufAllocator, status: Status, ending: Ending): ByteBuf =
    if !status.hasBody then
      val length = status.head.length + ending.bytes.length
      alloc.ioBuffer(length).writeBytes(status.head).writeBytes(ending.bytes)
    else
      val bodyLength = pos - Headroom
      val digits = digitCount(bodyLength)
      val start = Headroom - status.head.length - digits - ending.bytes.length
      System.arraycopy(status.head, 0, buf, start, status.head.length)
      writeDigits(buf, start + status.head.length, bodyLength, digits)
      System.arraycopy(ending.bytes, 0, buf, Headroom - ending.bytes.length, ending.bytes.length)
      alloc.ioBuffer(pos - start).writeBytes(buf, start, pos - start)

  /** The body written since [[reset]], as text (tests). */
  private[conduit] def body: String = String(buf, Headroom, pos - Headroom, UTF_8)

  private def ensure(n: Int): Unit =
    if pos + n > buf.length then buf = Arrays.copyOf(buf, math.max(buf.length * 2, pos + n))

object Out:
  /** Room for the longest status line and headers, in front of the body. */
  private val Headroom = 128
  private val Hex = "0123456789abcdef".getBytes(US_ASCII)
  private val True = "true".getBytes(US_ASCII)
  private val False = "false".getBytes(US_ASCII)
  private val Null = "null".getBytes(US_ASCII)
  /** 2000-01-01T00:00:00Z, Postgres's epoch, in milliseconds since 1970's. */
  private val PgEpochMillis = 946_684_800_000L
  private val MillisPerDay = 86_400_000L

  /** How a response ends its headers, which depends on whether the connection stays open. */
  enum Ending(text: String):
    case KeepAlive extends Ending("\r\n\r\n") // HTTP/1.1: keep-alive is the default
    case KeepAlive10 extends Ending("\r\nconnection: keep-alive\r\n\r\n") // HTTP/1.0 has to ask for it
    case Close extends Ending("\r\nconnection: close\r\n\r\n")
    private[Out] val bytes = text.getBytes(US_ASCII)

  /** A loop's spare [[Out]]s: a request takes one when it starts and gives it back once answered. */
  final class Pool:
    private var free = new Array[Out](64)
    private var size = 0

    def take(): Out =
      if size == 0 then Out()
      else
        size -= 1
        val out = free(size)
        free(size) = null
        out.reset()
        out

    /** Gives `out` back, unless it grew large answering one request: keep the pool's memory bounded. */
    def give(out: Out): Unit =
      if out.buf.length <= MaxPooledBytes then
        if size == free.length then free = Arrays.copyOf(free, size * 2)
        free(size) = out
        size += 1

  private val MaxPooledBytes = 256 * 1024

  private def digitCount(value: Long): Int =
    var n = 1
    var rest = value
    while rest >= 10 do
      rest /= 10
      n += 1
    n

  private def writeDigits(to: Array[Byte], at: Int, value: Long, n: Int): Unit =
    var i = at + n - 1
    var rest = value
    while i >= at do
      to(i) = ('0' + rest % 10).toByte
      rest /= 10
      i -= 1

  /** `value` in exactly `n` digits, with leading zeros. */
  private def digits(to: Array[Byte], at: Int, value: Int, n: Int): Unit =
    var i = at + n - 1
    var rest = value
    while i >= at do
      to(i) = ('0' + rest % 10).toByte
      rest /= 10
      i -= 1
