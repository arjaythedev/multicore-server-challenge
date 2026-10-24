package conduit.platform

import conduit.http.Exchange
import conduit.http.HttpEngine
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.concurrent.thread
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn
import kotlin.coroutines.resume
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** End-to-end: the NIO loops + the common engine over real sockets. */
class NioHttpTest {
    companion object {
        private val timer: ScheduledExecutorService = Executors.newScheduledThreadPool(2) { r ->
            Thread(r, "answer").apply { isDaemon = true }
        }

        /** /slow?ms=N answers from a timer thread; /big?n=N sends N pattern bytes; anything else echoes. */
        suspend fun handle(ex: Exchange) {
            when (ex.path) {
                "/slow" -> {
                    val ms = ex.query!!.substringAfter("ms=").substringBefore('&').toLong()
                    suspendCoroutineUninterceptedOrReturn { c ->
                        timer.schedule({
                            echo(ex)
                            c.resume(Unit)
                        }, ms, TimeUnit.MILLISECONDS)
                        COROUTINE_SUSPENDED
                    }
                }
                "/big" -> {
                    val n = ex.query!!.substringAfter("n=").toInt()
                    val o = ex.out
                    o.ensure(n)
                    for (i in 0 until n) o.buf[o.len + i] = pattern(i)
                    o.len += n
                    ex.send(200)
                }
                else -> echo(ex)
            }
        }

        fun pattern(i: Int) = ('a'.code + (i * 7 + i / 1000) % 26).toByte()

        fun echo(ex: Exchange) {
            val q = ex.query?.let { "\"$it\"" } ?: "null"
            ex.out.putAscii("{\"method\":\"${ex.method}\",\"path\":\"${ex.path}\",\"query\":$q,\"len\":${ex.body.size}}")
            ex.send(200)
        }

        /** A port in 3101-3199 that nobody listens on (checked with a plain bind: SO_REUSEPORT would share it). */
        fun freePort(from: Int): Int {
            for (p in from..3199) {
                try {
                    ServerSocket().use { it.bind(InetSocketAddress("127.0.0.1", p)) }
                    return p
                } catch (_: Exception) {
                }
            }
            error("no free port")
        }

        val port: Int by lazy {
            val p = freePort(3101)
            startHttpServer("127.0.0.1", p, 2, HttpEngine { handle(it) })
            p
        }
    }

    class Client(port: Int, rcvBuf: Int = 0) : AutoCloseable {
        val s = Socket().apply {
            tcpNoDelay = true
            soTimeout = 20_000
            if (rcvBuf > 0) receiveBufferSize = rcvBuf
            connect(InetSocketAddress("127.0.0.1", port), 10_000)
        }
        val inp = BufferedInputStream(s.getInputStream(), 65536)
        private val out = s.getOutputStream()

        fun send(req: String) {
            out.write(req.toByteArray())
            out.flush()
        }

        fun read(): Resp = readResponse(inp)

        fun get(path: String): Resp {
            send("GET $path HTTP/1.1\r\nHost: t\r\n\r\n")
            return read()
        }

        /** True once the server has closed the connection (EOF, no extra bytes). */
        fun eof(): Boolean = try {
            inp.read() == -1
        } catch (_: SocketTimeoutException) {
            false
        }

        override fun close() = s.close()
    }

    /** [size]: bytes on the wire (head + body). */
    class Resp(val status: Int, val headers: Map<String, String>, val body: ByteArray, val size: Int) {
        val text get() = body.decodeToString()
    }

    @Test
    fun keepAlive100Sequential() {
        Client(port).use { c ->
            for (i in 0 until 100) {
                val r = c.get("/echo?i=$i")
                assertEquals(200, r.status)
                assertEquals("{\"method\":\"GET\",\"path\":\"/echo\",\"query\":\"i=$i\",\"len\":0}", r.text)
                assertEquals("application/json", r.headers["content-type"])
            }
        }
    }

    @Test
    fun pipelinedInOneWrite() {
        Client(port).use { c ->
            val body = "{\"user\":{}}"
            c.send(
                "GET /a HTTP/1.1\r\n\r\n" + "GET /slow?ms=30 HTTP/1.1\r\n\r\n" +
                    "POST /b HTTP/1.1\r\nContent-Length: ${body.length}\r\n\r\n$body" +
                    "GET /slow?ms=1 HTTP/1.1\r\n\r\n" + "DELETE /c HTTP/1.1\r\n\r\n",
            )
            val paths = (0 until 5).map { c.read().text.substringAfter("\"path\":\"").substringBefore('"') }
            assertEquals(listOf("/a", "/slow", "/b", "/slow", "/c"), paths)
        }
    }

    @Test
    fun bigResponsesReadSlowly() {
        Client(port, rcvBuf = 16 * 1024).use { c ->
            // 2 MB usually fits the kernel's autotuned send buffer (tcp_wmem max 4 MB); 12 MB cannot, so the
            // second response is finished by the loop after requestWritable/onWritable rounds
            for (n in intArrayOf(2 shl 20, 12 shl 20)) {
                c.send("GET /big?n=$n HTTP/1.1\r\n\r\nGET /after HTTP/1.1\r\n\r\n")
                Thread.sleep(200) // let the server fill the socket buffers
                val r = readResponse(c.inp, slow = true)
                assertEquals(n, r.body.size)
                for (i in 0 until n) if (r.body[i] != pattern(i)) error("byte $i differs")
                assertEquals(200, c.read().status) // the pipelined request after it, still in sync
            }
        }
    }

    @Test
    fun pipelinedStressAnsweredFromOtherThreads() {
        // answers race the loop buffering the next requests (the BUSY -> BUSY_INPUT -> IDLE hand-offs)
        val failures = AtomicLong()
        val batches = if (System.getenv("CONDUIT_BENCH") == "1") 1000 else 20
        val workers = (0 until 8).map { t ->
            thread {
                (0 until 6).map { Client(port) }.forEachIndexed { ci, c ->
                    c.use {
                        var seq = 0
                        repeat(batches) { batch ->
                            val sb = StringBuilder()
                            val n = 1 + (batch * 7 + ci) % 25
                            for (i in 0 until n) {
                                val s = seq + i
                                val path = if (s % 3 == 0) "/echo" else "/slow"
                                val q = if (path == "/slow") "ms=0&s=$s" else "s=$s"
                                if (s % 5 == 0) sb.append("POST $path?$q HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc")
                                else sb.append("GET $path?$q HTTP/1.1\r\n\r\n")
                            }
                            c.send(sb.toString())
                            for (i in 0 until n) {
                                val r = c.read()
                                if (r.status != 200 || !r.text.contains("s=${seq + i}\"")) failures.incrementAndGet()
                            }
                            seq += n
                        }
                    }
                }
            }
        }
        workers.forEach { it.join() }
        assertEquals(0, failures.get())
    }

    @Test
    fun manyConcurrentConnections() {
        val conns = 2000
        val threads = 8
        val failures = AtomicLong()
        val workers = (0 until threads).map { t ->
            thread {
                val cs = (0 until conns / threads).map { Client(port) }
                try {
                    for (round in 0 until 3) {
                        for ((i, c) in cs.withIndex()) {
                            val path = if (i % 10 == 0) "/slow?ms=5" else "/echo?c=$t.$i.$round"
                            c.send("GET $path HTTP/1.1\r\nAuthorization: Token x\r\n\r\n")
                        }
                        for ((i, c) in cs.withIndex()) {
                            val r = c.read()
                            val want = if (i % 10 == 0) "\"query\":\"ms=5\"" else "\"query\":\"c=$t.$i.$round\""
                            if (r.status != 200 || !r.text.contains(want)) failures.incrementAndGet()
                        }
                    }
                } finally {
                    cs.forEach { it.close() }
                }
            }
        }
        workers.forEach { it.join() }
        assertEquals(0, failures.get())
    }

    @Test
    fun http10() {
        Client(port).use { c ->
            c.send("GET /x HTTP/1.0\r\n\r\n")
            val r = c.read()
            assertEquals(200, r.status)
            assertEquals("close", r.headers["connection"])
            assertTrue(c.eof())
        }
        Client(port).use { c ->
            c.send("GET /x HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
            assertEquals("keep-alive", c.read().headers["connection"])
            c.send("GET /y HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
            assertEquals(200, c.read().status)
        }
    }

    @Test
    fun connectionClose() {
        Client(port).use { c ->
            c.send("GET /slow?ms=20 HTTP/1.1\r\nConnection: close\r\n\r\n")
            val r = c.read()
            assertEquals("close", r.headers["connection"])
            assertTrue(c.eof())
        }
    }

    @Test
    fun malformedGets400AndClose() {
        Client(port).use { c ->
            c.send("BLAH\r\n\r\n")
            val r = c.read()
            assertEquals(400, r.status)
            assertEquals("{\"errors\":{\"body\":[\"bad request\"]}}", r.text)
            assertTrue(c.eof())
        }
    }

    @Test
    fun chunkedAndExpect() {
        Client(port).use { c ->
            c.send("POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n")
            assertTrue(c.read().text.contains("\"len\":5"))
            c.send("POST /e HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n")
            assertEquals(100, c.read().status)
            c.send("abcd")
            assertTrue(c.read().text.contains("\"len\":4"))
        }
    }

    @Test
    fun clientGoneWhileInFlight() {
        Client(port).use { c -> c.send("GET /slow?ms=50 HTTP/1.1\r\n\r\n") } // closed before the answer
        Thread.sleep(100)
        Client(port).use { c -> assertEquals(200, c.get("/still-alive").status) }
    }

    /** Throughput with a trivial handler; prints req/s. Long run only with CONDUIT_BENCH=1. */
    @Test
    fun throughput() {
        val seconds = if (System.getenv("CONDUIT_BENCH") == "1") 10.0 else 1.0
        val conns = 200
        val token = "Token eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9." + "x".repeat(80) + "." + "y".repeat(43)
        val req = ("GET /api/articles?limit=10&offset=0 HTTP/1.1\r\nHost: 127.0.0.1\r\n" +
            "User-Agent: conduit-loadgen/1\r\nAccept: application/json\r\nAccept-Encoding: gzip\r\n" +
            "Authorization: $token\r\n\r\n").toByteArray()
        val respLen = Client(port).use { c ->
            c.send(String(req))
            c.read().size
        }
        val total = AtomicLong()
        val stopAt = System.nanoTime() + (seconds * 1e9).toLong()
        val clientThreads = 2
        val ts = (0 until clientThreads).map {
            thread {
                val sel = Selector.open()
                val rb = ByteBuffer.allocateDirect(65536)
                repeat(conns / clientThreads) {
                    val ch = SocketChannel.open(InetSocketAddress("127.0.0.1", port))
                    ch.configureBlocking(false)
                    ch.socket().tcpNoDelay = true
                    ch.register(sel, SelectionKey.OP_READ, IntArray(1))
                    ch.write(ByteBuffer.wrap(req))
                }
                var n = 0L
                while (System.nanoTime() < stopAt) {
                    sel.select({ k ->
                        val ch = k.channel() as SocketChannel
                        val got = k.attachment() as IntArray
                        rb.clear()
                        val r = ch.read(rb)
                        if (r > 0) {
                            got[0] += r
                            while (got[0] >= respLen) {
                                got[0] -= respLen
                                n++
                                ch.write(ByteBuffer.wrap(req))
                            }
                        }
                    }, 100)
                }
                total.addAndGet(n)
                sel.keys().forEach { it.channel().close() }
            }
        }
        ts.forEach { it.join() }
        val rps = total.get() / seconds
        println("throughput: ${"%.0f".format(rps)} req/s ($conns connections, 2 loops, trivial handler, ${seconds}s)")
        assertTrue(total.get() > 0)
    }

    /** Heap per idle connection (connections held by a separate python process). Only with CONDUIT_BENCH=1. */
    @Test
    fun idleMemory() {
        if (System.getenv("CONDUIT_BENCH") != "1") return
        val n = 5000
        val script = """
            import socket, sys
            cs = []
            for i in range($n):
                s = socket.create_connection(("127.0.0.1", $port))
                s.sendall(b"GET /x HTTP/1.1\r\n\r\n")
                cs.append(s)
            for s in cs:
                b = b""
                while not b.endswith(b"}"):
                    b += s.recv(4096)
            print("ready", flush=True)
            sys.stdin.read()
        """.trimIndent()
        fun heap(): Long {
            repeat(3) {
                System.gc()
                Thread.sleep(200)
            }
            val r = Runtime.getRuntime()
            return r.totalMemory() - r.freeMemory()
        }
        val before = heap()
        val p = ProcessBuilder("python3", "-c", script).redirectErrorStream(true).start()
        val line = p.inputStream.bufferedReader().readLine()
        assertEquals("ready", line)
        val after = heap()
        p.outputStream.close()
        p.waitFor()
        println("idle memory: ${(after - before) / n} bytes of heap per idle connection ($n connections)")
    }
}

private fun readLine(inp: InputStream, b: ByteArrayOutputStream): String {
    b.reset()
    while (true) {
        val c = inp.read()
        if (c < 0) error("EOF in head")
        b.write(c)
        if (c == '\n'.code) break
    }
    return b.toString(Charsets.ISO_8859_1).trimEnd('\r', '\n')
}

/** Reads one response, framed by Content-Length; [slow] reads the body in small pieces with pauses. */
fun readResponse(inp: InputStream, slow: Boolean = false): NioHttpTest.Resp {
    val lb = ByteArrayOutputStream()
    val sl = readLine(inp, lb)
    var size = lb.size()
    require(sl.startsWith("HTTP/1.1 ")) { "bad status line '$sl'" }
    val status = sl.substring(9, 12).toInt()
    val headers = LinkedHashMap<String, String>()
    while (true) {
        val l = readLine(inp, lb)
        size += lb.size()
        if (l.isEmpty()) break
        headers[l.substringBefore(':').lowercase()] = l.substringAfter(':').trim()
    }
    if (status < 200 || status == 204) return NioHttpTest.Resp(status, headers, ByteArray(0), size)
    val n = headers["content-length"]!!.toInt()
    val body = ByteArray(n)
    var p = 0
    while (p < n) {
        val r = inp.read(body, p, if (slow) minOf(n - p, 16384) else n - p)
        if (r < 0) error("EOF in body")
        p += r
        if (slow && p % 65536 < 16384) Thread.sleep(1)
    }
    return NioHttpTest.Resp(status, headers, body, size + n)
}
