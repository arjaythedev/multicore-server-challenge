package conduit.crypto

import conduit.platform.getenv
import kotlin.concurrent.Volatile

/**
 * The C bcrypt kernel, native/conduit-bcrypt.c: the vendored Openwall core with up to 8 hashes interleaved
 * (JVM: a shared library built by build.sh, called through the FFM API; Kotlin/Native: compiled in by cinterop).
 */
internal expect object BcryptC {
    /** Makes the kernel callable and runs its C self-test. Null when usable, else the reason. Called at startup. */
    fun open(): String?

    /**
     * [n] (1..8) hashes of one [cost]: [keys] n x 18 words ([Bcrypt.keyWords]), [salts] n x 4 ([Bcrypt.saltWords]);
     * [out] gets n x 6 words, the 24 raw bytes of each as big-endian words. Only after [open] returned null.
     */
    fun lanes(n: Int, keys: IntArray, salts: IntArray, cost: Int, out: IntArray)
}

/**
 * Computes a batch of bcrypt lanes with the C kernel when it loads and reproduces known hashes (cost 10: ~12.5 ms
 * CPU per hash at 8 lanes), else with the pure-Kotlin lanes ([Bcrypt.hashLanes], at most 4: 18-23 ms per hash).
 * Both take the same key and salt words and give the same bytes for every password, including ones with a NUL.
 * `BCRYPT_IMPL=kotlin` forces the Kotlin lanes.
 */
object BcryptKernel {
    /** Lanes per batch of the C kernel; [Bcrypt.MAX_LANES] for the Kotlin lanes. */
    const val MAX_LANES = 8

    @Volatile
    private var useC = false

    /** The C kernel is in use. */
    val native: Boolean get() = useC

    /** Most jobs worth batching with the implementation in use. */
    val maxLanes: Int get() = if (useC) MAX_LANES else Bcrypt.MAX_LANES

    /** Chooses the implementation (once, at startup) and describes the choice for the log. */
    fun init(): String =
        select(if (getenv("BCRYPT_IMPL")?.trim() == "kotlin") "BCRYPT_IMPL=kotlin" else BcryptC.open())

    /**
     * Uses the C kernel if it opened ([unavailable] == null) and reproduces known hashes for every lane count (this
     * checks the call and the word layout end to end), else the Kotlin lanes. Returns the description.
     */
    internal fun select(unavailable: String?): String {
        val why = unavailable ?: try {
            checkC()
        } catch (t: Throwable) {
            t.toString()
        }
        useC = why == null
        return if (why == null) {
            "C lanes (Openwall core), up to $MAX_LANES per batch"
        } else {
            "Kotlin lanes, up to ${Bcrypt.MAX_LANES} per batch (C kernel not used: $why)"
        }
    }

    /** Like [Bcrypt.hashLanes] for [n] in 1..[maxLanes]: keys[i] / salts[i] give 24 raw bytes in outs[i]. */
    fun hashLanes(n: Int, keys: Array<IntArray>, salts: Array<IntArray>, cost: Int, outs: Array<ByteArray>) {
        if (useC) hashLanesC(n, keys, salts, cost, outs) else hashLanesKotlin(n, keys, salts, cost, outs)
    }

    internal fun hashLanesC(n: Int, keys: Array<IntArray>, salts: Array<IntArray>, cost: Int, outs: Array<ByteArray>) {
        require(n in 1..MAX_LANES) { "lanes: $n" }
        val k = IntArray(n * 18)
        val s = IntArray(n * 4)
        val o = IntArray(n * 6)
        for (i in 0 until n) {
            keys[i].copyInto(k, i * 18)
            salts[i].copyInto(s, i * 4)
        }
        try {
            BcryptC.lanes(n, k, s, cost, o)
        } finally {
            k.fill(0)
        }
        for (i in 0 until n) {
            val out = outs[i]
            for (w in 0 until 6) {
                val v = o[i * 6 + w]
                out[4 * w] = (v ushr 24).toByte()
                out[4 * w + 1] = (v ushr 16).toByte()
                out[4 * w + 2] = (v ushr 8).toByte()
                out[4 * w + 3] = v.toByte()
            }
        }
    }

    /** The Kotlin lanes, in chunks of at most [Bcrypt.MAX_LANES]. */
    internal fun hashLanesKotlin(n: Int, keys: Array<IntArray>, salts: Array<IntArray>, cost: Int, outs: Array<ByteArray>) {
        if (n <= Bcrypt.MAX_LANES) return Bcrypt.hashLanes(n, keys, salts, cost, outs)
        var i = 0
        while (i < n) {
            val m = minOf(Bcrypt.MAX_LANES, n - i)
            Bcrypt.hashLanes(m, keys.copyOfRange(i, i + m), salts.copyOfRange(i, i + m), cost, outs.copyOfRange(i, i + m))
            i += m
        }
    }

    /** Every lane count with different known hashes in its lanes; null if all match, else what failed. */
    private fun checkC(): String? {
        val keys = Array(CHECK.size) { Bcrypt.keyWords(CHECK[it].first.encodeToByteArray()) }
        val settings = Array(CHECK.size) { checkNotNull(Bcrypt.parse(CHECK[it].second)) }
        for (n in 1..MAX_LANES) {
            for (rot in intArrayOf(0, 5)) {
                val v = IntArray(n) { (it + rot) % CHECK.size }
                val outs = Array(n) { ByteArray(24) }
                hashLanesC(n, Array(n) { keys[v[it]] }, Array(n) { settings[v[it]].salt }, 4, outs)
                for (l in 0 until n) {
                    if (!Bcrypt.matches(outs[l], settings[v[l]].expected)) return "wrong hash in lane $l of $n"
                }
            }
        }
        return null
    }

    /** Cost-4 Openwall vectors (all in BcryptTest): ASCII, the 71/72-byte cutoff, UTF-8, $2a/$2b/$2y. */
    private val CHECK = listOf(
        "password123" to "\$2b\$04\$abcdefghijklmnopqrstuuK7Sjs7rFYArh/ytIZsOeM/z4RV2Fw2i",
        "p".repeat(72) to "\$2b\$04\$abcdefghijklmnopqrstuuNt.0ah97gHY3F7JC1Z6EXmQc0bQBhIO",
        "p".repeat(71) to "\$2b\$04\$abcdefghijklmnopqrstuuTYDowBoYf34KLYBHbWu7CBwc/8jbH1q",
        "één 🙂" to "\$2b\$04\$......................8s6VUJLJ1DDlV7xNO7sZksS.U52MSbu",
        "batch self test" to "\$2a\$04\$abcdefghijklmnopqrstuuM5.Jm4ZjoirouZjlg2TjPbXhQEN/8Bm",
        "" to "\$2a\$04\$nKK3n9cMaPThguAma1nRKuewozV2YMjGVWlf7ZFzqeVxIS7omZJVO",
        "Z?" to "\$2y\$04\$WPZy5pmxeTXYosL3VjvB8eCjUmWp8He7cAFgZXO19HqtQ8XVsUmbS",
        "teu" to "\$2a\$04\$wuPc7yuWDOWJN2kH/2mIe.bQvONNYHJl6IX0Fq93FbJYTWymF.3yW",
    )
}
