package conduit.http

import conduit.platform.Monitor
import conduit.platform.nanoTime
import conduit.platform.readTextFile
import conduit.platform.startThread
import conduit.db.sleepNanos
import conduit.util.ByteBuf
import kotlin.concurrent.Volatile

/**
 * Appends a gzip stream (RFC 1952: header, raw deflate at the fastest level, CRC-32 and size trailer) of
 * src[off, off + len) to [dst]. False if this platform has no compressor or compressing failed ([dst] may then hold a
 * partial stream: the caller discards it).
 */
expect fun gzip(src: ByteArray, off: Int, len: Int, dst: ByteBuf): Boolean

/**
 * Response compression only when the network is the bottleneck (HTTP_GZIP; the leaderboard's #1 entry does the same):
 * gzip costs CPU on every response, and the box is CPU-bound up to the point where its network link fills.
 * - HTTP_GZIP=0: never. HTTP_GZIP=1: always (to measure the CPU cost). Unset: adaptive.
 * - Adaptive: once a second a thread reads the kernel's counters, bytes sent on the real network interfaces
 *   (/proc/net/dev, loopback excluded) and TCP retransmits (/proc/net/snmp). Gzip turns on while the box sends more
 *   than GZIP_ABOVE_MBPS (default 100 MB/s) AND segments are being retransmitted (the link is full), and off again
 *   after 10 seconds without both. Nothing is counted per request; a loopback-only test never turns it on.
 * - Only bodies of at least [MIN_BODY] bytes, only to clients that sent Accept-Encoding: gzip, and only if the result
 *   is smaller.
 */
object Gzip {
    const val MIN_BODY = 1024

    private const val OFF = 0
    private const val ALWAYS = 1
    private const val ADAPTIVE = 2
    private const val HOLD_SECONDS = 10

    private var mode = OFF

    /** Read on every eligible response: set by [configure] (ALWAYS) or the egress monitor (ADAPTIVE). */
    @Volatile
    var active = false
        private set

    // statistics, approximate (unsynchronized counters, for the log only)
    private var responses = 0L
    private var bytesIn = 0L
    private var bytesOut = 0L

    /** From HTTP_GZIP ("0", "1", or null/anything else = adaptive); starts the egress monitor in adaptive mode. */
    fun configure(setting: String?, aboveMBps: Int) {
        mode = when (setting?.trim()) {
            "0" -> OFF
            "1" -> ALWAYS
            else -> ADAPTIVE
        }
        active = mode == ALWAYS
        if (mode == ADAPTIVE) startMonitor(aboveMBps.toLong() * 1_000_000L)
    }

    val description: String
        get() = when (mode) {
            OFF -> "off"
            ALWAYS -> "always"
            else -> "adaptive"
        }

    internal fun count(original: Int, compressed: Int) {
        responses++
        bytesIn += original
        bytesOut += compressed
    }

    private fun startMonitor(aboveBytesPerSec: Long) {
        if (readTextFile("/proc/net/dev") == null) {
            println("gzip: adaptive, but /proc/net/dev is unreadable here: off")
            return
        }
        startThread("gzip-egress") {
            val m = Monitor()
            var tx0 = txBytes()
            var re0 = retransmits()
            var t0 = nanoTime()
            var quiet = HOLD_SECONDS
            while (true) {
                sleepNanos(m, 1_000_000_000L)
                val tx = txBytes()
                val re = retransmits()
                val t = nanoTime()
                val rate = if (t > t0) (tx - tx0) * 1_000_000_000L / (t - t0) else 0L
                val full = rate >= aboveBytesPerSec && re > re0
                quiet = if (full) 0 else quiet + 1
                val on = quiet < HOLD_SECONDS
                if (on != active) {
                    active = on
                    println(
                        "gzip: ${if (on) "on" else "off"} (sending ${rate / 1_000_000} MB/s, ${re - re0} retransmits/s; " +
                            "so far $responses responses, $bytesIn -> $bytesOut bytes)",
                    )
                }
                tx0 = tx
                re0 = re
                t0 = t
            }
        }
    }

    /** Bytes sent on all interfaces but loopback (/proc/net/dev: "name: rx bytes ... (8 rx fields) tx bytes ..."). */
    private fun txBytes(): Long {
        val text = readTextFile("/proc/net/dev") ?: return 0L
        var sum = 0L
        for (line in text.lineSequence()) {
            val colon = line.indexOf(':')
            if (colon < 0) continue
            if (line.substring(0, colon).trim() == "lo") continue
            val f = line.substring(colon + 1).trim().split(Regex("\\s+"))
            if (f.size > 8) sum += f[8].toLongOrNull() ?: 0L
        }
        return sum
    }

    /** TCP segments retransmitted since boot (/proc/net/snmp: a "Tcp:" header line, then a "Tcp:" value line). */
    private fun retransmits(): Long {
        val text = readTextFile("/proc/net/snmp") ?: return 0L
        val tcp = text.lineSequence().filter { it.startsWith("Tcp:") }.toList()
        if (tcp.size < 2) return 0L
        val names = tcp[0].split(Regex("\\s+"))
        val values = tcp[1].split(Regex("\\s+"))
        val i = names.indexOf("RetransSegs")
        return if (i in values.indices) values[i].toLongOrNull() ?: 0L else 0L
    }
}
