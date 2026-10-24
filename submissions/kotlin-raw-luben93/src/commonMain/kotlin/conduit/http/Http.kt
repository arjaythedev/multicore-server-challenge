package conduit.http

import kotlin.jvm.JvmField
import conduit.json.JsonWriter
import conduit.util.ByteBuf

/**
 * One accepted client socket. The platform event loop (JVM NIO / Linux epoll) implements the four I/O primitives;
 * everything else is [HttpEngine]'s business. The loop that accepted the socket "owns" it: it is the only thread
 * that reads it and the only thread that calls the engine's onData/onWritable/onClosed for it.
 */
abstract class HttpConn {
    /**
     * Non-blocking write, callable from ANY thread (responses are written from Postgres/bcrypt threads).
     * Returns bytes written (0 = socket buffer full), or -1 if the connection is broken.
     */
    abstract fun tryWrite(b: ByteArray, off: Int, len: Int): Int

    /** Any thread: asks the owning loop to call [HttpEngine.onWritable] once the socket can take more bytes. */
    abstract fun requestWritable()

    /** Any thread: runs [task] on the owning loop thread soon (wakes the loop if it is waiting). */
    abstract fun execute(task: () -> Unit)

    /** Any thread, idempotent: closes the socket; the owning loop then calls [HttpEngine.onClosed] once. */
    abstract fun close()

    /** Engine-private per-connection state. Platform code must not touch it. */
    @JvmField var state: Any? = null
}

enum class Method { GET, POST, PUT, DELETE, OTHER }

/**
 * One request/response. Built by the engine when a complete request has been parsed, handed to the application's
 * suspend handler, and answered exactly once with [send], [sendEmpty] or [sendError]. If the handler returns
 * without answering, or throws, the engine answers 500.
 *
 * Response bodies are JSON written into [out] via [json]; the engine adds the status line and headers
 * (Content-Type: application/json, Content-Length) and writes headers + body with one write where possible.
 */
abstract class Exchange {
    abstract val method: Method
    /** Path without the query string, still percent-encoded. */
    abstract val path: String
    /** Raw query string after '?', still percent-encoded; null if none. */
    abstract val query: String?
    /** Raw Authorization header value; null if absent. */
    abstract val authorization: String?
    /** Request body bytes (empty array if none). */
    abstract val body: ByteArray

    /**
     * Response body buffer. Append only: it starts at `out.len` = a reserved header area (not 0), so the engine can
     * put the status line and headers right in front of the body and send both with one write. Never reset() it.
     */
    abstract val out: ByteBuf
    /** JSON writer over [out]. */
    abstract val json: JsonWriter

    /** Sends [out] as the JSON body with [status]. */
    abstract fun send(status: Int)

    /** Sends a response without a body (204). */
    abstract fun sendEmpty(status: Int)

    /** Sends {"errors":{"body":[message]}} with [status] (discards anything written to [out]). */
    abstract fun sendError(status: Int, message: String)

    /** Application scratch: the authenticated viewer (0 = anonymous) and the presented token. */
    @JvmField var viewer: Long = 0
    @JvmField var token: String? = null
}

/**
 * The common HTTP/1.1 engine: request parsing, keep-alive, the per-connection state machine, response writing,
 * coroutine launch. Platform loops call these four methods on the owning loop thread, never reentrantly: the
 * engine calls [HttpConn.execute], [HttpConn.close] and [HttpConn.requestWritable] from inside them, so a platform
 * must queue that work for later, never run it inline. See Engine.kt for the state machine.
 */
class HttpEngine(handler: suspend (Exchange) -> Unit) {
    private val core = EngineCore(handler)

    /** A new connection was accepted. */
    fun onOpen(conn: HttpConn) = core.onOpen(conn)

    /** [len] bytes were read into [buf] at [off]. [buf] is the loop's scratch and is reused after this returns. */
    fun onData(conn: HttpConn, buf: ByteArray, off: Int, len: Int) = core.onData(conn, buf, off, len)

    /** The socket is writable again after [HttpConn.requestWritable]. */
    fun onWritable(conn: HttpConn) = core.onWritable(conn)

    /** EOF, error or [HttpConn.close]; called exactly once per connection. */
    fun onClosed(conn: HttpConn) = core.onClosed(conn)
}
