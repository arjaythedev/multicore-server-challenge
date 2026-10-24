package conduit.auth

import conduit.platform.getenv
import conduit.platform.nanoTime
import kotlin.test.Test
import kotlin.test.assertEquals

/** Jwt.verify cost (runs on every request). Opt-in: JWT_BENCH=1. */
class JwtBench {
    @Test
    fun verify() {
        if (getenv("JWT_BENCH") != "1") return
        Jwt.init("multicore-server-challenge")
        val now = 1_700_000_000L
        val ours = Jwt.sign(123_456, now)
        // golang-jwt's sorted-key claims (the conformance suite's tokens)
        val go = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDI1OTIwMDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiMTAwIn0." +
            "PpiJjlw4qD5Np5mGEkrCB7GB9iGaUaZwLTvgWM5n-Jo"
        for ((name, t) in listOf("loadgen-style" to ours, "golang-jwt" to go)) {
            var sum = 0L
            for (round in 0 until 3) {
                val n = 200_000
                val t0 = nanoTime()
                repeat(n) { sum += Jwt.verify(t, now) }
                if (round == 2) println("Jwt.verify $name: ${(nanoTime() - t0) / n} ns")
            }
            assertEquals(if (t === ours) 123_456L * 600_000 else 100L * 600_000, sum)
        }
        // of which the platform HMAC over header.payload
        val msg = ours.substringBeforeLast('.').encodeToByteArray()
        val mac = conduit.platform.HmacSha256("multicore-server-challenge".encodeToByteArray())
        val out = ByteArray(32)
        for (round in 0 until 3) {
            val n = 200_000
            val t0 = nanoTime()
            repeat(n) { mac.mac(msg, 0, msg.size, out, 0) }
            if (round == 2) println("HmacSha256.mac ${msg.size} bytes: ${(nanoTime() - t0) / n} ns")
        }
        val impl = conduit.crypto.HmacSha256Impl("multicore-server-challenge".encodeToByteArray())
        for (round in 0 until 3) {
            val n = 200_000
            val t0 = nanoTime()
            repeat(n) { impl.mac(msg, 0, msg.size, out, 0) }
            if (round == 2) println("HmacSha256Impl.mac (pure Kotlin, midstates) ${msg.size} bytes: ${(nanoTime() - t0) / n} ns")
        }
    }
}
