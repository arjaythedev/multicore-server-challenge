package conduit.app

/**
 * Percent-decoding of path segments and query components. Keys decoded here go straight into a batched statement's
 * text[] parameter, and Postgres rejects NUL and invalid UTF-8 in text, which would fail every request in the batch.
 * So a value that decodes to such bytes never reaches Postgres: it can't equal any stored name either.
 */
internal object Url {
    /** Stands for a decoded value that Postgres text can't hold (never a real decoded value: it is a NUL). */
    const val INVALID = "\u0000"

    /**
     * Decodes s[from, to): `%XX` escapes, and `+` as a space when [plus] (query strings). Returns null on a malformed
     * escape; [invalid] when the result contains NUL or is not valid UTF-8. Without escapes this is a substring (or
     * [s] itself).
     */
    fun decode(s: String, from: Int = 0, to: Int = s.length, plus: Boolean = false, invalid: String? = null): String? {
        var i = from
        while (i < to) {
            val c = s[i]
            if (c == '%' || (plus && c == '+') || c == '\u0000') break
            i++
        }
        if (i == to) return if (from == 0 && to == s.length) s else s.substring(from, to)
        val out = ByteArray((to - from) * 3)
        var n = 0
        i = from
        while (i < to) {
            val c = s[i]
            when {
                c == '%' -> {
                    if (i + 2 >= to) return null
                    val h = hex(s[i + 1])
                    val l = hex(s[i + 2])
                    if (h < 0 || l < 0) return null
                    out[n++] = ((h shl 4) or l).toByte()
                    i += 3
                    continue
                }
                plus && c == '+' -> out[n++] = ' '.code.toByte()
                c.code < 0x80 -> out[n++] = c.code.toByte()
                // Non-ASCII chars in the raw target (clients never send them): re-encode as UTF-8.
                c.code < 0x800 -> {
                    out[n++] = (0xC0 or (c.code shr 6)).toByte()
                    out[n++] = (0x80 or (c.code and 0x3F)).toByte()
                }
                c.isHighSurrogate() && i + 1 < to && s[i + 1].isLowSurrogate() -> {
                    val cp = 0x10000 + ((c.code - 0xD800) shl 10) + (s[i + 1].code - 0xDC00)
                    out[n++] = (0xF0 or (cp shr 18)).toByte()
                    out[n++] = (0x80 or ((cp shr 12) and 0x3F)).toByte()
                    out[n++] = (0x80 or ((cp shr 6) and 0x3F)).toByte()
                    out[n++] = (0x80 or (cp and 0x3F)).toByte()
                    i++
                }
                else -> { // a lone surrogate encodes to bytes validUtf8 rejects
                    out[n++] = (0xE0 or (c.code shr 12)).toByte()
                    out[n++] = (0x80 or ((c.code shr 6) and 0x3F)).toByte()
                    out[n++] = (0x80 or (c.code and 0x3F)).toByte()
                }
            }
            i++
        }
        if (!validUtf8(out, 0, n)) return invalid
        return out.decodeToString(0, n)
    }

    private fun hex(c: Char): Int = when (c) {
        in '0'..'9' -> c - '0'
        in 'a'..'f' -> c - 'a' + 10
        in 'A'..'F' -> c - 'A' + 10
        else -> -1
    }

    /** Strict UTF-8 as Postgres accepts it: no NUL, no overlongs, no surrogates, nothing above U+10FFFF. */
    fun validUtf8(b: ByteArray, off: Int, end: Int): Boolean {
        var i = off
        while (i < end) {
            val c = b[i].toInt() and 0xFF
            if (c == 0) return false
            if (c < 0x80) { i++; continue }
            val n: Int
            val min: Int
            when {
                c in 0xC2..0xDF -> { n = 1; min = 0x80 }
                c in 0xE0..0xEF -> { n = 2; min = 0x800 }
                c in 0xF0..0xF4 -> { n = 3; min = 0x10000 }
                else -> return false
            }
            if (i + n >= end) return false
            var cp = c and (0x3F shr n)
            for (k in 1..n) {
                val x = b[i + k].toInt() and 0xFF
                if (x and 0xC0 != 0x80) return false
                cp = (cp shl 6) or (x and 0x3F)
            }
            if (cp < min || cp > 0x10FFFF || cp in 0xD800..0xDFFF) return false
            i += n + 1
        }
        return true
    }
}
