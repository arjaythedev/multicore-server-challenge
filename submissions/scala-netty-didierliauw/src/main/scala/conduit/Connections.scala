package conduit

import io.netty.buffer.{ByteBuf, ByteBufAllocator}
import io.netty.channel.{ChannelFutureListener, ChannelHandlerContext}

import java.io.IOException
import java.util

/** One event loop's open connections, least recently active first. Idle ones are closed by one sweep a second
  * instead of a timer per connection, and beyond `maxConnections` the longest-idle ones are closed, so `accept`
  * never fails for want of a file descriptor. Used on its event loop's thread only.
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

  private var oldest: Connection = null
  private var newest: Connection = null
  private var count = 0
  /** A coarse clock in seconds, advanced by each sweep: precise enough for an idle timeout, and free to read. */
  private var now = 0L
  /** Connections evicted so far. */
  var evicted = 0L

  def size: Int = count

  /** Seconds since the first sweep: the clock the idle timeout and the request deadline read. */
  private[conduit] def clock: Long = now

  /** Closes connections that have been idle longer than the timeout. Run once a second. */
  def sweep(): Unit =
    now += 1
    while oldest != null && now - oldest.lastActive > idleTimeoutSeconds do
      val idle = oldest
      remove(idle)
      if idle.busy then touch(idle) // waiting for Postgres, not idle
      else idle.close()

  private[conduit] def add(c: Connection): Unit =
    c.lastActive = now
    append(c)
    count += 1
    if count > maxConnections then evict()

  /** A connection has closed. */
  private[conduit] def closed(c: Connection): Unit = remove(c)

  /** Closes the longest-idle connections. A client that was evicted while idle reconnects on its next request. */
  private def evict(): Unit =
    var n = 0
    var skipped = 0
    while n < EvictionBatch && oldest != null && oldest.ne(newest) && skipped < count do
      val idle = oldest
      if idle.busy then
        touch(idle)
        skipped += 1
      else
        remove(idle)
        idle.close()
        n += 1
    evicted += n

  private[conduit] def touch(c: Connection): Unit =
    c.lastActive = now
    if c.linked && (c ne newest) then
      unlink(c)
      append(c)
    else if !c.linked && c.open then
      append(c)
      count += 1

  private[conduit] def remove(c: Connection): Unit =
    if c.linked then
      unlink(c)
      count -= 1

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
  private[conduit] var lastActive = 0L
  private[conduit] var open = true
  private var ctx: ChannelHandlerContext = null
  /** The requests not answered yet, oldest first. */
  private var first: Call = null
  private var last: Call = null
  private var pending = 0
  /** In a read: responses ready now are flushed when it completes. */
  private var reading = false

  /** Whether a request of its is being answered. */
  private[conduit] def busy: Boolean = first != null

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
    if last == null then first = call else last.nextCall = call
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
      connections.touch(this)
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
