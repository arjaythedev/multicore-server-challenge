package conduit.crypto

/** Pure-Kotlin SHA-256 (FIPS 180-4). Used directly on Kotlin/Native; the JVM uses javax.crypto instead. */
class Sha256 {
    private val h = IntArray(8)
    private val w = IntArray(64)
    private val block = ByteArray(64)
    private var blockLen = 0
    private var total = 0L

    init { reset() }

    fun reset() {
        IV.copyInto(h)
        blockLen = 0
        total = 0
    }

    /** Restores a saved 8-word state after [blocks] full 64-byte blocks (HMAC midstates). */
    fun restore(state: IntArray, blocks: Long) {
        state.copyInto(h)
        blockLen = 0
        total = blocks * 64
    }

    fun state(): IntArray = h.copyOf()

    fun update(data: ByteArray, off: Int, len: Int) {
        var p = off
        var n = len
        total += len
        if (blockLen > 0) {
            val take = minOf(64 - blockLen, n)
            data.copyInto(block, blockLen, p, p + take)
            blockLen += take; p += take; n -= take
            if (blockLen == 64) { compress(block, 0); blockLen = 0 }
        }
        while (n >= 64) {
            compress(data, p)
            p += 64; n -= 64
        }
        if (n > 0) {
            data.copyInto(block, 0, p, p + n)
            blockLen = n
        }
    }

    fun digest(out: ByteArray, outOff: Int) {
        val bits = total * 8
        block[blockLen++] = 0x80.toByte()
        if (blockLen > 56) {
            block.fill(0, blockLen, 64)
            compress(block, 0)
            blockLen = 0
        }
        block.fill(0, blockLen, 56)
        for (i in 0 until 8) block[56 + i] = (bits ushr (56 - 8 * i)).toByte()
        compress(block, 0)
        for (i in 0 until 8) {
            val v = h[i]
            out[outOff + 4 * i] = (v ushr 24).toByte()
            out[outOff + 4 * i + 1] = (v ushr 16).toByte()
            out[outOff + 4 * i + 2] = (v ushr 8).toByte()
            out[outOff + 4 * i + 3] = v.toByte()
        }
        reset()
    }

    private fun compress(b: ByteArray, off: Int) {
        val w = w
        for (i in 0 until 16) {
            val p = off + 4 * i
            w[i] = ((b[p].toInt() and 0xFF) shl 24) or ((b[p + 1].toInt() and 0xFF) shl 16) or
                ((b[p + 2].toInt() and 0xFF) shl 8) or (b[p + 3].toInt() and 0xFF)
        }
        for (i in 16 until 64) {
            val x = w[i - 15]
            val y = w[i - 2]
            val s0 = x.rotateRight(7) xor x.rotateRight(18) xor (x ushr 3)
            val s1 = y.rotateRight(17) xor y.rotateRight(19) xor (y ushr 10)
            w[i] = w[i - 16] + s0 + w[i - 7] + s1
        }
        var a = h[0]; var bb = h[1]; var c = h[2]; var d = h[3]
        var e = h[4]; var f = h[5]; var g = h[6]; var hh = h[7]
        for (i in 0 until 64) {
            val s1 = e.rotateRight(6) xor e.rotateRight(11) xor e.rotateRight(25)
            val ch = (e and f) xor (e.inv() and g)
            val t1 = hh + s1 + ch + K[i] + w[i]
            val s0 = a.rotateRight(2) xor a.rotateRight(13) xor a.rotateRight(22)
            val maj = (a and bb) xor (a and c) xor (bb and c)
            val t2 = s0 + maj
            hh = g; g = f; f = e; e = d + t1
            d = c; c = bb; bb = a; a = t1 + t2
        }
        h[0] += a; h[1] += bb; h[2] += c; h[3] += d
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    }

    companion object {
        private val IV = intArrayOf(
            0x6a09e667, -0x4498517b, 0x3c6ef372, -0x5ab00ac6, 0x510e527f, -0x64fa9774, 0x1f83d9ab, 0x5be0cd19,
        )
        private val K = intArrayOf(
            0x428a2f98, 0x71374491, -0x4a3f0431, -0x164a245b, 0x3956c25b, 0x59f111f1, -0x6dc07d5c, -0x54e3a12b,
            -0x27f85568, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, -0x7f214e02, -0x6423f959, -0x3e640e8c,
            -0x1b64963f, -0x1041b87a, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            -0x67c1aeae, -0x57ce3993, -0x4ffcd838, -0x40a68039, -0x391ff40d, -0x2a586eb9, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, -0x7e3d36d2, -0x6d8dd37b,
            -0x5d40175f, -0x57e599b5, -0x3db47490, -0x3893ae5d, -0x2e6d17e7, -0x2966f9dc, -0xbf1ca7b, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, -0x7b3787ec, -0x7338fdf8, -0x6f410006, -0x5baf9315, -0x41065c09, -0x398e870e,
        )

        fun digest(data: ByteArray): ByteArray {
            val s = Sha256()
            s.update(data, 0, data.size)
            val out = ByteArray(32)
            s.digest(out, 0)
            return out
        }
    }
}

/**
 * HMAC-SHA256 with the key schedule done once: the inner and outer pad midstates are precomputed, so each MAC
 * hashes only the message plus one outer block. Not thread-safe.
 */
class HmacSha256Impl(key: ByteArray) {
    private val sha = Sha256()
    private val inner: IntArray
    private val outer: IntArray
    private val tmp = ByteArray(32)

    init {
        val k = ByteArray(64)
        if (key.size > 64) Sha256.digest(key).copyInto(k) else key.copyInto(k)
        val pad = ByteArray(64)
        for (i in 0 until 64) pad[i] = (k[i].toInt() xor 0x36).toByte()
        sha.update(pad, 0, 64); inner = sha.state(); sha.reset()
        for (i in 0 until 64) pad[i] = (k[i].toInt() xor 0x5c).toByte()
        sha.update(pad, 0, 64); outer = sha.state(); sha.reset()
    }

    fun mac(data: ByteArray, off: Int, len: Int, out: ByteArray, outOff: Int) {
        sha.restore(inner, 1)
        sha.update(data, off, len)
        sha.digest(tmp, 0)
        sha.restore(outer, 1)
        sha.update(tmp, 0, 32)
        sha.digest(out, outOff)
    }
}
