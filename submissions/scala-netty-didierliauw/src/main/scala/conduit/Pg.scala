package conduit

import io.netty.bootstrap.Bootstrap
import io.netty.buffer.{ByteBuf, ByteBufUtil}
import io.netty.channel.{Channel, ChannelHandlerContext, ChannelOption, EventLoop}
import io.netty.handler.codec.ByteToMessageDecoder

import java.net.{URI, URLDecoder}
import java.nio.charset.StandardCharsets.{US_ASCII, UTF_8}
import java.security.{MessageDigest, SecureRandom}
import java.util
import java.util.Base64
import java.util.concurrent.{CompletableFuture, TimeUnit}
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec
import scala.annotation.unused
import scala.util.control.NonFatal

/** Where Postgres is, from `DATABASE_URL` (`postgres://user:password@host:port/database`). */
final case class PgConfig(host: String, port: Int, user: String, password: String, database: String)

object PgConfig:
  def parse(url: String): PgConfig =
    val uri = URI(url)
    require(uri.getScheme == "postgres" || uri.getScheme == "postgresql", s"DATABASE_URL must be a postgres:// URL")
    def decode(s: String) = if s == null then "" else URLDecoder.decode(s.replace("+", "%2B"), UTF_8)
    val (user, password) = Option(uri.getRawUserInfo).fold(("postgres", "")): info =>
      info.indexOf(':') match
        case -1 => (decode(info), "")
        case i => (decode(info.substring(0, i)), decode(info.substring(i + 1)))
    val database = Option(uri.getRawPath).map(_.stripPrefix("/")).filter(_.nonEmpty).fold(user)(decode)
    PgConfig(Option(uri.getHost).getOrElse("127.0.0.1"), if uri.getPort > 0 then uri.getPort else 5432, user, password, database)

/** A prepared statement: its SQL and the types of its parameters, prepared on every connection as `s<id>`. */
final class Statement(val id: Int, val sql: String, val paramTypes: Array[Int]):
  private[conduit] val name: Array[Byte] = s"s$id".getBytes(US_ASCII)

/** Postgres's types for the parameters the server sends (`pg_type.oid`). */
object Oid:
  val Bool = 16
  val Int8 = 20
  val Int4 = 23
  val Text = 25
  val TextArray = 1009
  val Int8Array = 1016

/** An error Postgres reported: its SQLSTATE and message. Codes starting with `08` are the connection's own. */
final class PgError(val code: String, val message: String):
  def isUniqueViolation: Boolean = code == "23505"
  override def toString: String = s"$code: $message"

object PgError:
  /** No connection could take the request. */
  val Unavailable = PgError("08006", "no connection to Postgres")
  val ConnectionLost = PgError("08006", "the connection to Postgres was lost")
  /** The query's client went away while it waited: it was never sent. */
  val Abandoned = PgError("57014", "abandoned before it was sent")

/** A packed batch's rows for all its queries ([[PgQuery.packed]]): kept for as long as the batch's answer lasts. */
abstract class PgPacked:
  def row(row: PgRow): Unit
  /** The batch is answered. */
  def release(): Unit

/** What a request asks of Postgres: one or more statements sent with one Sync (so they run in one implicit
  * transaction, committed before Postgres says it is ready again), and what to do with the replies. Every callback
  * runs on the event loop the request came in on, which owns the connection.
  */
abstract class PgQuery:
  /** The next query in its connection's queue, or its pool's. */
  private[conduit] var nextQuery: PgQuery = null
  /** When it started waiting in its pool's queue: a count. */
  private[conduit] var seq = 0L

  /** Whether it writes: it then goes to its pool's write connection, if it has one, which commits the writes waiting
    * for it together ([[WriteGroup]]), and the reads pipelined on the other connections never wait for a commit.
    */
  def write: Boolean = false

  /** Forgets the replies so far: the group of writes it went out in was rolled back, and it goes out again alone. */
  def reset(): Unit = ()

  /** The kind of batch it may run in, with other queries of its kind that wait for a connection, or null. A query
    * that has one is a single statement whose parameters [[int8Param]] and [[textParam]] give.
    */
  def batch: Sql.Batch = null

  /** Its `p`-th parameter (from 0), an `int8`, for a batch. */
  def int8Param(p: Int): Long = 0

  /** Its `p`-th parameter (from 0), a `text`, for a batch. */
  def textParam(p: Int): String = null

  /** Whether nobody waits for the answer any more: a query still waiting for a connection then isn't sent (under
    * overload, the clients that gave up would otherwise take Postgres's time from those still waiting).
    */
  def abandoned: Boolean = false

  /** Writes the query's Bind and Execute messages (not the Sync). */
  def send(w: PgWriter): Unit

  /** A row of the result of the query's `statement`-th statement, from 0. Valid during the call only. */
  def row(statement: Int, row: PgRow): Unit

  /** For a packed batch ([[Sql.Batch]] `packed`), made by its first query when the first of the rows for all of
    * them arrives: what holds those rows for the batch's queries.
    */
  def packed(): PgPacked = null

  /** In a packed batch, the query's own row, with the batch's rows for all (null if there were none). */
  def row(statement: Int, row: PgRow, @unused packed: PgPacked): Unit = this.row(statement, row)

  /** Postgres has answered all of the query and committed it: `error` is null, or why it failed, in which case
    * its transaction was rolled back.
    */
  def done(error: PgError): Unit

/** A row of a result, read in place in the connection's receive buffer: every column in binary format. */
final class PgRow:
  private var buf: ByteBuf = null
  private var offsets = new Array[Int](32)
  private var lengths = new Array[Int](32)
  private var count = 0

  /** Reads the DataRow message whose content starts at `at`. */
  private[conduit] def load(from: ByteBuf, at: Int): Unit =
    buf = from
    count = from.getUnsignedShort(at)
    if offsets.length < count then
      offsets = new Array[Int](count)
      lengths = new Array[Int](count)
    var p = at + 2
    var i = 0
    while i < count do
      val n = from.getInt(p)
      offsets(i) = p + 4
      lengths(i) = n
      p += 4 + math.max(n, 0)
      i += 1

  def columns: Int = count
  def isNull(i: Int): Boolean = lengths(i) < 0
  def int8(i: Int): Long = buf.getLong(offsets(i))
  def int4(i: Int): Int = buf.getInt(offsets(i))
  def bool(i: Int): Boolean = buf.getByte(offsets(i)) != 0
  def string(i: Int): String = if lengths(i) < 0 then null else buf.toString(offsets(i), lengths(i), UTF_8)

  /** A `text` column as a JSON string. */
  def text(i: Int, out: Out): Unit = out.jsonString(buf, offsets(i), lengths(i))

  /** A `text` column as a JSON string, or `null`. */
  def textOrNull(i: Int, out: Out): Unit = if lengths(i) < 0 then out.nul() else out.jsonString(buf, offsets(i), lengths(i))

  /** A `timestamptz` column as the spec's JSON timestamp. */
  def timestamp(i: Int, out: Out): Unit = out.timestamp(buf.getLong(offsets(i)))

  /** How many elements a one-dimensional `int8[]` column has: 0 if it is null. */
  def int8ArrayLength(i: Int): Int =
    if lengths(i) < 0 || buf.getInt(offsets(i)) == 0 then 0 else buf.getInt(offsets(i) + 12)

  /** Element `k` of a one-dimensional `int8[]` column without nulls (each element its length, then its 8 bytes). */
  def int8ArrayAt(i: Int, k: Int): Long = buf.getLong(offsets(i) + 24 + 12 * k)

  /** Whether a one-dimensional `int8[]` column without nulls has `value`. */
  def int8ArrayHas(i: Int, value: Long): Boolean =
    val n = int8ArrayLength(i)
    var k = 0
    while k < n && int8ArrayAt(i, k) != value do k += 1
    k < n

  /** A one-dimensional `text[]` column as a JSON array of strings (Postgres's binary array: dimensions, a flag for
    * nulls, the element type, each dimension's size and lower bound, then the elements, each with its length).
    */
  def textArray(i: Int, out: Out): Unit =
    out.byte('[')
    val at = offsets(i)
    if buf.getInt(at) > 0 then
      val n = buf.getInt(at + 12)
      var p = at + 20
      var k = 0
      while k < n do
        val length = buf.getInt(p)
        if k > 0 then out.byte(',')
        if length < 0 then out.nul() else out.jsonString(buf, p + 4, length)
        p += 4 + math.max(length, 0)
        k += 1
    out.byte(']')

/** Writes frontend messages into a buffer: a query's Binds and Executes, then the connection's Sync. */
final class PgWriter:
  private[conduit] var buf: ByteBuf = null
  private var bindStart = 0
  private var paramCountAt = 0
  private var params = 0
  /** The Executes written so far: each is one statement, whose replies end with a CommandComplete. */
  private[conduit] var executes = 0

  /** Starts a Bind of `statement` to the unnamed portal: parameters follow, then [[execute]]. */
  def bind(statement: Statement): PgWriter =
    bindStart = buf.writerIndex
    buf.writeByte('B').writeInt(0)
    buf.writeByte(0) // the unnamed portal
    buf.writeBytes(statement.name).writeByte(0)
    buf.writeShort(1).writeShort(1) // every parameter in binary
    paramCountAt = buf.writerIndex
    buf.writeShort(0)
    params = 0
    this

  def int8(value: Long): PgWriter =
    buf.writeInt(8).writeLong(value)
    params += 1
    this

  def int4(value: Int): PgWriter =
    buf.writeInt(4).writeInt(value)
    params += 1
    this

  def nul(): PgWriter =
    buf.writeInt(-1)
    params += 1
    this

  /** A `text` parameter, as UTF-8. */
  def text(value: String): PgWriter =
    val at = buf.writerIndex
    buf.writeInt(0)
    val n = ByteBufUtil.writeUtf8(buf, value)
    buf.setInt(at, n)
    params += 1
    this

  def textOrNull(value: String): PgWriter = if value == null then nul() else text(value)

  /** An `int8[]` parameter of `n` elements, the `i`-th `value(i)`. */
  def int8Array(n: Int, value: Int => Long): PgWriter =
    buf.writeInt(20 + 12 * n)
    buf.writeInt(1).writeInt(0).writeInt(Oid.Int8) // one dimension, no nulls, of int8
    buf.writeInt(n).writeInt(1) // its size and lower bound
    var i = 0
    while i < n do
      buf.writeInt(8).writeLong(value(i))
      i += 1
    params += 1
    this

  /** A `text[]` parameter of `n` elements, the `i`-th `value(i)`, without nulls. */
  def textArray(n: Int, value: Int => String): PgWriter =
    val at = buf.writerIndex
    buf.writeInt(0)
    buf.writeInt(1).writeInt(0).writeInt(Oid.Text)
    buf.writeInt(n).writeInt(1)
    var i = 0
    while i < n do
      val lengthAt = buf.writerIndex
      buf.writeInt(0)
      buf.setInt(lengthAt, ByteBufUtil.writeUtf8(buf, value(i)))
      i += 1
    buf.setInt(at, buf.writerIndex - at - 4)
    params += 1
    this

  /** A `text[]` parameter, one-dimensional, without nulls. */
  def textArray(values: collection.Seq[String]): PgWriter =
    val at = buf.writerIndex
    buf.writeInt(0)
    buf.writeInt(1).writeInt(0).writeInt(Oid.Text) // one dimension, no nulls, of text
    buf.writeInt(values.length).writeInt(1) // its size and lower bound
    for value <- values do
      val lengthAt = buf.writerIndex
      buf.writeInt(0)
      buf.setInt(lengthAt, ByteBufUtil.writeUtf8(buf, value))
    buf.setInt(at, buf.writerIndex - at - 4)
    params += 1
    this

  /** Ends the Bind (every result column in binary) and executes the portal. */
  def execute(): Unit =
    buf.writeShort(1).writeShort(1)
    buf.setShort(paramCountAt, params)
    buf.setInt(bindStart + 1, buf.writerIndex - bindStart - 1)
    buf.writeBytes(Execute)
    executes += 1

  private[conduit] def sync(): Unit = buf.writeBytes(Sync)

  private val Execute = Array[Byte]('E', 0, 0, 0, 9, 0, 0, 0, 0, 0) // the unnamed portal, all rows
  private val Sync = Array[Byte]('S', 0, 0, 0, 4)

/** One connection to Postgres, used by one event loop only. Startup sends the session's settings with the
  * login, authenticates (SCRAM-SHA-256, MD5 or a plain password, whichever the server asks for) and prepares every
  * statement; then it runs queries pipelined: each one's messages go out as soon as it is submitted (flushed once
  * per pass of the event loop), and replies come back in order, so the queries in flight are a queue.
  */
final class PgConnection(pool: PgPool, config: PgConfig, statements: collection.IndexedSeq[Statement]) extends ByteToMessageDecoder:
  import PgConnection.*

  private var ctx: ChannelHandlerContext = null
  /** One of its pool's write connections ([[PgQuery.write]]). */
  private[conduit] var writes = false
  /** Its channel, from when it starts connecting. */
  private[conduit] var channel: Channel = null
  /** Prepared and serving. */
  private[conduit] var ready = false
  private[conduit] var inFlight = 0
  private var first: PgQuery = null
  private var last: PgQuery = null
  /** The statement of the oldest query whose results are arriving. */
  private var statement = 0
  private var error: PgError = null
  private val row = PgRow()
  private val writer = PgWriter()
  private var flushScheduled = false
  private val flush: Runnable = () => flushNow()
  private var scram: Scram = null
  /** Logged in, and the statements sent to be prepared. */
  private var preparing = false
  /** Completed when the connection is prepared and serving, or failed if it couldn't get there. */
  private[conduit] val started = CompletableFuture[Unit]()

  override def channelActive(ctx: ChannelHandlerContext): Unit =
    this.ctx = ctx
    val buf = ctx.alloc().buffer(256)
    buf.writeInt(0).writeInt(196608) // protocol 3.0
    def param(name: String, value: String): Unit =
      buf.writeBytes(name.getBytes(UTF_8)).writeByte(0).writeBytes(value.getBytes(UTF_8)).writeByte(0)
    param("user", config.user)
    param("database", config.database)
    param("application_name", "conduit")
    param("client_encoding", "UTF8")
    for (name, value) <- SessionSettings do param(name, value)
    buf.writeByte(0)
    buf.setInt(0, buf.writerIndex)
    ctx.writeAndFlush(buf)
    super.channelActive(ctx)

  /** Sends `q` now (flushed at the end of this pass of the event loop) and queues it for its replies. */
  private[conduit] def submit(q: PgQuery): Unit =
    if writer.buf == null then writer.buf = ctx.alloc().ioBuffer(4096)
    q.send(writer)
    writer.sync()
    q.nextQuery = null
    if last == null then first = q else last.nextQuery = q
    last = q
    inFlight += 1
    if !flushScheduled then
      flushScheduled = true
      ctx.channel.eventLoop.execute(flush)

  private def flushNow(): Unit =
    flushScheduled = false
    val buf = writer.buf
    if buf != null then
      writer.buf = null
      ctx.writeAndFlush(buf, ctx.voidPromise())

  override protected def decode(ctx: ChannelHandlerContext, in: ByteBuf, out: util.List[AnyRef]): Unit =
    while in.readableBytes >= 5 do
      val start = in.readerIndex
      val length = in.getInt(start + 1)
      if in.readableBytes < length + 1 then return
      message(in.getByte(start), in, start + 5, start + 1 + length)
      in.readerIndex(start + 1 + length)

  private def message(kind: Byte, in: ByteBuf, at: Int, end: Int): Unit = kind match
    case 'D' =>
      if error == null then
        row.load(in, at)
        try first.row(statement, row)
        catch case NonFatal(e) => error = clientError(e)
    case 'C' | 'I' => statement += 1 // CommandComplete, EmptyQueryResponse
    case '2' | '1' | 'n' | 't' | 'T' | '3' | 's' => () // BindComplete, ParseComplete, NoData, descriptions, CloseComplete, PortalSuspended
    case 'Z' => readyForQuery()
    case 'E' =>
      val e = errorResponse(in, at, end)
      if ready then error = e
      else fail(s"Postgres refused the connection or a statement: $e")
    case 'N' | 'S' | 'K' | 'A' => () // notices, parameter status, the cancel key, notifications
    case 'R' => authentication(in, at, end)
    case other => fail(s"unexpected message from Postgres: '${other.toChar}'")

  private def readyForQuery(): Unit =
    if ready && first == null then fail("Postgres answered a query nobody sent")
    else if ready then
      val q = first
      first = q.nextQuery
      if first == null then last = null
      q.nextQuery = null
      inFlight -= 1
      statement = 0
      val e = error
      error = null
      try q.done(e)
      catch case NonFatal(t) => Log.error("request failed", t)
      pool.completed(this)
    else if !preparing then
      // Logged in: prepare every statement, all in one go.
      preparing = true
      val buf = ctx.alloc().buffer(16 * 1024)
      for s <- statements do
        val start = buf.writerIndex
        buf.writeByte('P').writeInt(0)
        buf.writeBytes(s.name).writeByte(0)
        buf.writeBytes(s.sql.getBytes(UTF_8)).writeByte(0)
        buf.writeShort(s.paramTypes.length)
        for t <- s.paramTypes do buf.writeInt(t)
        buf.setInt(start + 1, buf.writerIndex - start - 1)
      buf.writeBytes(Array[Byte]('S', 0, 0, 0, 4))
      ctx.writeAndFlush(buf)
    else
      ready = true
      started.complete(())
      pool.completed(this)

  private def authentication(in: ByteBuf, at: Int, end: Int): Unit = in.getInt(at) match
    case 0 => () // AuthenticationOk
    case 3 => passwordMessage(config.password.getBytes(UTF_8)) // cleartext
    case 5 => // MD5: md5(md5(password + user) + salt), in hex
      val md5 = MessageDigest.getInstance("MD5")
      val inner = ByteBufUtil.hexDump(md5.digest((config.password + config.user).getBytes(UTF_8)))
      md5.update(inner.getBytes(US_ASCII))
      md5.update(ByteBufUtil.getBytes(in, at + 4, 4))
      passwordMessage(("md5" + ByteBufUtil.hexDump(md5.digest())).getBytes(US_ASCII))
    case 10 => // SASL: the server's mechanisms
      val mechanisms = in.toString(at + 4, end - at - 4, UTF_8).split('\u0000').toSet
      if !mechanisms("SCRAM-SHA-256") then fail(s"no supported SASL mechanism among $mechanisms")
      else
        scram = Scram(config.password)
        val first = scram.clientFirst.getBytes(UTF_8)
        val mechanism = "SCRAM-SHA-256".getBytes(US_ASCII)
        val buf = ctx.alloc().buffer(64 + first.length)
        buf.writeByte('p').writeInt(4 + mechanism.length + 1 + 4 + first.length)
        buf.writeBytes(mechanism).writeByte(0).writeInt(first.length).writeBytes(first)
        ctx.writeAndFlush(buf)
    case 11 => // SASLContinue: the server-first-message
      val reply = scram.clientFinal(in.toString(at + 4, end - at - 4, UTF_8))
      if reply == null then fail("the server's SCRAM nonce doesn't extend ours")
      else saslResponse(reply.getBytes(UTF_8))
    case 12 => // SASLFinal: the server's signature
      if !scram.verify(in.toString(at + 4, end - at - 4, UTF_8)) then fail("the server's SCRAM signature is wrong")
    case other => fail(s"unsupported authentication method $other")

  /** A PasswordMessage: the password, or its MD5 form, as a C string. */
  private def passwordMessage(bytes: Array[Byte]): Unit =
    val buf = ctx.alloc().buffer(6 + bytes.length)
    buf.writeByte('p').writeInt(4 + bytes.length + 1).writeBytes(bytes).writeByte(0)
    ctx.writeAndFlush(buf)

  /** A SASLResponse: the same message type, its data as it is. */
  private def saslResponse(bytes: Array[Byte]): Unit =
    val buf = ctx.alloc().buffer(5 + bytes.length)
    buf.writeByte('p').writeInt(4 + bytes.length).writeBytes(bytes)
    ctx.writeAndFlush(buf)

  /** The connection failed: fails the startup with `why` if it is still under way, else logs it; then closes. */
  private def fail(why: String): Unit =
    if !started.isDone then started.completeExceptionally(IllegalStateException(why))
    else Log.warn("Postgres connection failed", "error" -> why)
    ctx.close()

  override def channelInactive(ctx: ChannelHandlerContext): Unit =
    val wasReady = ready
    ready = false
    if !started.isDone then started.completeExceptionally(IllegalStateException("Postgres closed the connection"))
    // Whatever was in flight won't be answered: it may or may not have committed.
    var q = first
    first = null
    last = null
    inFlight = 0
    while q != null do
      val next = q.nextQuery
      q.nextQuery = null
      try q.done(PgError.ConnectionLost)
      catch case NonFatal(t) => Log.error("request failed", t)
      q = next
    if writer.buf != null then
      writer.buf.release()
      writer.buf = null
    if wasReady then pool.lost(this)
    super.channelInactive(ctx)

  override def exceptionCaught(ctx: ChannelHandlerContext, cause: Throwable): Unit =
    Log.error("Postgres connection error", cause)
    ctx.close()

object PgConnection:
  /** Settings for the server's own sessions, sent with the login (rule 2 allows session-level settings): every
    * statement's generic plan instead of planning it again for the first executions, no JIT compilation or parallel
    * workers, which cost more than they save on queries this small, and no Memoize, which in a batch ([[Sql.Batch]])
    * would hand a request rows cached for another's identical look-up: a batch shares only where it says so, in its
    * shared and packed kinds (rule 5).
    */
  private val SessionSettings = Seq(
    "plan_cache_mode" -> "force_generic_plan",
    "jit" -> "off",
    "max_parallel_workers_per_gather" -> "0",
    "enable_memoize" -> "off",
  )

  private def clientError(e: Throwable): PgError =
    Log.error("reading a row failed", e)
    PgError("XX000", s"reading a row failed: $e")

  /** An ErrorResponse's fields: its SQLSTATE (`C`) and message (`M`). */
  private def errorResponse(in: ByteBuf, at: Int, end: Int): PgError =
    var code = "XX000"
    var message = ""
    var p = at
    while p < end && in.getByte(p) != 0 do
      val field = in.getByte(p)
      val stop = in.indexOf(p + 1, end, 0.toByte)
      val value = in.toString(p + 1, stop - p - 1, UTF_8)
      if field == 'C' then code = value
      else if field == 'M' then message = value
      p = stop + 1
    PgError(code, message)

/** A loop's connections to Postgres.
  *
  * With `drain`, a read goes to a read connection that has nothing in flight; if none is idle it waits in the pool's
  * queue, and the next connection to finish takes the `roundSize` oldest reads that wait, whatever their kind (with 0,
  * up to `batchSize` of every kind), each kind's together, up to `batchSize` of a kind in one statement
  * ([[Sql.Batch]]): one round of statements in flight per connection. Without it, a read goes to the connection with
  * the fewest in flight, up to `depth`, and a connection with room takes the oldest waiting read's kind. No timer
  * either way: a batch is what accumulated while the connections were busy, and nothing waits for one at a light load.
  *
  * Writes ([[PgQuery.write]]) go to the `writers` write connections, one transaction in flight on each: those that
  * wait go out together when one is free, up to `groupSize` of them in one transaction ([[WriteGroup]]), again no
  * timer, so a group is what accumulated during the last one's commit. Without write connections, writes go as reads
  * do. A lost connection is replaced; meanwhile the others serve.
  */
final class PgPool(
    loop: EventLoop,
    config: PgConfig,
    statements: collection.IndexedSeq[Statement],
    count: Int,
    depth: Int,
    channel: Class[? <: Channel],
    batchSize: Int = 1,
    writers: Int = 0,
    groupSize: Int = 1,
    drain: Boolean = false,
    roundSize: Int = 0,
    gatherMicros: Int = 0,
):
  /** The `count` read connections, then the write connections. */
  private val connections = new Array[PgConnection](count + writers)
  /** The waiting reads: queue 0 for those that run alone, then one per kind of batch. */
  private val queues = Array.fill(Sql.batchKinds.length + 1)(PgPool.Queue())
  private var waiting = 0
  /** With `gatherMicros` (and `drain` and `roundSize`): since when the oldest waiting read has waited
    * (`System.nanoTime`), and whether a timer will look again.
    */
  private val gathering = drain && roundSize > 0 && gatherMicros > 0
  private val gatherNanos = gatherMicros * 1000L
  private var waitingSince = 0L
  private var timer = false
  private var arrivals = 0L
  private val batch = new Array[PgQuery](math.max(1, batchSize))
  /** With `roundSize`: each queue's next query to count, and how many of each a round takes. */
  private val cursors = new Array[PgQuery](queues.length)
  private val taking = new Array[Int](queues.length)
  /** The writes waiting for a write connection. */
  private val writeQueue = PgPool.Queue()
  private var waitingWrites = 0
  private val group = new Array[PgQuery](math.max(1, groupSize))

  def size: Int = connections.length

  // Counts since the last `stats()`: queries, those that waited, the batches they went out in and the queries in them,
  // and the most waiting at once; the writes, the groups they went out in and the writes in them, and those sent again
  // after their group failed.
  private var submitted, queued, batches, batched, mostWaiting, writes, groups, grouped, retried = 0L

  /** The counts since the last call, for the log (`-Dconduit.stats=true`). */
  def stats(): Seq[(String, Any)] =
    val s = Seq("queries" -> submitted, "waited" -> queued, "batches" -> batches, "inBatches" -> batched, "mostWaiting" -> mostWaiting,
      "writes" -> writes, "groups" -> groups, "inGroups" -> grouped, "retried" -> retried)
    submitted = 0; queued = 0; batches = 0; batched = 0; mostWaiting = waiting
    writes = 0; groups = 0; grouped = 0; retried = 0
    s

  /** Opens every connection; completes once all are prepared. */
  def start(): CompletableFuture[Unit] =
    val all = (0 until size).map(open)
    CompletableFuture.allOf(all*).thenApply(_ => ())

  /** Closes every connection (a start that failed). */
  def close(): Unit = connections.foreach(c => if c != null && c.channel != null then c.channel.close())

  private def open(i: Int): CompletableFuture[Unit] =
    val c = PgConnection(this, config, statements)
    c.writes = i >= count
    connections(i) = c
    val connecting = Bootstrap()
      .group(loop)
      .channel(channel)
      .option(ChannelOption.TCP_NODELAY, java.lang.Boolean.TRUE)
      .option(ChannelOption.CONNECT_TIMEOUT_MILLIS, Integer.valueOf(10_000))
      .handler(c)
      .connect(config.host, config.port)
    c.channel = connecting.channel
    connecting.addListener((f: io.netty.channel.ChannelFuture) =>
      if !f.isSuccess then c.started.completeExceptionally(f.cause)
    )
    c.started

  /** Sends `q` on a connection, or queues it. On the loop's thread. */
  def submit(q: PgQuery): Unit =
    submitted += 1
    if q.write && writer(idle = false) != null then submitWrite(q) else submitRead(q)

  /** Sends `q` on the least busy read connection, or queues it. */
  private def submitRead(q: PgQuery): Unit =
    var best: PgConnection = null
    var i = 0
    while i < count do
      val c = connections(i)
      if c.ready && (best == null || c.inFlight < best.inFlight) then best = c
      i += 1
    if best == null then q.done(PgError.Unavailable)
    else if !gathering && (if drain then best.inFlight == 0 else best.inFlight < depth) && waiting == 0 then best.submit(q)
    else
      queued += 1
      q.seq = arrivals
      arrivals += 1
      queues(if q.batch == null || batchSize <= 1 then 0 else q.batch.id).add(q)
      waiting += 1
      if waiting > mostWaiting then mostWaiting = waiting
      if gathering then
        if waiting == 1 then waitingSince = System.nanoTime()
        gather()

  /** Sends `q` on a free write connection, or queues it for the next group. */
  private def submitWrite(q: PgQuery): Unit =
    writes += 1
    val c = if waitingWrites == 0 then writer(idle = true) else null
    if c != null then c.submit(q)
    else
      writeQueue.add(q)
      waitingWrites += 1

  /** A ready write connection, with nothing in flight if `idle`, or null. */
  private def writer(idle: Boolean): PgConnection =
    var i = count
    while i < connections.length do
      val c = connections(i)
      if c.ready && (!idle || c.inFlight == 0) then return c
      i += 1
    null

  /** `c` has answered a query, or become ready: it takes the oldest waiting ones it has room for, a kind's waiting
    * queries together, or, a write connection, the waiting writes. With `drain`, a read connection takes queries only
    * when it has none in flight, and then every kind that waits, each kind's together: one round of statements in
    * flight per connection.
    */
  private[conduit] def completed(c: PgConnection): Unit =
    if c.writes then sendWrites(c)
    else if gathering then gather()
    else if drain then
      if c.ready && c.inFlight == 0 && waiting > 0 then
        if roundSize > 0 then sendOldest(c)
        else
          var i = 0
          while i < queues.length && waiting > 0 do
            if queues(i).first != null then sendKind(c, i, batch.length)
            i += 1
    else while waiting > 0 && c.ready && c.inFlight < depth do
      var oldest = -1
      var i = 0
      while i < queues.length do
        if queues(i).first != null && (oldest < 0 || queues(i).first.seq < queues(oldest).first.seq) then oldest = i
        i += 1
      sendKind(c, oldest, if oldest == 0 then 1 else batch.length)

  /** With `gatherMicros`, a round goes out on an idle read connection once the oldest waiting read has waited
    * `gatherMicros`, or once a round's worth waits ([[sendOldest]]). At a light load reads wait for company, so that
    * batches are larger than what arrived while every connection was busy; at saturation they have waited that long
    * for a connection already, and one that comes free takes them at once, as without a window. Reads left after a
    * round have waited as long as the round's oldest. Called when a read waits, when a connection is free, and on
    * the timer.
    */
  private def gather(): Unit =
    while waiting > 0 do
      var c: PgConnection = null
      var i = 0
      while i < count && c == null do
        if connections(i).ready && connections(i).inFlight == 0 then c = connections(i)
        i += 1
      if c == null then return
      val left = waitingSince + gatherNanos - System.nanoTime()
      if left > 0 && waiting < roundSize then
        if !timer then
          timer = true
          loop.schedule((() => { timer = false; gather() }): Runnable, left, TimeUnit.NANOSECONDS)
        return
      sendOldest(c)

  /** Sends the `roundSize` oldest waiting reads on `c`, whatever their kind, each kind's together, so that every kind
    * waits alike. Taking every kind's, up to `batchSize` of each, let the most frequent kinds fall rounds behind the
    * others under overload.
    */
  private def sendOldest(c: PgConnection): Unit =
    var i = 0
    if waiting <= roundSize then
      // All of them: no need to find the oldest.
      while i < queues.length do
        while queues(i).first != null do sendKind(c, i, if i == 0 then waiting else batch.length)
        i += 1
      return
    while i < queues.length do
      cursors(i) = queues(i).first
      taking(i) = 0
      i += 1
    var n = 0
    var oldest = 0
    while n < roundSize && oldest >= 0 do
      oldest = -1
      i = 0
      while i < queues.length do
        val q = cursors(i)
        if q != null && (oldest < 0 || q.seq < cursors(oldest).seq) then oldest = i
        i += 1
      if oldest >= 0 then
        cursors(oldest) = cursors(oldest).nextQuery
        taking(oldest) += 1
        n += 1
    i = 0
    while i < queues.length do
      cursors(i) = null
      while taking(i) > 0 do
        val most = if i == 0 then taking(i) else math.min(taking(i), batch.length)
        sendKind(c, i, most)
        taking(i) -= most
      i += 1

  /** Sends up to `most` of queue `i`'s queries on `c`: from queue 0 each its own statement, from the others as one
    * batch (`most` at most `batchSize`).
    */
  private def sendKind(c: PgConnection, i: Int, most: Int): Unit =
    val queue = queues(i)
    var n = 0
    while queue.first != null && n < most do
      val q = queue.take()
      waiting -= 1
      if q.abandoned then q.done(PgError.Abandoned)
      else
        if i == 0 then c.submit(q) else batch(n) = q
        n += 1
    if i != 0 then
      if n == 1 then c.submit(batch(0))
      else if n > 1 then
        batches += 1
        batched += n
        c.submit(BatchQuery(batch(0).batch, java.util.Arrays.copyOf(batch, n)))
      java.util.Arrays.fill(batch.asInstanceOf[Array[AnyRef]], null)

  /** `c`, a write connection, takes the waiting writes if it has nothing in flight: up to `groupSize` in one
    * transaction.
    */
  private def sendWrites(c: PgConnection): Unit =
    if c.ready && c.inFlight == 0 then
      var n = 0
      while writeQueue.first != null && n < group.length do
        val q = writeQueue.take()
        waitingWrites -= 1
        if q.abandoned then q.done(PgError.Abandoned)
        else
          group(n) = q
          n += 1
      if n == 1 then c.submit(group(0))
      else if n > 1 then
        groups += 1
        grouped += n
        c.submit(WriteGroup(this, java.util.Arrays.copyOf(group, n)))
      java.util.Arrays.fill(group.asInstanceOf[Array[AnyRef]], null)

  /** The writes of a group Postgres rolled back for one's error: each goes out again alone, in its own transaction,
    * so that only the one at fault fails.
    */
  private[conduit] def retry(queries: Array[PgQuery]): Unit =
    retried += queries.length
    for q <- queries do
      q.reset()
      val c = writer(idle = false)
      if c != null then c.submit(q) else submitRead(q)

  /** `c` was lost: open another in its place, retrying every second, and fail what waits if none is left. */
  private[conduit] def lost(c: PgConnection): Unit =
    Log.warn("lost a connection to Postgres, reconnecting")
    val i = connections.indexOf(c)
    if !connections.exists(_.ready) then
      waiting = 0
      waitingWrites = 0
      for queue <- queues :+ writeQueue do
        while queue.first != null do queue.take().done(PgError.Unavailable)
    else if c.writes && writer(idle = false) == null then
      // Until a write connection is back, the writes go as reads do.
      while writeQueue.first != null do
        waitingWrites -= 1
        submitRead(writeQueue.take())
    def retry(): Unit =
      open(i).whenComplete((_, e) =>
        if e != null then loop.schedule((() => retry()): Runnable, 1, TimeUnit.SECONDS)
      )
    loop.schedule((() => retry()): Runnable, 100, TimeUnit.MILLISECONDS)

object PgPool:
  /** Queries waiting, oldest first. */
  private final class Queue:
    var first: PgQuery = null
    private var last: PgQuery = null

    def add(q: PgQuery): Unit =
      q.nextQuery = null
      if last == null then first = q else last.nextQuery = q
      last = q

    def take(): PgQuery =
      val q = first
      first = q.nextQuery
      if first == null then last = null
      q.nextQuery = null
      q

/** Queries of one kind sent as one statement ([[Sql.Batch]]). Each of the statement's parameters is an array holding
  * that parameter from every query, and each row goes back to its query by the batch's last column: the query's place
  * in the batch, from 1. A shared batch's rows go to every query; a packed batch's rows for all of them (0 in the last
  * column, ahead of the queries' own) to what its first query keeps them in ([[PgQuery.packed]]), and each query's
  * own with them.
  */
private final class BatchQuery(kind: Sql.Batch, queries: Array[PgQuery]) extends PgQuery:
  private val n = queries.length
  private var shared: PgPacked = null

  def send(w: PgWriter): Unit =
    w.bind(kind.batched)
    val types = kind.paramTypes
    if !kind.shared then
      var p = 0
      while p < types.length do
        val param = p
        if types(p) == Oid.Int8 then w.int8Array(n, i => queries(i).int8Param(param))
        else w.textArray(n, i => queries(i).textParam(param))
        p += 1
    w.execute()

  def row(statement: Int, row: PgRow): Unit =
    if kind.shared then
      var i = 0
      while i < n do
        queries(i).row(0, row)
        i += 1
    else
      val i = row.int8(row.columns - 1).toInt
      if !kind.packed then queries(i - 1).row(0, row)
      else if i > 0 then queries(i - 1).row(0, row, shared)
      else
        if shared == null then shared = queries(0).packed()
        shared.row(row)

  def done(error: PgError): Unit =
    var i = 0
    while i < n do
      try queries(i).done(error)
      catch case NonFatal(t) => Log.error("request failed", t)
      i += 1
    if shared != null then shared.release()

/** Writes that waited for a write connection, sent as one transaction: their statements one after another and one
  * Sync, so one commit, and one WAL flush, for all of them (group commit); each row goes back to its query by its
  * statement's place. Every response is written after Postgres's ReadyForQuery for the group, after its commit
  * (rule 6). If a statement fails, Postgres rolls back the whole transaction: each query then goes out again alone
  * ([[PgPool.retry]]), so that only the one at fault fails.
  */
private[conduit] final class WriteGroup(pool: PgPool, queries: Array[PgQuery]) extends PgQuery:
  private val n = queries.length
  /** Where each query's statements start among the group's, and where the last one's end. */
  private val starts = new Array[Int](n + 1)
  /** The query whose rows are arriving. */
  private var current = 0

  def send(w: PgWriter): Unit =
    val first = w.executes
    var i = 0
    while i < n do
      starts(i) = w.executes - first
      queries(i).send(w)
      i += 1
    starts(n) = w.executes - first

  def row(statement: Int, row: PgRow): Unit =
    while current < n - 1 && statement >= starts(current + 1) do current += 1
    queries(current).row(statement - starts(current), row)

  def done(error: PgError): Unit =
    if error != null && !error.code.startsWith("08") then pool.retry(queries)
    else
      var i = 0
      while i < n do
        try queries(i).done(error)
        catch case NonFatal(t) => Log.error("request failed", t)
        i += 1

/** The client's side of SCRAM-SHA-256 (RFC 5802, 7677), as Postgres runs it: the user name goes in the startup
  * message, so the SCRAM one is empty, and there is no channel binding.
  */
private[conduit] final class Scram(password: String, user: String = "", nonce: String = Scram.newNonce()):
  private val firstBare = s"n=$user,r=$nonce"
  private var serverSignature: Array[Byte] = null

  def clientFirst: String = "n,," + firstBare

  /** The client-final-message for the server-first-message, or null if the server's nonce doesn't extend ours. */
  def clientFinal(serverFirst: String): String =
    val fields = serverFirst.split(',').map(f => f.take(1) -> f.drop(2)).toMap
    val serverNonce = fields.getOrElse("r", "")
    if !serverNonce.startsWith(nonce) then return null
    val salt = Base64.getDecoder.decode(fields("s"))
    val iterations = fields("i").toInt
    val salted = hi(password.getBytes(UTF_8), salt, iterations)
    val clientKey = hmac(salted, "Client Key".getBytes(US_ASCII))
    val storedKey = MessageDigest.getInstance("SHA-256").digest(clientKey)
    val withoutProof = s"c=biws,r=$serverNonce"
    val authMessage = s"$firstBare,$serverFirst,$withoutProof".getBytes(UTF_8)
    val signature = hmac(storedKey, authMessage)
    val proof = Array.tabulate(clientKey.length)(i => (clientKey(i) ^ signature(i)).toByte)
    serverSignature = hmac(hmac(salted, "Server Key".getBytes(US_ASCII)), authMessage)
    s"$withoutProof,p=${Base64.getEncoder.encodeToString(proof)}"

  /** Whether the server-final-message carries the signature only a server that knows the password can make. */
  def verify(serverFinal: String): Boolean =
    serverFinal.startsWith("v=") && MessageDigest.isEqual(Base64.getDecoder.decode(serverFinal.drop(2).takeWhile(_ != ',')), serverSignature)

  private def hmac(key: Array[Byte], data: Array[Byte]): Array[Byte] =
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(key, "HmacSHA256"))
    mac.doFinal(data)

  /** PBKDF2 with HMAC-SHA-256, one block. */
  private def hi(password: Array[Byte], salt: Array[Byte], iterations: Int): Array[Byte] =
    val mac = Mac.getInstance("HmacSHA256")
    mac.init(SecretKeySpec(password, "HmacSHA256"))
    var u = mac.doFinal(salt ++ Array[Byte](0, 0, 0, 1))
    val result = u.clone()
    for _ <- 1 until iterations do
      u = mac.doFinal(u)
      for j <- result.indices do result(j) = (result(j) ^ u(j)).toByte
    result

private[conduit] object Scram:
  def newNonce(): String =
    val bytes = new Array[Byte](18)
    SecureRandom().nextBytes(bytes)
    Base64.getEncoder.encodeToString(bytes)
