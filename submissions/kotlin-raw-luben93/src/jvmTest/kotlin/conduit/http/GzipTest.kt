package conduit.http

import conduit.util.ByteBuf
import java.util.zip.GZIPInputStream
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class GzipTest {
    private val app = TestApp()
    private val engine = HttpEngine(app.handler)

    @AfterTest
    fun off() = Gzip.configure("0", 100) // Gzip is global: leave it off for the other tests

    private fun gunzip(b: ByteArray, off: Int, len: Int): ByteArray =
        GZIPInputStream(b.inputStream(off, len)).readAllBytes()

    private fun pattern(n: Int) = ByteArray(n) { ('a'.code + it % 26).toByte() }

    @Test
    fun roundTrip() {
        for (n in listOf(1, 1024, 8000, 200_000)) {
            val src = ByteArray(n + 7) { (it * 31 % 251).toByte() }
            val dst = ByteBuf(16)
            dst.len = 5 // like a response buffer: appended after what is there
            assertTrue(gzip(src, 7, n, dst))
            assertContentEquals(src.copyOfRange(7, 7 + n), gunzip(dst.buf, 5, dst.len - 5), "n=$n")
        }
    }

    /** One response from [c]: its head lines (lowercased names) and raw body bytes, framed by Content-Length. */
    private fun single(c: FakeConn): Pair<Map<String, String>, ByteArray> {
        val b = c.bytes()
        val s = b.decodeToString()
        val he = s.indexOf("\r\n\r\n")
        val headers = s.substring(0, he).split("\r\n").drop(1).associate {
            it.substringBefore(':').lowercase() to it.substringAfter(':').trim()
        }
        val start = s.substring(0, he + 4).encodeToByteArray().size
        val n = headers.getValue("content-length").toInt()
        assertEquals(b.size, start + n, "exactly one response")
        return headers to b.copyOfRange(start, start + n)
    }

    @Test
    fun alwaysGzipsLargeBodiesForClientsThatAsk() {
        Gzip.configure("1", 100)
        val c = FakeConn(engine)
        c.feed("GET /big?5000 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: deflate, gzip\r\n\r\n")
        val (h, body) = single(c)
        assertEquals("gzip", h["content-encoding"])
        assertTrue(body.size < 5000)
        assertContentEquals(pattern(5000), gunzip(body, 0, body.size))
        assertEquals(1, c.writes, "header and body leave in one write")
    }

    @Test
    fun plainWhenNotAskedTooSmallOrOff() {
        Gzip.configure("1", 100)
        for (req in listOf(
            "GET /big?5000 HTTP/1.1\r\nHost: x\r\n\r\n", // no Accept-Encoding
            "GET /big?5000 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: br, gzip;q=0\r\n\r\n", // gzip refused
            "GET /big?500 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n", // under MIN_BODY
        )) {
            val c = FakeConn(engine)
            c.feed(req)
            val (h, body) = single(c)
            assertNull(h["content-encoding"], req)
            assertContentEquals(pattern(body.size), body)
        }
        Gzip.configure("0", 100)
        assertFalse(Gzip.active)
        val c = FakeConn(engine)
        c.feed("GET /big?5000 HTTP/1.1\r\nHost: x\r\nAccept-Encoding: gzip\r\n\r\n")
        assertNull(single(c).first["content-encoding"])
    }
}
