package conduit.platform

import conduit.http.ABANDONED_NANOS
import conduit.http.ContextExchange
import conduit.http.EMPTY
import conduit.http.Exchange
import conduit.http.HttpEngine
import conduit.http.MAX_BODY
import conduit.http.MAX_HEAD
import conduit.http.Method
import conduit.http.Out
import conduit.http.OutPool
import conduit.http.RESERVE
import conduit.http.putError
import conduit.json.JsonWriter
import conduit.util.logSafe
import io.vertx.core.Context
import io.vertx.core.Vertx
import io.vertx.core.VertxOptions
import io.netty.buffer.Unpooled
import io.vertx.core.buffer.impl.BufferImpl
import io.vertx.core.http.HttpHeaders
import io.vertx.core.http.HttpMethod
import io.vertx.core.http.HttpServerOptions
import io.vertx.core.http.HttpServerRequest
import io.vertx.core.http.HttpServerResponse
import java.util.concurrent.TimeUnit
import kotlin.coroutines.Continuation
import kotlin.coroutines.CoroutineContext
import kotlin.coroutines.startCoroutine
import conduit.util.ByteBuf as Bytes

/**
 * The process's one Vert.x instance, shared by the HTTP server (HTTP_IO=vertx) and the Postgres client
 * (DB_DRIVER=vertx), so both run on the same event loops: a query's result arrives on the loop that owns the
 * request's connection, and the response is written there, with no hand-off to another thread.
 */
object SharedVertx {
    val instance: Vertx by lazy {
        // 2 loops for the pg client alone; with HTTP_IO=vertx they also carry every client connection (lab: 2 loops for
        // both at 144k users: 291% app CPU on 2 threads, p95 6.6 s), so 4
        val loops = getenv("VERTX_LOOPS")?.toIntOrNull() ?: if (getenv("HTTP_IO") == "vertx") 4 else 2
        Vertx.vertx(VertxOptions().setEventLoopPoolSize(loops).setPreferNativeTransport(true))
    }
}

private val vertxOuts = OutPool(1024)

// pre-encoded header name and value (Vert.x then writes their bytes as they are, no per-response encoding)
private val CONTENT_TYPE: CharSequence = HttpHeaders.createOptimized("Content-Type")
private val CT_JSON: CharSequence = HttpHeaders.createOptimized("application/json")

/**
 * HTTP_IO=vertx: Vert.x core's HTTP/1.1 server (on Netty) instead of our engine or a raw Netty pipeline. One server
 * per event loop ([loops], SO_REUSEPORT), each request's body collected by Vert.x (up to [MAX_BODY]), the handler
 * started as a coroutine on the request's event loop; the answer is written on that loop (posted there if the handler
 * resumed elsewhere, e.g. on our own Postgres driver's threads with DB_DRIVER=own).
 */
internal fun startVertxServer(host: String, port: Int, loops: Int, engine: HttpEngine) {
    val vertx = SharedVertx.instance
    val options = HttpServerOptions()
        .setHost(host).setPort(port)
        .setReusePort(true).setTcpNoDelay(true).setAcceptBacklog(65535)
        .setMaxInitialLineLength(MAX_HEAD).setMaxHeaderSize(MAX_HEAD)
        .setCompressionSupported(false).setHandle100ContinueAutomatically(true)
    val handler = engine.handler
    repeat(maxOf(1, loops)) {
        // created from this (non-Vert.x) thread, each server gets its own event loop; Vert.x spreads connections
        vertx.createHttpServer(options)
            .requestHandler { req -> onRequest(req, handler) }
            .listen()
            .toCompletionStage().toCompletableFuture().get(30, TimeUnit.SECONDS)
    }
    println("http: vert.x core HTTP/1.1 server, $loops servers on the shared Vert.x event loops")
}

private fun onRequest(req: HttpServerRequest, handler: suspend (Exchange) -> Unit) {
    val ctx = Vertx.currentContext()
    val m = when (req.method()) {
        HttpMethod.GET -> Method.GET
        HttpMethod.POST -> Method.POST
        HttpMethod.PUT -> Method.PUT
        HttpMethod.DELETE -> Method.DELETE
        else -> Method.OTHER
    }
    val path = req.path()
    val query = req.query()
    val auth = req.getHeader("Authorization")
    val hasBody = m == Method.POST || m == Method.PUT
    if (!hasBody) {
        req.end() // GET/DELETE: no body to wait for
        dispatch(VertxEx(req.response(), ctx, m, path, query, auth, EMPTY), handler)
        return
    }
    req.body().onComplete { ar ->
        if (ar.failed()) {
            req.response().setStatusCode(400).end()
            return@onComplete
        }
        val b = ar.result()
        if (b.length() > MAX_BODY) {
            req.response().setStatusCode(413).end()
            return@onComplete
        }
        dispatch(VertxEx(req.response(), ctx, m, path, query, auth, b.bytes), handler)
    }
}

private fun dispatch(ex: VertxEx, handler: suspend (Exchange) -> Unit) {
    try {
        handler.startCoroutine(ex, ex)
    } catch (e: Throwable) {
        logSafe({ "http: handler failed to start" }, e)
        ex.sendError(500, "internal server error")
    }
}

/** The Vert.x [Exchange], also the completion of its handler coroutine (500 if the handler did not answer). */
private class VertxEx(
    private val resp: HttpServerResponse,
    private val ctx: Context,
    override val method: Method,
    override val path: String,
    override val query: String?,
    override val authorization: String?,
    override val body: ByteArray,
) : ContextExchange(), Continuation<Unit> {
    private val born = nanoTime()
    private var res: Out? = null
    private var jsonReady = false
    private var answered = false

    private fun buf(): Out {
        if (answered) error("exchange already answered")
        return res ?: vertxOuts.get().also { res = it }
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
        respond(o, status, hasBody(status))
    }

    override fun sendEmpty(status: Int) {
        val o = claim() ?: return
        o.buf.len = RESERVE
        respond(o, status, hasBody(status))
    }

    override fun sendError(status: Int, message: String) {
        val o = claim() ?: return
        o.buf.len = RESERVE
        putError(o.buf, message)
        respond(o, status, true)
    }

    private fun claim(): Out? {
        if (answered) return null
        val o = res ?: vertxOuts.get()
        answered = true
        res = null
        return o
    }

    /**
     * Writes the response on the request's loop. The body is NOT copied: a Netty buffer wraps [o]'s bytes, and [o]
     * goes back to the pool only once Netty has written them (end()'s future).
     */
    private fun respond(o: Out, status: Int, withBody: Boolean) {
        if (Vertx.currentContext() === ctx) write(o, status, withBody) else ctx.runOnContext { write(o, status, withBody) }
    }

    private fun write(o: Out, status: Int, withBody: Boolean) {
        if (resp.closed()) {
            vertxOuts.put(o)
            return
        }
        resp.setStatusCode(status)
        if (!withBody) {
            vertxOuts.put(o)
            resp.end()
            return
        }
        resp.putHeader(CONTENT_TYPE, CT_JSON)
        val data = BufferImpl(Unpooled.wrappedBuffer(o.buf.buf, RESERVE, o.buf.len - RESERVE))
        resp.end(data).onComplete { vertxOuts.put(o) }
    }

    override val abandoned: Boolean
        get() = resp.closed() || nanoTime() - born >= ABANDONED_NANOS

    override fun abandon() {
        try {
            ctx.runOnContext { if (!resp.closed()) resp.reset() }
        } catch (_: Throwable) {
        }
    }

    override val context: CoroutineContext get() = this

    override fun resumeWith(result: Result<Unit>) {
        val e = result.exceptionOrNull()
        if (!answered) sendError(500, "internal server error")
        if (e != null) logSafe({ "http: handler failed" }, e)
    }
}

private fun hasBody(status: Int) = status >= 200 && status != 204 && status != 304
