package conduit

import io.netty.buffer.{ByteBuf, Unpooled}
import io.netty.channel.{ChannelFutureListener, ChannelHandlerContext}
import io.netty.handler.codec.ByteToMessageDecoder
import io.netty.util.concurrent.FastThreadLocal

import java.nio.charset.StandardCharsets.{ISO_8859_1, US_ASCII}
import java.util
import scala.annotation.unused

/** An HTTP/1.x request, reduced to what the API reads. The decoder fills one per thread again for each request
  * ([[Head.request]]), so decoding makes no object for it: it is valid until [[RequestDecoder.received]] returns,
  * and what a request needs longer (it waits for Postgres) is copied out of it by then.
  */
final class Request(
    var method: String = null,
    var path: String = null, // the request target without its query string, still percent-encoded
    var query: String = null, // after the '?', null without one
    var authorization: String = null, // null when absent
    var body: Array[Byte] = null,
    var keepAlive: Boolean = false,
    var http10: Boolean = false,
)

/** Decodes HTTP/1.0 and 1.1 requests straight from the socket bytes. It reads the request line and the few
  * headers the API uses (Content-Length, Authorization, Connection, Expect, Transfer-Encoding) and skips the
  * rest. Pipelined requests and requests split across reads both work. A malformed request gets a 400 and the
  * connection is closed; chunked bodies aren't supported (no client of this API sends them), and a request that
  * takes longer than [[deadlineSeconds]] to arrive gets a 408. Decoded requests go down the pipeline;
  * [[Connection]], the server's one handler per connection, handles them itself instead.
  */
class RequestDecoder extends ByteToMessageDecoder:
  import RequestDecoder.*

  private var continueSent = false
  private var failed = false
  /** When the request now arriving began, by [[clock]]; -1 between requests. */
  private var started = -1

  /** A request must arrive whole within this many seconds of its first bytes, or it gets a 408 and the connection
    * closes, so a client can't hold a connection by trickling a request in. It is checked as more of the request
    * arrives; a client that stops sending is closed by the idle timeout like any idle connection. None by default.
    */
  protected def deadlineSeconds: Long = Long.MaxValue

  /** The clock for [[deadlineSeconds]], in seconds. */
  protected def clock: Long = 0

  override protected def decode(ctx: ChannelHandlerContext, in: ByteBuf, out: util.List[AnyRef]): Unit =
    if failed then
      in.skipBytes(in.readableBytes)
      return
    if started < 0 then started = clock.toInt
    else if clock - started >= deadlineSeconds then return fail(ctx, in, TimedOut)
    val headLength = findHeadEnd(in)
    if headLength < 0 then
      if in.readableBytes > MaxHeadLength then fail(ctx, in, TooLarge)
      return
    val head = Head.parse(in, headLength)
    if head == null then return fail(ctx, in, BadRequest)
    if head.chunked then return fail(ctx, in, NotImplemented)
    if head.contentLength < 0 then return fail(ctx, in, BadRequest)
    if head.contentLength > MaxBodyLength then return fail(ctx, in, TooLarge)
    if in.readableBytes < headLength + head.contentLength then
      if head.expectContinue && !continueSent then
        continueSent = true
        ctx.writeAndFlush(Unpooled.wrappedBuffer(Continue))
      return
    in.skipBytes(headLength)
    val body = if head.contentLength == 0 then NoBody else new Array[Byte](head.contentLength)
    in.readBytes(body)
    continueSent = false
    started = -1
    head.request.body = body
    received(ctx, head.request, out)

  /** Passes a decoded request on: the thread's [[Request]], which the next request fills again. */
  protected def received(@unused ctx: ChannelHandlerContext, req: Request, out: util.List[AnyRef]): Unit =
    out.add(Request(req.method, req.path, req.query, req.authorization, req.body, req.keepAlive, req.http10))

  /** Answers a request the server can't serve and closes the connection, ignoring anything else the client sends. */
  private def fail(ctx: ChannelHandlerContext, in: ByteBuf, response: Array[Byte]): Unit =
    failed = true
    in.skipBytes(in.readableBytes)
    ctx.writeAndFlush(Unpooled.wrappedBuffer(response)).addListener(ChannelFutureListener.CLOSE)

object RequestDecoder:
  private[conduit] val MaxHeadLength = 16 * 1024
  /** Bodies are small JSON objects (an article's is the largest); this only bounds what one request can buffer. */
  private val MaxBodyLength = 1024 * 1024
  private val NoBody = new Array[Byte](0)
  private val Continue = "HTTP/1.1 100 Continue\r\n\r\n".getBytes(US_ASCII)
  private val BadRequest = errorResponse("400 Bad Request", "bad request")
  private val TooLarge = errorResponse("413 Content Too Large", "request too large")
  private val NotImplemented = errorResponse("501 Not Implemented", "chunked bodies are not supported")
  private val TimedOut = errorResponse("408 Request Timeout", "request timeout")

  private def errorResponse(status: String, message: String): Array[Byte] =
    val body = s"""{"errors":{"body":["$message"]}}"""
    s"HTTP/1.1 $status\r\ncontent-type: application/json\r\ncontent-length: ${body.length}\r\nconnection: close\r\n\r\n$body"
      .getBytes(US_ASCII)

  /** The length of the request line and headers, up to and including the blank line, or -1 if incomplete. */
  private def findHeadEnd(in: ByteBuf): Int =
    val start = in.readerIndex
    val end = in.writerIndex
    var i = start + 3
    while i < end do
      if in.getByte(i) == '\n' && in.getByte(i - 1) == '\r' && in.getByte(i - 2) == '\n' && in.getByte(i - 3) == '\r'
      then return i + 1 - start
      i += 1
    -1

/** The parsed request line and headers, and the [[Request]] they make. One per thread, filled again for each
  * request: decoding a request makes no objects of its own, only the `String`s and body the request carries on.
  */
private final class Head:
  /** The request line and headers, copied out of the socket's buffer; grown for a longer head. */
  private[conduit] var bytes = new Array[Byte](RequestDecoder.MaxHeadLength)
  val request = Request()
  var contentLength = 0 // -1 when malformed
  var expectContinue = false
  var chunked = false

private object Head:
  /** The event loop's, or a test's: each thread decodes into its own. */
  private val current = new FastThreadLocal[Head]:
    override protected def initialValue(): Head = Head()

  private val ContentLength = "content-length".getBytes(US_ASCII)
  private val Authorization = "authorization".getBytes(US_ASCII)
  private val Connection = "connection".getBytes(US_ASCII)
  private val Expect = "expect".getBytes(US_ASCII)
  private val TransferEncoding = "transfer-encoding".getBytes(US_ASCII)
  private val Http10 = "HTTP/1.0".getBytes(US_ASCII)
  private val Http11 = "HTTP/1.1".getBytes(US_ASCII)
  /** The API's methods, and the paths most requests have: compared in place and answered as constants. */
  private val Methods = Array("GET", "POST", "PUT", "DELETE")
  private val MethodBytes = Methods.map(_.getBytes(US_ASCII))
  private val Paths = Array("/api/tags", "/api/articles", "/api/articles/feed", "/api/user")
  private val PathBytes = Paths.map(_.getBytes(US_ASCII))

  /** Parses the `length` bytes at `in`'s reader index (request line, headers and the blank line) into this thread's
    * [[Head]], which the next call fills again, or returns null if they're malformed.
    */
  def parse(in: ByteBuf, length: Int): Head =
    val h = current.get()
    if h.bytes.length < length then h.bytes = new Array[Byte](length)
    val head = h.bytes
    in.getBytes(in.readerIndex, head, 0, length)
    val lineEnd = indexOf(head, '\r', 0, length)
    val sp1 = indexOf(head, ' ', 0, length)
    val sp2 = if sp1 < 0 then -1 else indexOf(head, ' ', sp1 + 1, length)
    if sp1 <= 0 || sp2 < 0 || sp2 > lineEnd || head(lineEnd + 1) != '\n' then return null
    val http10 = is(head, sp2 + 1, lineEnd, Http10)
    if !http10 && !is(head, sp2 + 1, lineEnd, Http11) then return null
    val method = constant(head, 0, sp1, Methods, MethodBytes)
    val queryStart = indexOf(head, '?', sp1 + 1, sp2)
    val targetEnd = if queryStart >= 0 then queryStart else sp2
    val path = constant(head, sp1 + 1, targetEnd, Paths, PathBytes)
    val query = if queryStart < 0 then null else String(head, queryStart + 1, sp2 - queryStart - 1, ISO_8859_1)

    var authorization: String = null
    var contentLength = 0
    var lengthSeen = false
    var connection: String = null
    var expectContinue = false
    var chunked = false
    var pos = lineEnd + 2
    while pos < length - 2 do // the last 2 bytes are the blank line
      val end = indexOf(head, '\r', pos, length)
      if end < 0 || head(end + 1) != '\n' then return null
      val colon = indexOf(head, ':', pos, length)
      if colon <= pos || colon > end then return null
      var valueStart = colon + 1
      while valueStart < end && (head(valueStart) == ' ' || head(valueStart) == '\t') do valueStart += 1
      var valueEnd = end
      while valueEnd > valueStart && (head(valueEnd - 1) == ' ' || head(valueEnd - 1) == '\t') do valueEnd -= 1
      def value = String(head, valueStart, valueEnd - valueStart, ISO_8859_1)
      if nameIs(head, pos, colon, ContentLength) then
        // Two different lengths leave the body's end ambiguous, and a proxy in front could read it the other way
        // (request smuggling): malformed, as RFC 9112 allows. The same length twice is fine.
        val length = parseLength(head, valueStart, valueEnd)
        contentLength = if lengthSeen && length != contentLength then -1 else length
        lengthSeen = true
      else if nameIs(head, pos, colon, Authorization) then authorization = value
      else if nameIs(head, pos, colon, Connection) then connection = value.toLowerCase
      else if nameIs(head, pos, colon, Expect) then expectContinue = value.equalsIgnoreCase("100-continue")
      else if nameIs(head, pos, colon, TransferEncoding) then chunked = !value.equalsIgnoreCase("identity")
      pos = end + 2

    // HTTP/1.1 keeps the connection open unless told to close; HTTP/1.0 closes it unless told to keep it.
    val keepAlive =
      if connection == null then !http10
      else if http10 then connection.contains("keep-alive")
      else !connection.contains("close")
    val r = h.request
    r.method = method
    r.path = path
    r.query = query
    r.http10 = http10
    r.authorization = authorization
    r.keepAlive = keepAlive
    h.contentLength = contentLength
    h.expectContinue = expectContinue
    h.chunked = chunked
    h

  /** `a[from, until)` as one of the `strings` if it is one of their `bytes`, without a new `String`; else decoded. */
  private def constant(a: Array[Byte], from: Int, until: Int, strings: Array[String], bytes: Array[Array[Byte]]): String =
    var i = 0
    while i < bytes.length do
      if is(a, from, until, bytes(i)) then return strings(i)
      i += 1
    String(a, from, until - from, ISO_8859_1)

  /** The first `b` in `a[from, until)`, or -1. */
  private def indexOf(a: Array[Byte], b: Char, from: Int, until: Int): Int =
    var i = from
    while i < until && a(i) != b do i += 1
    if i < until then i else -1

  /** Whether `a[from, until)` is `bytes`, exactly: compared in place, without a `String` per request. */
  private def is(a: Array[Byte], from: Int, until: Int, bytes: Array[Byte]): Boolean =
    util.Arrays.equals(a, from, until, bytes, 0, bytes.length)

  /** Whether `a[from, until)` is `name`, ignoring ASCII case (`name` is lower case). */
  private def nameIs(a: Array[Byte], from: Int, until: Int, name: Array[Byte]): Boolean =
    if until - from != name.length then false
    else
      var i = 0
      while i < name.length && (a(from + i) | 0x20) == name(i) do i += 1
      i == name.length

  /** A Content-Length value, or -1 if it isn't a plain decimal number. */
  private def parseLength(a: Array[Byte], from: Int, until: Int): Int =
    if from == until || until - from > 9 then -1
    else
      var n = 0
      var i = from
      while i < until do
        val d = a(i) - '0'
        if d < 0 || d > 9 then return -1
        n = n * 10 + d
        i += 1
      n
