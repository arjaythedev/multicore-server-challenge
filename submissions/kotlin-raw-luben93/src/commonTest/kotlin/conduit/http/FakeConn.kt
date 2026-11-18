package conduit.http

import conduit.platform.Monitor
import conduit.platform.locked
import conduit.util.ByteBuf
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn

/** An in-memory socket: records writes, queues loop work; the test plays the event loop with [pump]. */
class FakeConn(val engine: HttpEngine) : HttpConn() {
    private val lock = Monitor()
    private val written = ByteBuf(1024)
    private val tasks = ArrayList<() -> Unit>()
    /** Bytes the socket still accepts before it is "full" (partial writes). */
    var budget = Int.MAX_VALUE
    var broken = false
    var closed = false
        private set
    private var closedDelivered = false
    private var wantWritable = false
    var writes = 0
        private set

    init {
        engine.onOpen(this)
    }

    override fun tryWrite(b: ByteArray, off: Int, len: Int): Int = lock.locked {
        if (broken || closed) return -1
        writes++
        val n = minOf(len, budget)
        budget -= n
        written.put(b, off, n)
        n
    }

    override fun requestWritable() = lock.locked { wantWritable = true }

    override fun execute(task: () -> Unit) {
        lock.locked { tasks.add(task) }
    }

    override fun close() = lock.locked { closed = true }

    fun feed(s: String) = feed(s.encodeToByteArray())

    /** Delivers bytes as one read (through a reused scratch with garbage around it, like a loop does). */
    fun feed(b: ByteArray, off: Int = 0, len: Int = b.size - off) {
        if (closedDelivered) return
        val scratch = ByteArray(len + 7) { 'x'.code.toByte() }
        b.copyInto(scratch, 3, off, off + len)
        engine.onData(this, scratch, 3, len)
        scratch.fill('#'.code.toByte()) // the engine must not keep references into the scratch
        pump()
    }

    /** Runs the loop side: posted tasks, writable callbacks (while there is budget), the close callback. */
    fun pump() {
        while (true) {
            val t = lock.locked { if (tasks.isEmpty()) null else tasks.removeAt(0) }
            if (t != null) {
                t()
                continue
            }
            val w = lock.locked {
                if (wantWritable && budget > 0 && !closed) {
                    wantWritable = false
                    true
                } else false
            }
            if (w) {
                engine.onWritable(this)
                continue
            }
            val c = lock.locked { closed && !closedDelivered }
            if (c) {
                closedDelivered = true
                engine.onClosed(this)
            }
            return
        }
    }

    /** Simulates the peer closing: the loop reports EOF. */
    fun eof() {
        lock.locked { closed = true }
        pump()
    }

    val pendingWritable get() = lock.locked { wantWritable }

    fun text(): String = lock.locked { written.toByteArray().decodeToString() }

    /** Everything written so far, as bytes (for binary bodies such as gzip). */
    fun bytes(): ByteArray = lock.locked { written.toByteArray() }

    fun responses(): List<Resp> = parseResponses(lock.locked { written.toByteArray() })
}

class Resp(val status: Int, val reason: String, val headers: Map<String, String>, val body: String) {
    override fun toString() = "$status $reason $headers $body"
}

/** Splits a byte stream of HTTP/1.1 responses, framing strictly by Content-Length (as Go's client does). */
fun parseResponses(b: ByteArray): List<Resp> {
    val out = ArrayList<Resp>()
    var p = 0
    while (p < b.size) {
        val s = b.decodeToString(p, b.size)
        val he = s.indexOf("\r\n\r\n")
        require(he >= 0) { "incomplete response head: $s" }
        val lines = s.substring(0, he).split("\r\n")
        val sl = lines[0]
        require(sl.startsWith("HTTP/1.1 ")) { "bad status line: $sl" }
        val status = sl.substring(9, 12).toInt()
        val reason = sl.substring(13)
        val headers = LinkedHashMap<String, String>()
        for (l in lines.drop(1)) {
            val c = l.indexOf(':')
            require(c > 0) { "bad header line: $l" }
            val name = l.substring(0, c).lowercase()
            require(name !in headers) { "duplicate header $name" }
            headers[name] = l.substring(c + 1).trim()
        }
        p += (s.substring(0, he + 4)).encodeToByteArray().size
        val cl = headers["content-length"]
        val n = if (status < 200 || status == 204 || status == 304) {
            require(cl == null) { "$status with Content-Length" }
            0
        } else cl?.toInt() ?: error("no Content-Length on $status")
        require(p + n <= b.size) { "truncated body" }
        out.add(Resp(status, reason, headers, b.decodeToString(p, p + n)))
        p += n
    }
    return out
}

/** Requests parked by the "/async" route, answered later by the test (possibly from another thread). */
class Parked {
    private val lock = Monitor()
    private val items = ArrayList<Pair<Exchange, Continuation<Unit>>>()

    suspend fun park(ex: Exchange) = suspendCoroutineUninterceptedOrReturn { c ->
        lock.locked {
            items.add(ex to c)
            lock.signalAll()
        }
        COROUTINE_SUSPENDED
    }

    val size get() = lock.locked { items.size }

    /** Waits up to [ms] for a parked request and removes the oldest. */
    fun take(ms: Long = 5000): Pair<Exchange, Continuation<Unit>> = lock.locked {
        val deadline = conduit.platform.nanoTime() + ms * 1_000_000
        while (items.isEmpty()) {
            val left = deadline - conduit.platform.nanoTime()
            check(left > 0) { "nothing parked" }
            lock.awaitNanos(left)
        }
        items.removeAt(0)
    }
}

/** The test application: answers per path, writing bodies by hand into ex.out (JsonWriter is not needed). */
class TestApp {
    val parked = Parked()
    var handled = 0

    val handler: suspend (Exchange) -> Unit = { ex -> handle(ex) }

    suspend fun handle(ex: Exchange) {
        handled++
        check(ex.out.len == RESERVE) { "body must start after the reserved header area, len=${ex.out.len}" }
        when (ex.path) {
            "/async" -> {
                parked.park(ex)
                return // the test answered before resuming us
            }
            "/empty" -> ex.sendEmpty(204)
            "/empty200" -> ex.sendEmpty(200)
            "/error" -> ex.sendError(422, "bad \"thing\"\n\u0001 ü")
            "/throw" -> throw IllegalStateException("boom (expected by the test)")
            "/none" -> {}
            "/twice" -> {
                ex.out.putAscii("{}")
                ex.send(200)
                ex.sendError(500, "again")
                ex.send(201)
            }
            "/big" -> {
                val n = ex.query!!.toInt()
                val o = ex.out
                o.ensure(n)
                for (i in 0 until n) o.buf[o.len + i] = ('a'.code + i % 26).toByte()
                o.len += n
                ex.send(200)
            }
            else -> echo(ex, 200)
        }
    }
}

fun echo(ex: Exchange, status: Int) {
    ex.out.putUtf8("${ex.method} ${ex.path} q=${ex.query} a=${ex.authorization} n=${ex.body.size} b=${ex.body.decodeToString()}")
    ex.send(status)
}
