package conduit.platform

import conduit.http.ABANDONED_NANOS
import conduit.http.CLOSE
import conduit.http.CONTINUE_100
import conduit.http.ContextExchange
import conduit.http.EMPTY
import conduit.http.Exchange
import conduit.http.HttpConn
import conduit.http.HttpEngine
import conduit.http.KEEP
import conduit.http.KEEP_10
import conduit.http.MAX_BODY
import conduit.http.MAX_HEAD
import conduit.http.Method
import conduit.http.Out
import conduit.http.OutPool
import conduit.http.RESERVE
import conduit.http.putError
import conduit.http.putHead
import conduit.json.JsonWriter
import conduit.util.logSafe
import io.netty.bootstrap.ServerBootstrap
import io.netty.buffer.ByteBuf
import io.netty.buffer.ByteBufAllocator
import io.netty.channel.Channel
import io.netty.channel.ChannelFutureListener
import io.netty.channel.ChannelHandlerContext
import io.netty.channel.ChannelInboundHandlerAdapter
import io.netty.channel.ChannelInitializer
import io.netty.channel.ChannelOption
import io.netty.channel.IoHandlerFactory
import io.netty.channel.MultiThreadIoEventLoopGroup
import io.netty.channel.ServerChannel
import io.netty.channel.epoll.Epoll
import io.netty.channel.epoll.EpollIoHandler
import io.netty.channel.epoll.EpollServerSocketChannel
import io.netty.channel.unix.UnixChannelOption
import io.netty.handler.codec.TooLongFrameException
import io.netty.handler.codec.http.HttpContent
import io.netty.handler.codec.http.HttpDecoderConfig
import io.netty.handler.codec.http.HttpHeaderNames
import io.netty.handler.codec.http.HttpMethod
import io.netty.handler.codec.http.HttpRequest
import io.netty.handler.codec.http.HttpRequestDecoder
import io.netty.handler.codec.http.HttpUtil
import io.netty.handler.codec.http.HttpVersion
import io.netty.handler.codec.http.LastHttpContent
import io.netty.util.ResourceLeakDetector
import io.netty.util.concurrent.DefaultThreadFactory
import io.netty.util.concurrent.FastThreadLocal
import java.net.InetAddress
import java.net.InetSocketAddress
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicIntegerFieldUpdater
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.startCoroutine
import conduit.util.ByteBuf as Bytes

private const val NETTY_BACKLOG = 65535
private const val NETTY_READ_CHUNK = 64 * 1024

/**
 * JVM, HTTP_IO=netty or netty-http (lab A/B against [startEpollServer]): Netty 4.2 on its native epoll transport
 * (NETTY_TRANSPORT=io_uring: io_uring, see [ioUring]), [loops] event loops, each with its own SO_REUSEPORT listener
 * (the kernel spreads new connections over them, as in EpollHttp). The usual Netty tuning: the allocator chosen by
 * `-Dio.netty.allocator.type` (start.sh: pooled, NETTY_ALLOCATOR=adaptive for 4.2's new default), no leak detection
 * or buffer bounds checks (start.sh), TCP_NODELAY, header validation off, no aggregator, one write and flush per
 * response with a void promise.
 * - `netty`: Netty moves the bytes, our engine parses HTTP/1.1 and frames responses ([RawHandler]).
 * - `netty-http`: Netty's HTTP/1.1 decoder parses requests too ([HttpHandler]); responses keep our pre-rendered
 *   head (the encoder would allocate a headers object per response for the same bytes).
 * Handlers are coroutines started on the loop; a Postgres or bcrypt thread resumes them (Postgres rows are views into
 * that connection's receive buffer, valid until its next reply, so the JSON is rendered there), and the finished
 * bytes go to the connection's loop as one task. NETTY_HANDLER=vt (experiment): each request's handler starts on a
 * new virtual thread instead of the loop. Returns false (caller falls back) if no transport is available.
 */
internal fun startNettyServer(
    host: String,
    port: Int,
    loops: Int,
    engine: HttpEngine,
    codec: Boolean,
    vt: Boolean = getenv("NETTY_HANDLER") == "vt",
): Boolean {
    val t = transport() ?: return false
    ResourceLeakDetector.setLevel(ResourceLeakDetector.Level.DISABLED)
    val n = maxOf(1, loops)
    val group = MultiThreadIoEventLoopGroup(n, DefaultThreadFactory("http", true), t.factory)
    val decoder = HttpDecoderConfig().setMaxInitialLineLength(MAX_HEAD).setMaxHeaderSize(MAX_HEAD)
        .setMaxChunkSize(MAX_BODY).setValidateHeaders(false)
    val b = ServerBootstrap()
        .group(group)
        .channel(t.server)
        .option(ChannelOption.SO_BACKLOG, NETTY_BACKLOG)
        .option(ChannelOption.SO_REUSEADDR, true)
        .option(UnixChannelOption.SO_REUSEPORT, true)
        .childOption(ChannelOption.TCP_NODELAY, true)
        .childOption(ChannelOption.ALLOCATOR, ByteBufAllocator.DEFAULT)
        .childHandler(object : ChannelInitializer<Channel>() {
            override fun initChannel(ch: Channel) {
                if (codec) ch.pipeline().addLast(HttpRequestDecoder(decoder), HttpHandler(engine.handler, vt))
                else ch.pipeline().addLast(RawHandler(engine))
            }
        })
    val addr = InetSocketAddress(InetAddress.getByName(host), port)
    b.bind(addr).sync()
    var listeners = 1
    while (listeners < n) { // one listener per loop; without SO_REUSEPORT the first one feeds all loops
        try {
            b.bind(addr).sync()
            listeners++
        } catch (e: Exception) {
            println("http: netty: one listener only ($e)")
            break
        }
    }
    println(
        "http: netty ${if (codec) "HTTP/1.1 decoder" else "transport"} on ${t.name}, $n loops, $listeners listeners, " +
            "allocator ${ByteBufAllocator.DEFAULT.javaClass.simpleName}${if (vt && codec) ", handlers on virtual threads" else ""}",
    )
    return true
}

private class Transport(val name: String, val factory: IoHandlerFactory, val server: Class<out ServerChannel>)

/** NETTY_TRANSPORT=io_uring if this build has it and the kernel allows it, else epoll; null: neither. */
private fun transport(): Transport? {
    if (getenv("NETTY_TRANSPORT") == "io_uring") ioUring()?.let { return it }
    if (!Epoll.isAvailable()) {
        println("http: netty epoll unavailable (${Epoll.unavailabilityCause()})")
        return null
    }
    return Transport("native epoll", EpollIoHandler.newFactory(), EpollServerSocketChannel::class.java)
}

/**
 * Netty 4.2's io_uring transport, by reflection: its jar is only on the classpath of builds made with NETTY_URING=1
 * (build.gradle.kts), and containers often forbid the syscalls (seccomp). Null (epoll then) if either is missing.
 */
private fun ioUring(): Transport? = try {
    val io = Class.forName("io.netty.channel.uring.IoUring")
    if (io.getMethod("isAvailable").invoke(null) == true) {
        val factory = Class.forName("io.netty.channel.uring.IoUringIoHandler").getMethod("newFactory").invoke(null)
        @Suppress("UNCHECKED_CAST")
        val server = Class.forName("io.netty.channel.uring.IoUringServerSocketChannel") as Class<out ServerChannel>
        Transport("io_uring", factory as IoHandlerFactory, server)
    } else {
        println("http: netty io_uring unavailable (${io.getMethod("unavailabilityCause").invoke(null)}); using epoll")
        null
    }
} catch (e: ReflectiveOperationException) {
    println("http: netty io_uring not in this build ($e); using epoll")
    null
} catch (e: LinkageError) {
    println("http: netty io_uring unusable ($e); using epoll")
    null
}

/** The loop's read scratch (Netty hands us its pooled direct buffers; our engine reads byte arrays). */
private val readScratch = object : FastThreadLocal<ByteArray>() {
    override fun initialValue() = ByteArray(NETTY_READ_CHUNK)
}

private val CLOSING = AtomicIntegerFieldUpdater.newUpdater(NettyConn::class.java, "closing")

/** HTTP_IO=netty: one channel under our engine. Netty owns the socket. */
internal class NettyConn(@JvmField val ch: Channel, private val engine: HttpEngine) : HttpConn() {
    /** 1 once close() was called or the channel went inactive (any thread reads it). */
    @JvmField @Volatile var closing = 0

    /**
     * On the loop: takes all of it (Netty queues what the socket cannot take now). Elsewhere: takes nothing, so the
     * engine keeps the response and asks for [requestWritable], and the loop writes it. A write queued from another
     * thread would only run after the task in progress, while the engine (thinking it written) could let the loop
     * answer the next pipelined request inline: responses out of order.
     */
    override fun tryWrite(b: ByteArray, off: Int, len: Int): Int {
        if (closing != 0 || !ch.isActive) return -1
        if (!ch.eventLoop().inEventLoop()) return 0
        val buf = ch.alloc().directBuffer(len, len)
        buf.writeBytes(b, off, len)
        ch.writeAndFlush(buf, ch.voidPromise())
        return len
    }

    override fun requestWritable() = execute { if (closing == 0) engine.onWritable(this) }

    override fun execute(task: () -> Unit) = ch.eventLoop().execute { task() }

    override fun close() {
        if (CLOSING.compareAndSet(this, 0, 1)) ch.close()
    }
}

/** HTTP_IO=netty: bytes in, our engine does HTTP. Netty fires channelInactive later (never inside close()). */
private class RawHandler(private val engine: HttpEngine) : ChannelInboundHandlerAdapter() {
    private var conn: NettyConn? = null

    override fun channelActive(ctx: ChannelHandlerContext) {
        val c = NettyConn(ctx.channel(), engine)
        conn = c
        engine.onOpen(c)
    }

    override fun channelRead(ctx: ChannelHandlerContext, msg: Any) {
        val buf = msg as ByteBuf
        try {
            val c = conn ?: return
            val s = readScratch.get()
            var at = buf.readerIndex()
            var left = buf.readableBytes()
            while (left > 0 && c.closing == 0) {
                val n = minOf(left, s.size)
                buf.getBytes(at, s, 0, n)
                engine.onData(c, s, 0, n)
                at += n
                left -= n
            }
        } finally {
            buf.release()
        }
    }

    override fun channelInactive(ctx: ChannelHandlerContext) {
        val c = conn ?: return
        conn = null
        c.closing = 1
        engine.onClosed(c)
    }

    override fun exceptionCaught(ctx: ChannelHandlerContext, cause: Throwable) {
        ctx.close() // reset by peer and the like; channelInactive tells the engine
    }
}

/** Response buffers of the netty-http exchanges (the engine keeps its own pool). */
private val nettyOuts = OutPool(1024)

/** NETTY_HANDLER=vt: thread scratch lent to the virtual thread a handler starts on (one per request otherwise). */
private val vtScratches = ConcurrentLinkedQueue<Scratch>()

/**
 * HTTP_IO=netty-http: Netty's decoder hands us the request head and body pieces; we collect the body (up to
 * [MAX_BODY]) and run the handler. One request at a time per connection, like the engine: anything decoded while a
 * request is in flight (pipelining) waits in [queue] and is handled after that response.
 */
private class HttpHandler(private val handler: suspend (Exchange) -> Unit, private val vt: Boolean) :
    ChannelInboundHandlerAdapter() {
    private lateinit var ctx: ChannelHandlerContext
    private var head: HttpRequest? = null
    private var body: ByteArray = EMPTY
    private var bodyLen = 0
    private var skip = false // the rest of a rejected request
    private var busy = false
    private val queue = ArrayDeque<Any>()

    override fun handlerAdded(ctx: ChannelHandlerContext) {
        this.ctx = ctx
    }

    override fun channelRead(ctx: ChannelHandlerContext, msg: Any) {
        if (busy) queue.addLast(msg) else handle(msg)
    }

    override fun channelInactive(ctx: ChannelHandlerContext) {
        while (queue.isNotEmpty()) release(queue.removeFirst())
        ctx.fireChannelInactive()
    }

    override fun exceptionCaught(ctx: ChannelHandlerContext, cause: Throwable) {
        ctx.close()
    }

    private fun handle(msg: Any) {
        if (msg is HttpRequest) {
            val r = msg.decoderResult()
            if (r.isFailure) {
                reject(if (r.cause() is TooLongFrameException) 431 else 400, "bad request")
                release(msg)
                return
            }
            head = msg
            body = EMPTY
            bodyLen = 0
            skip = false
            if (HttpUtil.is100ContinueExpected(msg)) ctx.writeAndFlush(ctx.alloc().directBuffer().writeBytes(CONTINUE_100), ctx.voidPromise())
        }
        if (msg is HttpContent) {
            try {
                if (skip || head == null) return
                val c = msg.content()
                val n = c.readableBytes()
                if (bodyLen + n > MAX_BODY) {
                    skip = true
                    head = null
                    reject(413, "request body too large")
                    return
                }
                if (n > 0) {
                    if (bodyLen + n > body.size) body = body.copyOf(maxOf(bodyLen + n, body.size * 2, 256))
                    c.getBytes(c.readerIndex(), body, bodyLen, n)
                    bodyLen += n
                }
                if (msg is LastHttpContent) dispatch()
            } finally {
                msg.release()
            }
        }
    }

    private fun dispatch() {
        val h = head ?: return
        head = null
        val uri = h.uri()
        val q = uri.indexOf('?')
        val keep = HttpUtil.isKeepAlive(h)
        val mode = if (!keep) CLOSE else if (h.protocolVersion() == HttpVersion.HTTP_1_0) KEEP_10 else KEEP
        val ex = NettyEx(
            this, methodOf(h.method()), if (q < 0) uri else uri.substring(0, q), if (q < 0) null else uri.substring(q + 1),
            h.headers().get(HttpHeaderNames.AUTHORIZATION), if (bodyLen == body.size) body else body.copyOf(bodyLen), mode,
        )
        body = EMPTY
        busy = true
        if (!vt) {
            handler.startCoroutine(ex, ex)
            return
        }
        Thread.ofVirtual().start {
            val s = vtScratches.poll() ?: Scratch()
            lendScratch(s)
            try {
                handler.startCoroutine(ex, ex) // runs until the first suspension (Postgres, bcrypt) or the answer
            } finally {
                lendScratch(null)
                vtScratches.offer(s)
            }
        }
    }

    /** Any thread: true while the client is connected (for [NettyEx.abandoned]). */
    val active: Boolean get() = ctx.channel().isActive

    /** Any thread: closes the connection (Netty runs it on the loop). */
    fun close() {
        ctx.channel().close()
    }

    /**
     * Any thread: sends one rendered response ([o] from [start] to [end]), then frees the connection for its next
     * request. Off the loop this is ONE task on the connection's loop (Netty's own cross-thread write would be a write
     * task plus our next-request task), and the direct buffer comes from the loop's allocator cache.
     */
    fun write(o: Out, start: Int, end: Int, close: Boolean) {
        val loop = ctx.channel().eventLoop()
        if (loop.inEventLoop()) send(o, start, end, close) else loop.execute(Send(this, o, start, end, close))
    }

    /** On the loop: copies the response into a direct buffer, writes and flushes it, returns [o] to the pool. */
    fun send(o: Out, start: Int, end: Int, close: Boolean) {
        val ch = ctx.channel()
        var buf: ByteBuf? = null
        try {
            if (ch.isActive) buf = ctx.alloc().directBuffer(end - start, end - start).writeBytes(o.buf.buf, start, end - start)
        } catch (e: Throwable) { // out of direct memory: drop this client rather than the loop's other work
            ch.close()
            logSafe({ "http: netty response buffer" }, e)
        } finally {
            nettyOuts.put(o)
        }
        if (buf == null) return
        if (close) {
            ctx.writeAndFlush(buf).addListener(ChannelFutureListener.CLOSE)
        } else {
            ctx.writeAndFlush(buf, ctx.voidPromise())
            next()
        }
    }

    private fun next() {
        busy = false
        while (!busy && queue.isNotEmpty()) handle(queue.removeFirst())
    }

    private fun reject(status: Int, message: String) {
        val o = nettyOuts.get()
        putError(o.buf, message)
        val start = putHead(o.buf.buf, status, o.buf.len - RESERVE, CLOSE)
        busy = true // nothing more is answered on this connection
        val buf = ctx.alloc().directBuffer(o.buf.len - start)
        buf.writeBytes(o.buf.buf, start, o.buf.len - start)
        nettyOuts.put(o)
        ctx.writeAndFlush(buf).addListener(ChannelFutureListener.CLOSE)
    }

    private fun release(msg: Any) {
        if (msg is HttpContent) msg.release()
    }
}

/** [HttpHandler.send] as a loop task. */
private class Send(
    private val h: HttpHandler,
    private val o: Out,
    private val start: Int,
    private val end: Int,
    private val close: Boolean,
) : Runnable {
    override fun run() = h.send(o, start, end, close)
}

private fun methodOf(m: HttpMethod): Method = when (m) {
    HttpMethod.GET -> Method.GET
    HttpMethod.POST -> Method.POST
    HttpMethod.PUT -> Method.PUT
    HttpMethod.DELETE -> Method.DELETE
    else -> Method.OTHER
}

private fun hasBody(status: Int) = status >= 200 && status != 204 && status != 304

/**
 * The netty-http [Exchange], also the completion of its handler coroutine (500 if the handler did not answer) and
 * that coroutine's context, so the overload guard can drop its queued work once the client is gone, as for engine
 * exchanges.
 */
private class NettyEx(
    private val conn: HttpHandler,
    override val method: Method,
    override val path: String,
    override val query: String?,
    override val authorization: String?,
    override val body: ByteArray,
    private val connMode: Int,
) : ContextExchange(), Continuation<Unit> {
    private val born = nanoTime()
    private var res: Out? = null
    private var jsonReady = false
    private var answered = false

    private fun buf(): Out {
        if (answered) error("exchange already answered")
        return res ?: nettyOuts.get().also { res = it }
    }

    override val out: Bytes
        get() = buf().buf

    override val json: JsonWriter
        get() {
            val o = buf()
            if (!jsonReady) {
                jsonReady = true
                val len = o.buf.len
                o.json.reset()
                o.buf.len = len
            }
            return o.json
        }

    override fun send(status: Int) {
        val o = claim() ?: return
        respond(o, status, if (hasBody(status)) o.buf.len - RESERVE else -1)
    }

    override fun sendEmpty(status: Int) {
        val o = claim() ?: return
        o.buf.len = RESERVE
        respond(o, status, if (hasBody(status)) 0 else -1)
    }

    override fun sendError(status: Int, message: String) {
        val o = claim() ?: return
        o.buf.len = RESERVE
        putError(o.buf, message)
        respond(o, status, o.buf.len - RESERVE)
    }

    private fun claim(): Out? {
        if (answered) return null
        val o = res ?: nettyOuts.get()
        answered = true
        res = null
        return o
    }

    private fun respond(o: Out, status: Int, bodyLen: Int) {
        val start = putHead(o.buf.buf, status, bodyLen, connMode)
        conn.write(o, start, if (bodyLen < 0) RESERVE else o.buf.len, connMode == CLOSE) // the loop returns o
    }

    override val abandoned: Boolean
        get() = !conn.active || nanoTime() - born >= ABANDONED_NANOS

    override fun abandon() {
        try {
            conn.close()
        } catch (_: Throwable) { // out of memory: the connection stays open until the client closes it
        }
    }

    override val context: CoroutineContext get() = this

    override fun resumeWith(result: Result<Unit>) {
        val e = result.exceptionOrNull()
        if (!answered) sendError(500, "internal server error")
        if (e != null) logSafe({ "http: handler failed" }, e)
    }
}
