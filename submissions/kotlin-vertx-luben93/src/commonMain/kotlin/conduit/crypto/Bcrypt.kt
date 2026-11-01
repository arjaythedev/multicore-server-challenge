package conduit.crypto

import kotlin.jvm.JvmField

/**
 * bcrypt from scratch (Provos & Mazieres' EksBlowfish, bit-compatible with OpenBSD/Openwall for every key this
 * server can see). Verifies `$2a$`, `$2b$` and `$2y$` alike: they differ only for keys with 0xff bytes followed by
 * other high bytes (the `$2a$` "safety" quirk), and UTF-8 never contains 0xff. `$2x$` (the old sign-extension bug)
 * is rejected. New hashes are `$2b$`.
 *
 * The key is the password bytes plus a NUL, cycled to 72 bytes (a password of 72+ bytes is cut at 72, no NUL).
 *
 * The expensive part, 2^cost x 2 re-encryptions of the whole state, is in the generated [eks1]..[eks4]
 * (BcryptLanes.kt): one hash is a chain of ~68 M dependent S-box loads, so [hashLanes] computes up to [MAX_LANES]
 * independent hashes with their rounds interleaved, which costs about as much as one.
 */
object Bcrypt {
    const val MAX_LANES = 4
    const val MIN_COST = 4
    const val MAX_COST = 31

    /** bcrypt's radix-64 alphabet (not RFC 4648's). */
    private const val ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    private val DECODE = IntArray(128) { -1 }.also { t -> for (i in ALPHABET.indices) t[ALPHABET[i].code] = i }

    /** A parsed stored hash. */
    class Setting(@JvmField val cost: Int, @JvmField val salt: IntArray, @JvmField val expected: ByteArray)

    /** Parses a 60-char `$2a$`/`$2b$`/`$2y$` hash with cost 04..31; null if malformed. */
    fun parse(hash: String): Setting? {
        if (hash.length != 60 || hash[0] != '$' || hash[1] != '2' || hash[3] != '$' || hash[6] != '$') return null
        val v = hash[2]
        if (v != 'a' && v != 'b' && v != 'y') return null
        val c1 = hash[4] - '0'
        val c2 = hash[5] - '0'
        if (c1 !in 0..9 || c2 !in 0..9) return null
        val cost = c1 * 10 + c2
        if (cost < MIN_COST || cost > MAX_COST) return null
        val salt = ByteArray(16)
        val expected = ByteArray(23)
        if (!decode(hash, 7, salt, 16) || !decode(hash, 29, expected, 23)) return null
        return Setting(cost, saltWords(salt), expected)
    }

    /** The 18 big-endian key words: [password] bytes + NUL, cycled; at most 72 bytes are used. */
    fun keyWords(password: ByteArray): IntArray {
        val n = minOf(password.size, 72)
        val cycle = minOf(n + 1, 72) // the NUL is part of the cycle unless the key fills all 72 bytes
        val kw = IntArray(18)
        var p = 0
        for (i in 0 until 18) {
            var v = 0
            for (j in 0 until 4) {
                v = (v shl 8) or (if (p < n) password[p].toInt() and 0xff else 0)
                p = if (p + 1 == cycle) 0 else p + 1
            }
            kw[i] = v
        }
        return kw
    }

    /** 16 salt bytes as 4 big-endian words. */
    fun saltWords(salt: ByteArray): IntArray = IntArray(4) {
        ((salt[4 * it].toInt() and 0xff) shl 24) or ((salt[4 * it + 1].toInt() and 0xff) shl 16) or
            ((salt[4 * it + 2].toInt() and 0xff) shl 8) or (salt[4 * it + 3].toInt() and 0xff)
    }

    /**
     * Computes [n] (1..[MAX_LANES]) independent hashes of the same [cost] with interleaved lanes: keys[i] / salts[i]
     * (from [keyWords] / [saltWords]) give 24 raw bytes in outs[i] (bcrypt encodes the first 23).
     */
    fun hashLanes(n: Int, keys: Array<IntArray>, salts: Array<IntArray>, cost: Int, outs: Array<ByteArray>) {
        when (n) {
            1 -> eks1(keys[0], salts[0], cost, outs[0])
            2 -> eks2(keys[0], keys[1], salts[0], salts[1], cost, outs[0], outs[1])
            3 -> eks3(keys[0], keys[1], keys[2], salts[0], salts[1], salts[2], cost, outs[0], outs[1], outs[2])
            4 -> eks4(
                keys[0], keys[1], keys[2], keys[3], salts[0], salts[1], salts[2], salts[3], cost,
                outs[0], outs[1], outs[2], outs[3],
            )
            else -> throw IllegalArgumentException("lanes: $n")
        }
    }

    /** A new `$2b$` hash of [password] with the 16-byte [salt]. */
    fun hash(password: ByteArray, salt: ByteArray, cost: Int = 10): String {
        val raw = ByteArray(24)
        eks1(keyWords(password), saltWords(salt), cost, raw)
        return format(cost, salt, raw)
    }

    /** Single-lane verify against a stored hash (malformed hash -> false). */
    fun verify(password: ByteArray, hash: String): Boolean {
        val s = parse(hash) ?: return false
        val raw = ByteArray(24)
        eks1(keyWords(password), s.salt, s.cost, raw)
        return matches(raw, s.expected)
    }

    /** Constant-time compare of the first 23 raw bytes with the stored ones. */
    fun matches(raw: ByteArray, expected: ByteArray): Boolean {
        var d = 0
        for (i in 0 until 23) d = d or (raw[i].toInt() xor expected[i].toInt())
        return d == 0
    }

    /** `$2b$<cost>$` + 22 chars of salt + 31 chars of the first 23 raw bytes. */
    fun format(cost: Int, salt: ByteArray, raw: ByteArray): String {
        val sb = StringBuilder(60)
        sb.append("\$2b\$").append(('0' + cost / 10)).append(('0' + cost % 10)).append('$')
        encode(salt, 16, sb)
        encode(raw, 23, sb)
        return sb.toString()
    }

    private fun encode(d: ByteArray, len: Int, sb: StringBuilder) {
        var i = 0
        while (i < len) {
            var c1 = d[i++].toInt() and 0xff
            sb.append(ALPHABET[c1 ushr 2])
            c1 = (c1 and 0x03) shl 4
            if (i >= len) { sb.append(ALPHABET[c1]); break }
            var c2 = d[i++].toInt() and 0xff
            sb.append(ALPHABET[c1 or (c2 ushr 4)])
            c1 = (c2 and 0x0f) shl 2
            if (i >= len) { sb.append(ALPHABET[c1]); break }
            c2 = d[i++].toInt() and 0xff
            sb.append(ALPHABET[c1 or (c2 ushr 6)])
            sb.append(ALPHABET[c2 and 0x3f])
        }
    }

    private fun digit(s: String, i: Int): Int {
        val c = s[i].code
        return if (c < 128) DECODE[c] else -1
    }

    /** Decodes exactly [n] bytes from s[off..]; unused trailing bits are ignored, as in Openwall. */
    private fun decode(s: String, off: Int, out: ByteArray, n: Int): Boolean {
        var o = 0
        var i = off
        while (o < n) {
            val c1 = digit(s, i++)
            val c2 = digit(s, i++)
            if (c1 < 0 || c2 < 0) return false
            out[o++] = ((c1 shl 2) or ((c2 and 0x30) ushr 4)).toByte()
            if (o == n) break
            val c3 = digit(s, i++)
            if (c3 < 0) return false
            out[o++] = (((c2 and 0x0f) shl 4) or ((c3 and 0x3c) ushr 2)).toByte()
            if (o == n) break
            val c4 = digit(s, i++)
            if (c4 < 0) return false
            out[o++] = (((c3 and 0x03) shl 6) or c4).toByte()
        }
        return true
    }
}

// ---- cold helpers for the generated cores (setup and output are ~0.07% of the work at cost 10)

/** The salt cycled as an 18-word key, for ExpandKey(state, 0, salt). */
internal fun bfSaltKey(salt: IntArray): IntArray = IntArray(18) { salt[it and 3] }

/** Encrypts the block (lr[0], lr[1]) in place with the state [a]. */
private fun bfEncrypt(a: IntArray, lr: IntArray) {
    var l = lr[0] xor a[0]
    var r = lr[1]
    var i = 1
    while (i <= 16) {
        r = r xor a[i] xor bfF(a, l)
        l = l xor a[i + 1] xor bfF(a, r)
        i += 2
    }
    lr[0] = r xor a[17]
    lr[1] = l
}

private fun bfF(a: IntArray, x: Int): Int =
    ((a[18 + (x ushr 24)] + a[274 + ((x ushr 16) and 0xff)]) xor a[530 + ((x ushr 8) and 0xff)]) + a[786 + (x and 0xff)]

/**
 * The initial ExpandKey(state, salt, key): state = pi, P ^= key, then P and S are re-encrypted in place by one
 * chain whose input block is XORed with salt words (0,1), (2,3), (0,1), ... in turn.
 */
internal fun bfSetup(a: IntArray, key: IntArray, salt: IntArray) {
    BF_INIT.copyInto(a)
    for (i in 0 until 18) a[i] = a[i] xor key[i]
    val lr = IntArray(2)
    var sp = 0
    var i = 0
    while (i < 1042) {
        lr[0] = lr[0] xor salt[sp]
        lr[1] = lr[1] xor salt[sp + 1]
        sp = sp xor 2
        bfEncrypt(a, lr)
        a[i] = lr[0]
        a[i + 1] = lr[1]
        i += 2
    }
}

private val ORPHEAN = intArrayOf(0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274)

/** Encrypts "OrpheanBeholderScryDoubt" 64 times; the 24 bytes go to [out] big-endian. */
internal fun bfFinish(a: IntArray, out: ByteArray) {
    val lr = IntArray(2)
    for (j in 0 until 6 step 2) {
        lr[0] = ORPHEAN[j]
        lr[1] = ORPHEAN[j + 1]
        for (k in 0 until 64) bfEncrypt(a, lr)
        for (b in 0 until 2) {
            val v = lr[b]
            val p = (j + b) * 4
            out[p] = (v ushr 24).toByte()
            out[p + 1] = (v ushr 16).toByte()
            out[p + 2] = (v ushr 8).toByte()
            out[p + 3] = v.toByte()
        }
    }
}
