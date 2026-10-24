package conduit.platform

import conduit.http.HttpEngine
import java.io.File
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertTrue

/** Out of descriptors: accept must back off (not spin) and recover once fds are free again. */
class EmfileTest {
    @Test
    fun acceptBacksOffAndRecovers() = probe("nio")

    @Test
    fun acceptBacksOffAndRecoversOnEpoll() = probe("epoll")

    private fun probe(io: String) {
        val port = NioHttpTest.freePort(3171)
        val java = File(System.getProperty("java.home"), "bin/java").path
        val cp = System.getProperty("java.class.path")
        // ulimit -n sets soft and hard, so the JVM cannot raise it back (MaxFDLimit)
        val pb = ProcessBuilder("bash", "-c",
            "ulimit -n 256 && exec \"$java\" --enable-native-access=ALL-UNNAMED -cp \"$cp\" conduit.platform.EmfileProbe $port")
        pb.environment()["HTTP_IO"] = io
        val p = pb.redirectErrorStream(true).start()
        assertTrue(p.waitFor(60, TimeUnit.SECONDS), "probe hung")
        val out = p.inputStream.bufferedReader().readText()
        val pauses = out.lines().count { it.contains("pausing accepts") }
        assertTrue("probe: served after exhaustion" in out, out)
        assertTrue(pauses in 1..20, "expected a few 100 ms pauses, got $pauses:\n$out")
    }
}

/** Child process of [EmfileTest]. */
object EmfileProbe {
    @JvmStatic
    fun main(args: Array<String>) {
        val port = args[0].toInt()
        startHttpServer("127.0.0.1", port, 1, HttpEngine { ex ->
            ex.out.putAscii("{}")
            ex.send(200)
        })
        val clients = ArrayList<Socket>()
        try {
            repeat(1000) { clients.add(Socket().apply { connect(InetSocketAddress("127.0.0.1", port), 2000) }) }
        } catch (_: IOException) { // the client side ran out first: the server is starved too
        }
        Thread.sleep(500) // queued connections: accept fails with EMFILE, loop backs off
        clients.forEach { it.close() }
        Thread.sleep(500)
        Socket("127.0.0.1", port).use { s ->
            s.soTimeout = 5000
            s.getOutputStream().write("GET /x HTTP/1.1\r\n\r\n".toByteArray())
            val r = s.getInputStream().readNBytes(12).decodeToString()
            println(if (r == "HTTP/1.1 200") "probe: served after exhaustion" else "probe: bad response '$r'")
        }
        System.out.flush()
        Runtime.getRuntime().halt(0)
    }
}
