package conduit.crypto

import conduit.platform.getenv
import conduit.platform.nanoTime
import kotlin.math.roundToLong
import kotlin.test.Test

/** CPU time of the calling thread in nanoseconds (benchmarks only). */
internal expect fun threadCpuNanos(): Long

/**
 * Cost-10 timing of the C kernel (every lane count) and the Kotlin lanes, in this process. Opt-in: BCRYPT_BENCH=1
 * (batches per lane count via BCRYPT_BENCH_REPS, default 5). Prints wall and thread-CPU time per batch and CPU per
 * hash; run it pinned (taskset -c 3) on a quiet core.
 */
class BcryptKernelBench {
    @Test
    fun cost10() {
        if (getenv("BCRYPT_BENCH") != "1") return
        val reps = getenv("BCRYPT_BENCH_REPS")?.toIntOrNull() ?: 5
        val key = Bcrypt.keyWords("password123".encodeToByteArray())
        val salt = Bcrypt.parse("\$2a\$10\$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq")!!.salt
        fun r2(d: Double) = (d * 100).roundToLong() / 100.0
        fun measure(impl: String, n: Int, cost: Int, run: (Array<IntArray>, Array<IntArray>, Array<ByteArray>) -> Unit) {
            val keys = Array(n) { key }
            val salts = Array(n) { salt }
            val outs = Array(n) { ByteArray(24) }
            run(keys, salts, outs) // first call outside the timing
            val w0 = nanoTime()
            val c0 = threadCpuNanos()
            repeat(reps) { run(keys, salts, outs) }
            val wall = (nanoTime() - w0) / 1e6 / reps
            val cpu = (threadCpuNanos() - c0) / 1e6 / reps
            println("bcrypt cost $cost $impl n=$n: ${r2(wall)} ms/batch wall, ${r2(cpu)} ms/batch CPU = ${r2(cpu / n)} ms CPU/hash")
        }
        val why = BcryptC.open()
        if (why == null) {
            for (n in 1..BcryptKernel.MAX_LANES) {
                measure("C", n, 10) { k, s, o -> BcryptKernel.hashLanesC(n, k, s, 10, o) }
            }
        } else {
            println("bcrypt: C kernel unavailable: $why")
        }
        // the Kotlin lanes after the same JIT warm-up as Passwords (700 calls per lane count at cost 0)
        for (n in 1..Bcrypt.MAX_LANES) {
            val keys = Array(n) { key }
            val salts = Array(n) { salt }
            val outs = Array(n) { ByteArray(24) }
            repeat(700) { Bcrypt.hashLanes(n, keys, salts, 0, outs) }
        }
        for (n in 1..Bcrypt.MAX_LANES) {
            measure("Kotlin", n, 10) { k, s, o -> Bcrypt.hashLanes(n, k, s, 10, o) }
        }
    }
}
