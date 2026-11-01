package conduit

import io.netty.buffer.{ByteBuf, ByteBufAllocator}
import io.netty.channel.{ChannelFutureListener, ChannelHandlerContext}

import java.io.IOException
import java.util

/** One event loop's open connections. Those with no request waiting are listed least recently active first: idle ones
  * are closed by one sweep a second instead of a timer per connection, and beyond `maxConnections` the longest-idle
  * ones are closed. A connection whose request waits for Postgres is off the list, so neither ever steps over it:
  * under overload nearly every connection waits, and an eviction that skipped them walked the whole list for every
  * connection accepted (300 µs at 100,000 connections). Past the limit with none idle, the loop is [[full]], and the
  * listening socket stops accepting until it isn't (`Main`), so `accept` never fails for want of a file descriptor.
  * Used on its event loop's thread only, but for [[full]].
  *
  * `requestDeadlineSeconds`: how long a request may take to arrive ([[RequestDecoder.deadlineSeconds]]), timed by
  * [[clock]]; none by default.
  */
final class Connections(
    idleTimeoutSeconds: Int,
    maxConnections: Int,
    val requestDeadlineSeconds: Long = Long.MaxValue,
):
  import Connections.*

  /** The connections with no request waiting, longest idle first. */
  private var oldest: Connection = null
  private var newest: Connection = null
  /** The open connections, waiting or not, but those already being closed. */
  private var count = 0
  @volatile private var atLimit = false
  /** A coarse clock in seconds, advanced by each sweep: precise enough for an idle timeout, and free to read. */
  private var now = 0L
  /** Connections evicted so far. */
  var evicted = 0L

  def size: Int = count

  /** Whether the loop holds `maxConnections` and none of them is idle: read by the listening socket's loop. */
  def full: Boolean = atLimit

  /** Seconds since the first sweep: the clock the idle timeout and the request deadline read. */
  private[conduit] def clock: Long = now

  /** Closes connections that have been idle longer than the timeout. Run once a second. */
  def sweep(): Unit =
    now += 1
    while oldest != null && now - oldest.lastActive > idleTimeoutSeconds do discard(oldest)
    update()

  private[conduit] def add(c: Connection): Unit =
    c.counted = true
    count += 1
    c.lastActive = now
    append(c)
    if count > maxConnections then evict()
    update()

  /** `c` has a request waiting: off the list until it has answered every request. */
  private[conduit] def busy(c: Connection): Unit =
    if c.linked then
      unlink(c)
      update()

  /** `c` has answered every request: back on the list, the most recently active. */
  private[conduit] def idle(c: Connection): Unit =
    c.lastActive = now
    if c.counted && !c.linked then
      append(c)
      update()

  /** `c` received something: the most recently active, if it is on the list. */
  private[conduit] def touch(c: Connection): Unit =
    c.lastActive = now
    if c.linked && (c ne newest) then
      unlink(c)
      append(c)

  /** A connection has closed. */
  private[conduit] def closed(c: Connection): Unit =
    if c.linked then unlink(c)
    if c.counted then
      c.counted = false
      count -= 1
    update()

  /** Closes the longest-idle connections, but the newest. A client that was evicted while idle reconnects on its next
    * request.
    */
  private def evict(): Unit =
    var n = 0
    while n < EvictionBatch && oldest != null && (oldest ne newest) do
      discard(oldest)
      n += 1
    evicted += n

  /** Closes `c`, counted as closed from now on: its descriptor is freed once the close completes. */
  private def discard(c: Connection): Unit =
    unlink(c)
    c.counted = false
    count -= 1
    c.close()

  private def update(): Unit =
    val reached = count >= maxConnections && (oldest == null || (oldest eq newest))
    if reached != atLimit then atLimit = reached

  private def append(c: Connection): Unit =
    c.prev = newest
    c.next = null
    if newest == null then oldest = c else newest.next = c
    newest = c
    c.linked = true

  private def unlink(c: Connection): Unit =
    if c.prev == null then oldest = c.next else c.prev.next = c.next
    if c.next == null then newest = c.prev else c.next.prev = c.prev
    c.prev = null
    c.next = null
    c.linked = false

object Connections:
  /** How many connections one eviction closes, so it doesn't run on every accept once the limit is reached. */
  private val EvictionBatch = 64

/** Each connection's one handler: keeps its place in [[Connections]], decodes its requests (it is a
  * [[RequestDecoder]]) and hands them to its loop's [[Api]]. Requests may be pipelined, and are answered by Postgres
  * in any order, so the connection queues their [[Call]]s and writes the responses in the order the requests came.
  */
final class Connection(connections: Connections, api: Api) extends RequestDecoder:
  import Connection.*

  private[conduit] var prev: Connection = null
  private[conduit] var next: Connection = null
  private[conduit] var linked = false
  /** Counted among its loop's connections: from its activation until it closes or is being closed. */
  private[conduit] var counted = false
  private[conduit] var lastActive = 0L
  private[conduit] var open = true
  private var ctx: ChannelHandlerContext = null
  /** The requests not answered yet, oldest first. */
  private var first: Call = null
  private var last: Call = null
  private var pending = 0
  /** In a read: responses ready now are flushed when it completes. */
  private var reading = false

  private[conduit] def alloc: ByteBufAllocator = ctx.alloc()

  override def channelActive(ctx: ChannelHandlerContext): Unit =
    this.ctx = ctx
    connections.add(this)
    super.channelActive(ctx)

  override def channelRead(ctx: ChannelHandlerContext, msg: AnyRef): Unit =
    connections.touch(this)
    reading = true
    super.channelRead(ctx, msg)

  override protected def received(ctx: ChannelHandlerContext, req: Request, out: util.List[AnyRef]): Unit =
    api.handle(this, req)

  override protected def deadlineSeconds: Long = connections.requestDeadlineSeconds

  override protected def clock: Long = connections.clock

  override def channelReadComplete(ctx: ChannelHandlerContext): Unit =
    super.channelReadComplete(ctx)
    reading = false
    ctx.flush()

  override def channelInactive(ctx: ChannelHandlerContext): Unit =
    open = false
    connections.closed(this)
    super.channelInactive(ctx)

  override def exceptionCaught(ctx: ChannelHandlerContext, cause: Throwable): Unit =
    cause match
      case _: IOException => () // the client went away
      case _ => Log.error("connection error", cause)
    ctx.close()

  private[conduit] def close(): Unit = ctx.close()

  /** `call` is the connection's newest request: answered after the ones before it. Past [[MaxPipelined]] waiting,
    * the connection stops reading until they are answered.
    */
  private[conduit] def enqueue(call: Call): Unit =
    call.nextCall = null
    if last == null then
      first = call
      connections.busy(this)
    else last.nextCall = call
    last = call
    pending += 1
    if pending == MaxPipelined then ctx.channel.config.setAutoRead(false)

  /** `call` has its response: writes it, and those after it that were waiting for it. */
  private[conduit] def answered(call: Call): Unit =
    if call ne first then return
    var wrote = false
    while first != null && first.response != null do
      val c = first
      first = c.nextCall
      if first == null then last = null
      c.nextCall = null
      pending -= 1
      if pending == MaxPipelined - 1 then ctx.channel.config.setAutoRead(true)
      write(c.response, c.ending ne Out.Ending.Close)
      c.response = null
      wrote = true
    if wrote then
      if first == null then connections.idle(this)
      if !reading then ctx.flush()

  /** Writes without a future when the connection stays open: a failed write still reaches `exceptionCaught`. On a
    * closed connection the response is dropped.
    */
  private def write(response: ByteBuf, keepAlive: Boolean): Unit =
    if !open then response.release()
    else if keepAlive then ctx.write(response, ctx.voidPromise())
    else ctx.write(response).addListener(ChannelFutureListener.CLOSE)

object Connection:
  /** Requests a connection may have waiting before it stops reading more. */
  private val MaxPipelined = 32
