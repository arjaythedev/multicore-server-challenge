package conduit.http

import conduit.util.logSafe
import kotlin.concurrent.atomics.AtomicInt
import kotlin.coroutines.startCoroutine
import kotlin.jvm.JvmField
import kotlin.math.max

// Per-connection state machine. Exactly one request per connection is in flight; the owning loop parses, any thread
// may answer. Only the loop moves a connection out of IDLE; whoever completes a response moves it back.
internal const val IDLE = 0       // no request in flight: the loop parses input as it arrives
internal const val BUSY = 1       // a request is in flight (handler running, or its response still being written)
internal const val BUSY_INPUT = 2 // ... and input arrived meanwhile: the completion must hand it back to the loop
internal const val CLOSED = 3     // closing or closed: input is dropped, nothing more is answered

private const val IN_INITIAL = 2048
/** Input buffered behind a request in flight (pipelining) before the client is cut off. */
private const val MAX_BUFFERED = MAX_HEAD + 2 * MAX_BODY
private const val POOL = 1024

/**
 * Engine-private connection state ([HttpConn.state]). An idle connection holds no buffers: [inBuf] exists only while
 * unparsed bytes are buffered (a partial request, or input pipelined behind the request in flight).
 */
internal class ConnState(@JvmField val conn: HttpConn) {
    @JvmField val st = AtomicInt(IDLE)

    // Input side: owning loop only.
    @JvmField var inBuf: ByteArray? = null
    @JvmField var inOff = 0
    @JvmField var inEnd = 0
    /** Head: bytes after the request start already searched for its end. Chunked body: next chunk's offset. */
    @JvmField var scan = 0
    @JvmField var chunkTotal = 0
    /** A request whose head is parsed and consumed, waiting for its body. */
    @JvmField var head: Ex? = null
    /** Set by [EngineCore.parse]: it stopped on an incomplete request (rather than on a request in flight). */
    @JvmField var partial = false

    // A response the socket did not take at once; handed to the loop by requestWritable (which publishes these).
    @JvmField var wOut: Out? = null
    @JvmField var wPos = 0
    @JvmField var wEnd = 0
    @JvmField var wClose = false
}

internal class EngineCore(private val handler: suspend (Exchange) -> Unit) {
    private val pool = OutPool(POOL)

    fun onOpen(conn: HttpConn) {
        conn.state = ConnState(conn)
    }

    fun onData(conn: HttpConn, buf: ByteArray, off: Int, len: Int) {
        val cs = conn.state as? ConnState ?: return
        try {
            when (cs.st.load()) {
                IDLE -> if (cs.inBuf == null && cs.head == null) {
                    // fast path: parse straight from the loop's scratch, buffer only what is left over
                    val end = off + len
                    val p = parse(cs, buf, off, end)
                    if (p < end && append(cs, buf, p, end - p) && !cs.partial) flagInput(cs)
                } else if (append(cs, buf, off, len)) {
                    drain(cs)
                }
                CLOSED -> {}
                else -> if (append(cs, buf, off, len)) flagInput(cs)
            }
        } catch (e: Throwable) {
            fail(cs, e)
        }
    }

    fun onWritable(conn: HttpConn) {
        val cs = conn.state as? ConnState ?: return
        val o = cs.wOut ?: return
        cs.wOut = null
        if (cs.st.load() == CLOSED) {
            pool.put(o)
            return
        }
        try {
            write(cs, o, cs.wPos, cs.wEnd, cs.wClose)
        } catch (e: Throwable) {
            fail(cs, e)
        }
    }

    fun onClosed(conn: HttpConn) {
        val cs = conn.state as? ConnState ?: return
        cs.st.store(CLOSED)
        cs.inBuf = null
        cs.head = null
        val o = cs.wOut
        if (o != null) {
            cs.wOut = null
            pool.put(o)
        }
    }

    private fun fail(cs: ConnState, e: Throwable) {
        cs.st.store(CLOSED) // state and socket first: logging allocates, and may fail
        cs.conn.close()
        logSafe({ "http: engine error, closing connection" }, e)
    }

    /**
     * Parses and dispatches requests from b[from, end) while the connection is IDLE. Returns the first unconsumed
     * index; [ConnState.partial] tells whether it stopped on an incomplete request or on a request in flight.
     */
    private fun parse(cs: ConnState, b: ByteArray, from: Int, end: Int): Int {
        var pos = from
        while (true) {
            if (cs.st.load() != IDLE) {
                cs.partial = false
                return pos
            }
            var ex = cs.head
            if (ex == null) {
                while (pos < end && (b[pos] == 13.toByte() || b[pos] == 10.toByte())) pos++ // stray CRLF between requests
                if (pos == end) {
                    cs.scan = 0
                    cs.partial = true
                    return pos
                }
                val he = headEnd(b, pos + cs.scan, end)
                if (he < 0 || he - pos > MAX_HEAD) {
                    if (end - pos > MAX_HEAD) return reject(cs, 431, "request header too large", end)
                    cs.scan = max(0, end - pos - 3)
                    cs.partial = true
                    return pos
                }
                cs.scan = 0
                ex = Ex(this, cs)
                val err = parseHead(ex, b, pos, he)
                if (err != 0) return reject(cs, err, errorText(err), end)
                pos = he
                if (!ex.chunked && ex.bodyLen == 0) {
                    dispatch(cs, ex)
                    continue
                }
                cs.head = ex
            }
            // the body
            if (ex.chunked) {
                val r = scanChunked(cs, b, pos, end)
                when (r) {
                    NEED -> return waitBody(cs, ex, b, pos)
                    BAD -> return reject(cs, 400, "malformed chunked body", end)
                    TOO_BIG -> return reject(cs, 413, "request body too large", end)
                }
                ex.body = decodeChunked(b, pos, cs.chunkTotal)
                cs.scan = 0
                cs.chunkTotal = 0
                pos = r
            } else {
                val n = ex.bodyLen
                if (end - pos < n) return waitBody(cs, ex, b, pos)
                ex.body = b.copyOfRange(pos, pos + n)
                pos += n
            }
            cs.head = null
            dispatch(cs, ex)
        }
    }

    private fun waitBody(cs: ConnState, ex: Ex, b: ByteArray, pos: Int): Int {
        // the head's bytes are not kept with the body: the Authorization value must not point into them
        val a = ex.authBuf
        if (a === b) {
            ex.authBuf = b.copyOfRange(ex.authOff, ex.authOff + ex.authLen)
            ex.authOff = 0
        }
        if (ex.expect) { // the client waits for this before it sends the body
            ex.expect = false
            if (cs.conn.tryWrite(CONTINUE_100, 0, CONTINUE_100.size) != CONTINUE_100.size) {
                cs.st.store(CLOSED) // cannot happen on a socket with nothing else in flight; never half-send it
                cs.conn.close()
            }
        }
        cs.partial = true
        return pos
    }

    private fun dispatch(cs: ConnState, ex: Ex) {
        cs.st.store(BUSY) // before the handler can answer on another thread
        handler.startCoroutine(ex, ex)
    }

    /** A response buffer for [Ex] (any thread): taken when the response is rendered, not when the request is parsed. */
    internal fun takeOut(): Out = pool.get()

    /** Returns an unsent buffer (any thread), e.g. the uncompressed body once its gzipped copy is sent instead. */
    internal fun putOut(o: Out) = pool.put(o)

    /** Answers [status] with Connection: close and drops all input. Returns [end] (everything consumed). */
    private fun reject(cs: ConnState, status: Int, message: String, end: Int): Int {
        cs.inBuf = null
        cs.head = null
        cs.partial = false
        val ex = Ex(this, cs)
        ex.connMode = CLOSE
        ex.res = pool.get()
        cs.st.store(BUSY)
        ex.sendError(status, message)
        return end
    }

    /** Posted by a completion that found input waiting (runs on the owning loop). */
    private fun resume(cs: ConnState) {
        try {
            drain(cs)
        } catch (e: Throwable) {
            fail(cs, e)
        }
    }

    /** Parses buffered input (owning loop). */
    private fun drain(cs: ConnState) {
        while (true) {
            if (cs.st.load() != IDLE) return
            val b = cs.inBuf ?: return
            val p = parse(cs, b, cs.inOff, cs.inEnd)
            if (cs.inBuf !== b) return // rejected or closed: input dropped
            cs.inOff = p
            if (p == cs.inEnd) {
                cs.inBuf = null
                cs.inOff = 0
                cs.inEnd = 0
                return
            }
            if (cs.partial || cs.st.compareAndSet(BUSY, BUSY_INPUT)) return
            // the response completed between parse() and the CAS: parse on
        }
    }

    /** New input is buffered behind a request in flight: make sure whoever completes it comes back to parse. */
    private fun flagInput(cs: ConnState) {
        while (true) {
            when (cs.st.load()) {
                BUSY -> if (cs.st.compareAndSet(BUSY, BUSY_INPUT)) return
                IDLE -> return drain(cs) // completed meanwhile, without seeing the flag
                else -> return // already flagged, or closed
            }
        }
    }

    /** Buffers b[off, off+len) after the unparsed input. False if the connection is closed (or is closed now). */
    private fun append(cs: ConnState, b: ByteArray, off: Int, len: Int): Boolean {
        if (cs.st.load() == CLOSED) return false
        val have = cs.inEnd - cs.inOff
        if (have + len > MAX_BUFFERED) {
            cs.st.store(CLOSED)
            cs.inBuf = null
            cs.conn.close()
            return false
        }
        var buf = cs.inBuf
        val head = cs.head
        if (buf == null || cs.inEnd + len > buf.size) {
            val need = have + len
            if (buf != null && need <= buf.size) {
                buf.copyInto(buf, 0, cs.inOff, cs.inEnd)
            } else {
                // a waiting fixed-length body is buffered whole: size for it at once
                val hint = if (head != null && !head.chunked) head.bodyLen else 0
                val nb = ByteArray(max(need, max(hint, if (buf == null) IN_INITIAL else buf.size * 2)))
                buf?.copyInto(nb, 0, cs.inOff, cs.inEnd)
                buf = nb
                cs.inBuf = nb
            }
            cs.inOff = 0
            cs.inEnd = have
        }
        b.copyInto(buf, cs.inEnd, off, off + len)
        cs.inEnd += len
        return true
    }

    /**
     * Writes o.buf[from, to) (any thread). A remainder the socket did not take goes to the loop (requestWritable,
     * then [onWritable]); a broken socket is closed. On completion the buffer returns to the pool.
     */
    fun write(cs: ConnState, o: Out, from: Int, to: Int, close: Boolean) {
        val conn = cs.conn
        val n = conn.tryWrite(o.buf.buf, from, to - from)
        if (n < 0) {
            pool.put(o)
            cs.st.store(CLOSED)
            conn.close()
            return
        }
        val p = from + n
        if (p < to) {
            cs.wOut = o
            cs.wPos = p
            cs.wEnd = to
            cs.wClose = close
            conn.requestWritable()
            return
        }
        pool.put(o)
        if (close) {
            cs.st.store(CLOSED)
            conn.close()
            return
        }
        // response complete: back to IDLE, and hand buffered input to the loop if some arrived meanwhile
        while (true) {
            val s = cs.st.load()
            if (s == CLOSED) return
            if (cs.st.compareAndSet(s, IDLE)) {
                if (s == BUSY_INPUT) conn.execute { resume(cs) }
                return
            }
        }
    }

    private fun errorText(status: Int) = when (status) {
        413 -> "request body too large"
        417 -> "expectation not supported"
        501 -> "transfer-encoding not supported"
        else -> "bad request"
    }
}
