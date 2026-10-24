package conduit.http

import conduit.platform.Monitor
import conduit.platform.locked
import conduit.platform.startThread
import kotlin.coroutines.resume
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class EngineTest {
    private val app = TestApp()
    private val engine = HttpEngine(app.handler)

    private fun conn() = FakeConn(engine)

    private fun get(path: String, extra: String = "") = "GET $path HTTP/1.1\r\nHost: x\r\n$extra\r\n"

    private fun post(path: String, body: String, extra: String = "") =
        "POST $path HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n" +
            "Content-Length: ${body.encodeToByteArray().size}\r\n$extra\r\n$body"

    private fun chunked(path: String, vararg chunks: String, trailer: String = "") =
        "POST $path HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n" +
            chunks.joinToString("") { "${it.encodeToByteArray().size.toString(16)}\r\n$it\r\n" } + "0\r\n$trailer\r\n"

    @Test
    fun simpleGet() {
        val c = conn()
        c.feed(get("/articles?limit=10&offset=0", "Authorization:   Token abc.def  \r\n"))
        val r = c.responses().single()
        assertEquals(200, r.status)
        assertEquals("OK", r.reason)
        assertEquals("application/json", r.headers["content-type"])
        assertEquals(r.body.encodeToByteArray().size.toString(), r.headers["content-length"])
        assertNull(r.headers["connection"])
        assertEquals("GET /articles q=limit=10&offset=0 a=Token abc.def n=0 b=", r.body)
        assertEquals(1, c.writes, "header and body leave in one write")
        assertFalse(c.closed)
    }

    @Test
    fun targetForms() {
        val c = conn()
        c.feed(get("/a") + get("/a?") + get("/a?x=1&y") + get("/p%20q?&limit=1") +
            "GET http://host:3000/abs?z=1 HTTP/1.1\r\n\r\n" + "GET http://host HTTP/1.1\r\n\r\n")
        assertEquals(
            listOf(
                "GET /a q=null a=null n=0 b=", "GET /a q= a=null n=0 b=", "GET /a q=x=1&y a=null n=0 b=",
                "GET /p%20q q=&limit=1 a=null n=0 b=", "GET /abs q=z=1 a=null n=0 b=", "GET / q=null a=null n=0 b=",
            ),
            c.responses().map { it.body },
        )
    }

    @Test
    fun methods() {
        val c = conn()
        c.feed(post("/x", "{}") + "PUT /x HTTP/1.1\r\nContent-Length: 2\r\n\r\nab" + "DELETE /x HTTP/1.1\r\n\r\n" +
            "PATCH /x HTTP/1.1\r\n\r\n")
        assertEquals(
            listOf("POST /x q=null a=null n=2 b={}", "PUT /x q=null a=null n=2 b=ab", "DELETE /x q=null a=null n=0 b=",
                "OTHER /x q=null a=null n=0 b="),
            c.responses().map { it.body },
        )
    }

    @Test
    fun keepAliveManySequential() {
        val c = conn()
        for (i in 0 until 100) c.feed(post("/n$i", "body$i"))
        val rs = c.responses()
        assertEquals(100, rs.size)
        for (i in 0 until 100) assertEquals("POST /n$i q=null a=null n=${"body$i".length} b=body$i", rs[i].body)
        assertFalse(c.closed)
    }

    private val mixed = get("/one", "Authorization: Token t1\r\n") + post("/two", "{\"a\":\"ü\"}") +
        chunked("/three", "hel", "lo wor", "ld") + get("/empty") + post("/four", "")

    private val mixedBodies = listOf(
        "GET /one q=null a=Token t1 n=0 b=", "POST /two q=null a=null n=10 b={\"a\":\"ü\"}",
        "POST /three q=null a=null n=11 b=hello world", "", "POST /four q=null a=null n=0 b=",
    )

    @Test
    fun pipelinedInOneRead() {
        val c = conn()
        c.feed(mixed)
        assertEquals(mixedBodies, c.responses().map { it.body })
        assertEquals(listOf(200, 200, 200, 204, 200), c.responses().map { it.status })
    }

    @Test
    fun splitAtEveryByteBoundary() {
        val all = mixed.encodeToByteArray()
        for (k in 1 until all.size) {
            val c = conn()
            c.feed(all, 0, k)
            c.feed(all, k, all.size - k)
            assertEquals(mixedBodies, c.responses().map { it.body }, "split at $k")
        }
    }

    @Test
    fun oneByteAtATime() {
        val all = mixed.encodeToByteArray()
        val c = conn()
        for (i in all.indices) c.feed(all, i, 1)
        assertEquals(mixedBodies, c.responses().map { it.body })
    }

    @Test
    fun pipelinedAsyncAnsweredInOrder() {
        val all = (get("/async") + post("/async", "abc") + chunked("/async", "x", "yz") + get("/sync"))
            .encodeToByteArray()
        for (k in 0..all.size) { // also split at every boundary while requests are in flight
            val c = conn()
            c.feed(all, 0, k)
            var fed = k == all.size
            val got = ArrayList<String>()
            repeat(3) {
                if (!fed && app.parked.size == 0) {
                    c.feed(all, k, all.size - k)
                    fed = true
                }
                val (ex, cont) = app.parked.take()
                echo(ex, 201)
                cont.resume(Unit)
                c.pump() // runs the posted drain of the buffered input
                got.add(ex.body.decodeToString())
            }
            if (!fed) c.feed(all, k, all.size - k)
            assertEquals(listOf("", "abc", "xyz"), got, "split $k")
            assertEquals(listOf(201, 201, 201, 200), c.responses().map { it.status }, "split $k")
            assertEquals(0, app.parked.size)
        }
    }

    @Test
    fun answerFromAnotherThread() {
        val c = conn()
        c.feed(get("/async") + get("/async") + get("/after"))
        repeat(2) {
            val (ex, cont) = app.parked.take()
            val done = Monitor()
            var finished = false
            startThread("answer") {
                echo(ex, 200)
                cont.resume(Unit)
                done.locked {
                    finished = true
                    done.signalAll()
                }
            }
            done.locked { while (!finished) done.await() }
            c.pump()
        }
        assertEquals(listOf("/async", "/async", "/after"), c.responses().map { it.body.split(' ')[1] })
    }

    @Test
    fun chunkedBodies() {
        val c = conn()
        c.feed(
            "POST /c HTTP/1.1\r\nTransfer-Encoding: Chunked\r\n\r\n" +
                "4;ext=1\r\nWiki\r\n5 \r\npedia\r\nE\r\n in\r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n" +
                "POST /d HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n" +
                "POST /e HTTP/1.1\nTransfer-Encoding: chunked\n\na\nabcdefghij\n0\n\n",
        )
        assertEquals(
            listOf("POST /c q=null a=null n=23 b=Wikipedia in\r\n\r\nchunks.", "POST /d q=null a=null n=0 b=",
                "POST /e q=null a=null n=10 b=abcdefghij"),
            c.responses().map { it.body },
        )
    }

    @Test
    fun chunkedMalformed() {
        for (bad in listOf("zz\r\nab\r\n0\r\n\r\n", "2\r\nabX\r\n0\r\n\r\n", "\r\n")) {
            val c = conn()
            c.feed("POST /c HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n$bad")
            val r = c.responses().single()
            assertEquals(400, r.status, bad)
            assertEquals("close", r.headers["connection"])
            assertTrue(c.closed)
        }
    }

    @Test
    fun expectContinue() {
        val c = conn()
        c.feed("POST /x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n")
        assertEquals("HTTP/1.1 100 Continue\r\n\r\n", c.text())
        c.feed("hello")
        val rs = c.responses()
        assertEquals(listOf(100, 200), rs.map { it.status })
        assertEquals("POST /x q=null a=null n=5 b=hello", rs[1].body)

        val d = conn() // body already there: no interim response
        d.feed("POST /x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\nhello")
        assertEquals(listOf(200), d.responses().map { it.status })

        val e = conn() // too large: refused without reading the body
        e.feed("POST /x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 2000000\r\n\r\n")
        assertEquals(listOf(413), e.responses().map { it.status })
        assertTrue(e.closed)

        val f = conn()
        f.feed("POST /x HTTP/1.1\r\nExpect: something\r\nContent-Length: 1\r\n\r\nx")
        assertEquals(listOf(417), f.responses().map { it.status })
    }

    @Test
    fun limits() {
        val big = "x".repeat(MAX_HEAD)
        val a = conn()
        a.feed("GET / HTTP/1.1\r\nX-Big: $big\r\n\r\n")
        assertEquals(431, a.responses().single().status)
        assertTrue(a.closed)

        val b = conn() // incomplete head over the limit, arriving in pieces
        b.feed("GET / HTTP/1.1\r\n")
        repeat(70) { b.feed("X-Pad-$it: ${"y".repeat(1000)}\r\n") }
        assertEquals(431, b.responses().single().status)
        assertTrue(b.closed)

        val c = conn()
        c.feed("POST / HTTP/1.1\r\nContent-Length: ${MAX_BODY + 1}\r\n\r\n")
        assertEquals(413, c.responses().single().status)
        assertTrue(c.closed)

        val d = conn() // exactly the limit is fine, in 64 KiB reads
        val body = ByteArray(MAX_BODY) { 'b'.code.toByte() }
        d.feed("POST /x HTTP/1.1\r\nContent-Length: $MAX_BODY\r\n\r\n")
        var p = 0
        while (p < body.size) {
            val n = minOf(65536, body.size - p)
            d.feed(body, p, n)
            p += n
        }
        assertTrue(d.responses().single().body.startsWith("POST /x q=null a=null n=$MAX_BODY b=bbb"))

        val e = conn() // chunked over the limit
        val chunk = "z".repeat(1 shl 16)
        e.feed("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")
        repeat(17) { e.feed("10000\r\n$chunk\r\n") }
        assertEquals(413, e.responses().single().status)
        assertTrue(e.closed)
    }

    @Test
    fun malformed() {
        val cases = listOf(
            "GARBAGE\r\n\r\n", "GET /\r\n\r\n", "GET / HTTP/2.0x\r\n\r\n", "GET / FTP/1.1\r\n\r\n",
            "GET  / HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\nNoColon\r\n\r\n", "GET / HTTP/1.1\r\nBad Name: x\r\n\r\n",
            "GET / HTTP/1.1\r\nHost : x\r\n\r\n", "GET / HTTP/1.1\r\n folded\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: abc\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: +5\r\n\r\n", "POST / HTTP/1.1\r\nContent-Length:\r\n\r\n",
            "POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nab",
            "POST / HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
            "POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", "GET /a\u0001b HTTP/1.1\r\n\r\n",
        )
        for (m in cases) {
            val c = conn()
            c.feed(m + get("/never"))
            val r = c.responses().single()
            assertEquals(400, r.status, m)
            assertEquals("close", r.headers["connection"], m)
            assertEquals("{\"errors\":{\"body\":[\"bad request\"]}}", r.body, m)
            assertTrue(c.closed, m)
        }
        val te = conn()
        te.feed("POST / HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n")
        assertEquals(501, te.responses().single().status)
    }

    @Test
    fun duplicateEqualContentLengthIsFine() {
        val c = conn()
        c.feed("POST /x HTTP/1.1\r\nContent-Length: 2\r\ncontent-length: 2\r\n\r\nab")
        assertEquals("POST /x q=null a=null n=2 b=ab", c.responses().single().body)
    }

    @Test
    fun connectionClose() {
        val c = conn()
        c.feed(get("/a", "Connection: close\r\n") + get("/never"))
        val r = c.responses().single()
        assertEquals("close", r.headers["connection"])
        assertTrue(c.closed)

        val d = conn()
        d.feed(get("/a", "Connection: Keep-Alive, CLOSE\r\n"))
        assertEquals("close", d.responses().single().headers["connection"])
        assertTrue(d.closed)
    }

    @Test
    fun http10() {
        val c = conn()
        c.feed("GET /a HTTP/1.0\r\n\r\n")
        assertEquals("close", c.responses().single().headers["connection"])
        assertTrue(c.closed)

        val d = conn()
        d.feed("GET /a HTTP/1.0\r\nConnection: keep-alive\r\n\r\nGET /b HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
        val rs = d.responses()
        assertEquals(listOf("keep-alive", "keep-alive"), rs.map { it.headers["connection"] })
        assertFalse(d.closed)
    }

    @Test
    fun partialWrites() {
        val c = conn()
        c.budget = 10
        c.feed(get("/big?5000") + get("/after"))
        assertTrue(c.pendingWritable)
        assertEquals(10, c.text().length)
        var rounds = 0
        while (c.pendingWritable) {
            c.budget = 7 // the socket drains a little at a time
            c.pump()
            check(++rounds < 10000)
        }
        val rs = c.responses()
        assertEquals(2, rs.size)
        assertEquals(5000, rs[0].body.length)
        assertEquals('a' + 4999 % 26, rs[0].body.last())
        assertEquals("GET /after q=null a=null n=0 b=", rs[1].body)
        assertFalse(c.closed)
    }

    @Test
    fun brokenSocketCloses() {
        val c = conn()
        c.feed(get("/async"))
        val (ex, cont) = app.parked.take()
        c.broken = true
        echo(ex, 200)
        cont.resume(Unit)
        c.pump()
        assertTrue(c.closed)
        c.feed(get("/x")) // dropped
        assertEquals("", c.text())
    }

    @Test
    fun closedWhileInFlight() {
        val c = conn()
        c.feed(get("/async"))
        val (ex, cont) = app.parked.take()
        c.eof()
        echo(ex, 200) // late answer: harmless
        cont.resume(Unit)
        assertEquals("", c.text())
    }

    @Test
    fun handlerFailures() {
        val c = conn()
        c.feed(get("/throw") + get("/none") + get("/twice") + get("/error") + get("/empty200") + get("/ok"))
        val rs = c.responses()
        assertEquals(listOf(500, 500, 200, 422, 200, 200), rs.map { it.status })
        assertEquals("{\"errors\":{\"body\":[\"internal server error\"]}}", rs[0].body)
        assertEquals("{}", rs[2].body)
        assertEquals("{\"errors\":{\"body\":[\"bad \\\"thing\\\"\\n\\u0001 ü\"]}}", rs[3].body)
        assertEquals("0", rs[4].headers["content-length"])
        assertEquals("application/json", rs[4].headers["content-type"])
        assertFalse(c.closed)
    }

    @Test
    fun noContent() {
        val c = conn()
        c.feed(get("/empty") + get("/ok"))
        val t = c.text()
        assertTrue(t.startsWith("HTTP/1.1 204 No Content\r\n\r\nHTTP/1.1 200 OK\r\n"), t)
    }

    @Test
    fun strayLineBreaksBetweenRequests() {
        val c = conn()
        c.feed(post("/a", "x") + "\r\n" + get("/b"))
        assertEquals(listOf("/a", "/b"), c.responses().map { it.body.split(' ')[1] })
    }

    @Test
    fun bufferReuseAfterLargeResponse() {
        val c = conn()
        c.feed(get("/big?100000") + get("/small") + get("/big?300000") + get("/small2"))
        val rs = c.responses()
        assertEquals(listOf(100000, 31, 300000, 32), rs.map { it.body.length })
    }

    @Test
    fun overflowWhileBusyCloses() {
        val c = conn()
        c.feed(get("/async"))
        val chunk = ByteArray(65536) { 'G'.code.toByte() }
        repeat(40) { c.feed(chunk) }
        assertTrue(c.closed)
    }
}
