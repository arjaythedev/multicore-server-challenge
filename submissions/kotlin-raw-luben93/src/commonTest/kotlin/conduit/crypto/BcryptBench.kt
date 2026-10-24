package conduit.crypto

import conduit.platform.getenv
import conduit.platform.nanoTime
import kotlin.math.roundToLong
import kotlin.test.Test

/**
 * Cost-10 timing per lane count. Opt-in: BCRYPT_BENCH=1 (reps via BCRYPT_BENCH_REPS, default 8). Prints wall time
 * per batch and per hash; a busy machine inflates it.
 */
class BcryptBench {
    @Test
    fun cost10() {
        if (getenv("BCRYPT_BENCH") != "1") return
        val reps = getenv("BCRYPT_BENCH_REPS")?.toIntOrNull() ?: 8
        val key = Bcrypt.keyWords("password123".encodeToByteArray())
        val salt = Bcrypt.parse("\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")!!.salt
        fun r1(d: Double) = (d * 10).roundToLong() / 10.0
        for (round in 0 until 3) { // round 0 warms the JIT up
            val line = StringBuilder("bcrypt cost 10, round $round:")
            for (n in 1..Bcrypt.MAX_LANES) {
                val keys = Array(n) { key }
                val salts = Array(n) { salt }
                val outs = Array(n) { ByteArray(24) }
                val t0 = nanoTime()
                repeat(if (round == 0) 2 else reps) { Bcrypt.hashLanes(n, keys, salts, 10, outs) }
                val ms = (nanoTime() - t0) / 1e6 / (if (round == 0) 2 else reps)
                line.append(" | $n lane(s) ${r1(ms)} ms/batch = ${r1(ms / n)} ms/hash")
            }
            println(line)
        }
    }
}
