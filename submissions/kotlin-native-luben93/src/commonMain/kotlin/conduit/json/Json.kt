package conduit.json

import kotlin.jvm.JvmField
import conduit.pg.Row
import conduit.platform.loadLongLE
import conduit.util.ByteBuf
import conduit.util.intBE

/** A pre-encoded object key: the bytes of `"name":`. Create once (top-level vals), reuse forever. */
class JsonName(name: String) {
    @JvmField val bytes: ByteArray = "\"$name\":".encodeToByteArray()
}

/**
 * Streaming JSON writer straight into a [ByteBuf] (no intermediate objects, no Strings on hot paths). Handles commas
 * itself: call [name] then exactly one value inside objects; values in arrays are separated automatically.
 * String escaping: `"` `\` and control characters < 0x20 (\n \r \t as short escapes, others \u00XX); all other bytes,
 * including non-ASCII UTF-8, are copied unchanged.
 */
class JsonWriter(@JvmField val out: ByteBuf) {
    /** Per nesting level: [EMPTY] (nothing written yet), [MORE] (a value was written), [KEYED] (after a name). */
    private var state = ByteArray(16)
    private var depth = 0

    /** Clears the nesting state (call when [out] is reset). */
    fun reset() {
        depth = 0
        state[0] = EMPTY
    }

    /** Before a value: a comma unless it is the first one in its container or follows a name. */
    private fun sep() {
        val d = depth
        when (state[d]) {
            EMPTY, KEYED -> state[d] = MORE
            else -> out.put(','.code)
        }
    }

    private fun open(c: Char) {
        sep()
        out.put(c.code)
        val d = depth + 1
        if (d == state.size) state = state.copyOf(d * 2)
        state[d] = EMPTY
        depth = d
    }

    fun beginObject() = open('{')

    fun endObject() {
        depth--
        out.put('}'.code)
    }

    fun beginArray() = open('[')

    fun endArray() {
        depth--
        out.put(']'.code)
    }

    /** Writes the key (with a leading comma when needed). */
    fun name(n: JsonName) {
        val d = depth
        val b = n.bytes
        val o = out
        o.ensure(b.size + 1)
        if (state[d] != EMPTY) o.buf[o.len++] = ','.code.toByte()
        b.copyInto(o.buf, o.len)
        o.len += b.size
        state[d] = KEYED
    }

    /** A JSON string from a Kotlin string; null writes `null`. */
    fun string(s: String?) {
        if (s == null) return nul()
        sep()
        val n = s.length
        val o = out
        o.ensure(n * 3 + 2) // 3 bytes per char covers UTF-8 (a surrogate pair is 4 bytes for 2 chars)
        var b = o.buf
        var p = o.len
        b[p++] = QUOTE
        var i = 0
        while (i < n) {
            val c = s[i].code
            if (c < 0x80) {
                if (ESC[c].toInt() == 0) {
                    b[p++] = c.toByte()
                } else {
                    o.len = p
                    o.ensure((n - i) * 3 + 8) // an escape takes up to 6 bytes for 1 char
                    b = o.buf
                    p = putEscape(b, p, c)
                }
            } else if (c < 0x800) {
                b[p++] = (0xC0 or (c shr 6)).toByte()
                b[p++] = (0x80 or (c and 0x3F)).toByte()
            } else if (c in 0xD800..0xDBFF && i + 1 < n && s[i + 1].code in 0xDC00..0xDFFF) {
                val cp = 0x10000 + ((c - 0xD800) shl 10) + (s[++i].code - 0xDC00)
                b[p++] = (0xF0 or (cp shr 18)).toByte()
                b[p++] = (0x80 or ((cp shr 12) and 0x3F)).toByte()
                b[p++] = (0x80 or ((cp shr 6) and 0x3F)).toByte()
                b[p++] = (0x80 or (cp and 0x3F)).toByte()
            } else if (c in 0xD800..0xDFFF) { // lone surrogate: U+FFFD, as encodeToByteArray does
                b[p++] = 0xEF.toByte(); b[p++] = 0xBF.toByte(); b[p++] = 0xBD.toByte()
            } else {
                b[p++] = (0xE0 or (c shr 12)).toByte()
                b[p++] = (0x80 or ((c shr 6) and 0x3F)).toByte()
                b[p++] = (0x80 or (c and 0x3F)).toByte()
            }
            i++
        }
        b[p++] = QUOTE
        o.len = p
    }

    /** A JSON string from UTF-8 bytes (escaped as needed). */
    fun string(b: ByteArray, off: Int, len: Int) {
        sep()
        quoted(b, off, len)
    }

    /** `"` + escaped bytes + `"`: runs of plain bytes are block-copied. */
    private fun quoted(src: ByteArray, off: Int, len: Int) {
        val o = out
        o.ensure(len + 2)
        o.buf[o.len++] = QUOTE
        val end = off + len
        var i = off
        while (true) {
            val start = i
            // 16, then 8 bytes per step while none of them needs an escape (the byte loop then finds the exact one)
            while (i + 16 <= end && (escapes(loadLongLE(src, i)) or escapes(loadLongLE(src, i + 8))) == 0L) i += 16
            while (i + 8 <= end && escapes(loadLongLE(src, i)) == 0L) i += 8
            while (i < end && ESC[src[i].toInt() and 0xFF].toInt() == 0) i++
            val run = i - start
            if (run > 0) {
                src.copyInto(o.buf, o.len, start, i)
                o.len += run
            }
            if (i == end) break
            o.ensure(end - i + 7) // the escape (<= 6 bytes) plus the rest unescaped plus the quote
            o.len = putEscape(o.buf, o.len, src[i].toInt())
            i++
        }
        o.buf[o.len++] = QUOTE
    }

    /** A text column as a JSON string, or `null` when the column is NULL. */
    fun text(row: Row, col: Int) {
        val l = row.len[col]
        if (l < 0) return nul()
        sep()
        quoted(row.buf, row.off[col], l)
    }

    fun number(v: Long) {
        sep()
        val o = out
        o.ensure(20)
        if (v == Long.MIN_VALUE) {
            o.putAscii("-9223372036854775808")
            return
        }
        val b = o.buf
        var p = o.len
        var x = v
        if (x < 0) {
            b[p++] = '-'.code.toByte()
            x = -x
        }
        var digits = 1
        var t = 10L
        while (digits < 19 && x >= t) { // 10^18 is the largest power of ten in a Long
            digits++
            t *= 10
        }
        p += digits
        o.len = p
        if (x <= Int.MAX_VALUE) { // int division is cheaper
            var y = x.toInt()
            while (y >= 10) {
                val q = y / 10
                b[--p] = ('0'.code + (y - q * 10)).toByte()
                y = q
            }
            b[p - 1] = ('0'.code + y).toByte()
        } else {
            while (x >= 10) {
                val q = x / 10
                b[--p] = ('0'.code + (x - q * 10).toInt()).toByte()
                x = q
            }
            b[p - 1] = ('0'.code + x.toInt()).toByte()
        }
    }

    fun bool(v: Boolean) {
        sep()
        out.put(if (v) TRUE else FALSE)
    }

    fun nul() {
        sep()
        out.put(NULL)
    }

    /**
     * A timestamptz as "YYYY-MM-DDTHH:MM:SS.mmmZ" (UTC, exactly 3 fractional digits, truncated not rounded).
     * [micros] is Postgres's binary value: microseconds since 2000-01-01T00:00:00Z (may be negative).
     */
    fun timestamp(micros: Long) {
        sep()
        val ms = micros.floorDiv(1000L) + 946_684_800_000L // Unix epoch milliseconds
        val days = ms.floorDiv(86_400_000L)
        var rem = (ms - days * 86_400_000L).toInt() // ms of day, 0 until 86_400_000
        // civil_from_days (Howard Hinnant): proleptic Gregorian date of a day count since 1970-01-01
        val z = days + 719_468
        val era = (if (z >= 0) z else z - 146_096) / 146_097
        val doe = (z - era * 146_097).toInt() // [0, 146096]
        val yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365 // [0, 399]
        val doy = doe - (365 * yoe + yoe / 4 - yoe / 100) // [0, 365]
        val mp = (5 * doy + 2) / 153 // [0, 11], March-based
        val day = doy - (153 * mp + 2) / 5 + 1
        val month = if (mp < 10) mp + 3 else mp - 9
        val year = yoe + era * 400 + (if (month <= 2) 1 else 0)
        val o = out
        o.ensure(26)
        if (year in 0L..9999L) {
            val b = o.buf
            val p = o.len
            val y = year.toInt()
            b[p] = QUOTE
            b[p + 1] = ('0'.code + y / 1000).toByte()
            b[p + 2] = ('0'.code + y / 100 % 10).toByte()
            b[p + 3] = ('0'.code + y / 10 % 10).toByte()
            b[p + 4] = ('0'.code + y % 10).toByte()
            o.len = p + 5
        } else { // beyond 4 digits (never in our data): ISO 8601's expanded form, still valid JSON
            o.put(QUOTE.toInt())
            if (year > 0) o.put('+'.code)
            o.putDecimal(year)
            o.ensure(21)
        }
        val b = o.buf
        val p = o.len - 5 // the fields below are written at the offsets of the 4-digit layout
        b[p + 5] = '-'.code.toByte()
        two(b, p + 6, month)
        b[p + 8] = '-'.code.toByte()
        two(b, p + 9, day)
        b[p + 11] = 'T'.code.toByte()
        val h = rem / 3_600_000
        rem -= h * 3_600_000
        val mi = rem / 60_000
        rem -= mi * 60_000
        val s = rem / 1000
        rem -= s * 1000
        two(b, p + 12, h)
        b[p + 14] = ':'.code.toByte()
        two(b, p + 15, mi)
        b[p + 17] = ':'.code.toByte()
        two(b, p + 18, s)
        b[p + 20] = '.'.code.toByte()
        b[p + 21] = ('0'.code + rem / 100).toByte()
        b[p + 22] = ('0'.code + rem / 10 % 10).toByte()
        b[p + 23] = ('0'.code + rem % 10).toByte()
        b[p + 24] = 'Z'.code.toByte()
        b[p + 25] = QUOTE
        o.len = p + 26
    }

    /**
     * A binary text[] column as a JSON array of strings, in array order (NULL column or empty array -> `[]`).
     * Binary array format: Int32 ndim (0 = empty), Int32 has-null flag, Int32 element OID, ndim x (Int32 size,
     * Int32 lower bound), then per element Int32 length (-1 = NULL element, written as `null`) + UTF-8 bytes.
     * Multi-dimensional arrays are flattened. [sortBytes]: in ascending unsigned-byte order instead (the app sorts tag
     * lists itself when the database collation is byte order; NULL elements first).
     */
    fun textArray(row: Row, col: Int, sortBytes: Boolean = false) {
        sep()
        val o = out
        o.put('['.code)
        val l = row.len[col]
        if (l >= 12) {
            val b = row.buf
            var p = row.off[col]
            val ndim = b.intBE(p)
            p += 12
            var count = if (ndim > 0) 1 else 0
            for (d in 0 until ndim) {
                count *= b.intBE(p)
                p += 8
            }
            if (sortBytes && count > 1) return sortedElements(b, p, count)
            for (e in 0 until count) {
                if (e > 0) o.put(','.code)
                val n = b.intBE(p)
                p += 4
                if (n < 0) {
                    o.put(NULL)
                } else {
                    quoted(b, p, n)
                    p += n
                }
            }
        }
        o.put(']'.code)
    }

    // (offset, length) of each element for [sortedElements]; grown on demand, kept per writer
    private var elemOff = IntArray(16)
    private var elemLen = IntArray(16)

    /** The [count] elements starting at [p] (after the array header), insertion-sorted by bytes, then `]`. */
    private fun sortedElements(b: ByteArray, start: Int, count: Int) {
        if (count > elemOff.size) {
            elemOff = IntArray(count)
            elemLen = IntArray(count)
        }
        val offs = elemOff
        val lens = elemLen
        var p = start
        for (e in 0 until count) {
            val n = b.intBE(p)
            p += 4
            // insertion sort: tag lists are short (1-4 per seed article)
            var j = e
            while (j > 0 && compareBytes(b, p, n, offs[j - 1], lens[j - 1]) < 0) {
                offs[j] = offs[j - 1]
                lens[j] = lens[j - 1]
                j--
            }
            offs[j] = p
            lens[j] = n
            if (n > 0) p += n
        }
        val o = out
        for (e in 0 until count) {
            if (e > 0) o.put(','.code)
            if (lens[e] < 0) o.put(NULL) else quoted(b, offs[e], lens[e])
        }
        o.put(']'.code)
    }

    /** Unsigned lexicographic comparison of two byte ranges of [b]; a length of -1 (NULL) sorts first. */
    private fun compareBytes(b: ByteArray, p1: Int, n1: Int, p2: Int, n2: Int): Int {
        if (n1 < 0 || n2 < 0) return n1.coerceAtMost(0) - n2.coerceAtMost(0)
        val n = minOf(n1, n2)
        for (i in 0 until n) {
            val d = (b[p1 + i].toInt() and 0xFF) - (b[p2 + i].toInt() and 0xFF)
            if (d != 0) return d
        }
        return n1 - n2
    }

    private companion object {
        const val EMPTY: Byte = 0
        const val MORE: Byte = 1
        const val KEYED: Byte = 2
        const val QUOTE = '"'.code.toByte()

        val TRUE = "true".encodeToByteArray()
        val FALSE = "false".encodeToByteArray()
        val NULL = "null".encodeToByteArray()
        val HEX = "0123456789abcdef".encodeToByteArray()

        /** Per byte: 0 = copy as is; otherwise the short escape letter, or 'u' for \u00XX. */
        val ESC = ByteArray(256).also { t ->
            for (c in 0 until 0x20) t[c] = 'u'.code.toByte()
            t['\n'.code] = 'n'.code.toByte()
            t['\r'.code] = 'r'.code.toByte()
            t['\t'.code] = 't'.code.toByte()
            t['"'.code] = '"'.code.toByte()
            t['\\'.code] = '\\'.code.toByte()
        }

        private const val ONES = 0x0101010101010101L
        private const val HIGHS = -0x7f7f7f7f7f7f7f80L // 0x8080808080808080

        /**
         * Nonzero iff any of the 8 bytes packed in [x] needs an escape: < 0x20, '"' or '\' (SWAR: a byte b < n sets the
         * high bit of (b - n) & ~b; the borrow chain can only flag bytes above an already flagged one, so the
         * answer is exact). Bytes >= 0x80 (UTF-8) never do.
         */
        fun escapes(x: Long): Long {
            val ctl = (x - 0x20 * ONES) and x.inv()
            val q = x xor (0x22 * ONES)
            val bs = x xor (0x5C * ONES)
            return (ctl or ((q - ONES) and q.inv()) or ((bs - ONES) and bs.inv())) and HIGHS
        }

        /** Writes the escape for byte [c] (which needs one) at b[p]; returns the new position. */
        fun putEscape(b: ByteArray, p: Int, c: Int): Int {
            val e = ESC[c and 0xFF]
            b[p] = '\\'.code.toByte()
            if (e != 'u'.code.toByte()) {
                b[p + 1] = e
                return p + 2
            }
            b[p + 1] = 'u'.code.toByte()
            b[p + 2] = '0'.code.toByte()
            b[p + 3] = '0'.code.toByte()
            b[p + 4] = HEX[(c shr 4) and 0xF]
            b[p + 5] = HEX[c and 0xF]
            return p + 6
        }

        fun two(b: ByteArray, p: Int, v: Int) {
            b[p] = ('0'.code + v / 10).toByte()
            b[p + 1] = ('0'.code + v % 10).toByte()
        }
    }
}

/** Parsed request-body JSON (request bodies only: writes are ~5% of traffic, allocation is fine there). */
sealed class JsonValue {
    object Null : JsonValue()
    class Bool(val value: Boolean) : JsonValue()
    /** The number's source text (validated JSON number syntax). */
    class Num(val text: String) : JsonValue()
    class Str(val value: String) : JsonValue()
    class Arr(val items: List<JsonValue>) : JsonValue()
    /** Members in source order; on duplicate keys the last one wins. */
    class Obj(val members: Map<String, JsonValue>) : JsonValue() {
        operator fun get(key: String): JsonValue? = members[key]
    }
}

object JsonReader {
    /** Deepest nesting of arrays/objects accepted. */
    const val MAX_DEPTH = 64

    /**
     * Parses exactly one JSON value spanning b[off, off+len) (surrounding whitespace allowed; trailing garbage,
     * invalid UTF-8, bad escapes, unpaired surrogates, nesting deeper than 64 -> null). Never throws.
     */
    fun parse(b: ByteArray, off: Int = 0, len: Int = b.size): JsonValue? {
        if (off < 0 || len < 0 || off + len > b.size) return null
        return try {
            val p = Parser(b, off, off + len)
            p.ws()
            val v = p.value(0) ?: return null
            p.ws()
            if (p.pos != p.end) null else v
        } catch (_: Exception) {
            null // defensive only: the parser checks bounds itself
        }
    }

    /** Recursive descent; every method returns null (Kotlin null, not [JsonValue.Null]) on a syntax error. */
    private class Parser(val b: ByteArray, var pos: Int, val end: Int) {
        fun ws() {
            while (pos < end) {
                val c = b[pos].toInt()
                if (c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09) pos++ else return
            }
        }

        fun value(depth: Int): JsonValue? {
            if (pos >= end) return null
            return when (b[pos].toInt().toChar()) {
                '{' -> obj(depth + 1)
                '[' -> arr(depth + 1)
                '"' -> string()?.let { JsonValue.Str(it) }
                't' -> literal("true", JsonValue.Bool(true))
                'f' -> literal("false", JsonValue.Bool(false))
                'n' -> literal("null", JsonValue.Null)
                else -> number()
            }
        }

        private fun literal(word: String, v: JsonValue): JsonValue? {
            if (end - pos < word.length) return null
            for (i in word.indices) if (b[pos + i].toInt() != word[i].code) return null
            pos += word.length
            return v
        }

        private fun obj(depth: Int): JsonValue? {
            if (depth > MAX_DEPTH) return null
            pos++ // '{'
            val m = LinkedHashMap<String, JsonValue>()
            ws()
            if (pos < end && b[pos].toInt() == '}'.code) {
                pos++
                return JsonValue.Obj(m)
            }
            while (true) {
                ws()
                if (pos >= end || b[pos].toInt() != '"'.code) return null
                val k = string() ?: return null
                ws()
                if (pos >= end || b[pos].toInt() != ':'.code) return null
                pos++
                ws()
                m[k] = value(depth) ?: return null
                ws()
                if (pos >= end) return null
                when (b[pos++].toInt()) {
                    ','.code -> continue
                    '}'.code -> return JsonValue.Obj(m)
                    else -> return null
                }
            }
        }

        private fun arr(depth: Int): JsonValue? {
            if (depth > MAX_DEPTH) return null
            pos++ // '['
            val items = ArrayList<JsonValue>()
            ws()
            if (pos < end && b[pos].toInt() == ']'.code) {
                pos++
                return JsonValue.Arr(items)
            }
            while (true) {
                ws()
                items.add(value(depth) ?: return null)
                ws()
                if (pos >= end) return null
                when (b[pos++].toInt()) {
                    ','.code -> continue
                    ']'.code -> return JsonValue.Arr(items)
                    else -> return null
                }
            }
        }

        /** -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)? */
        private fun number(): JsonValue? {
            val start = pos
            if (pos < end && b[pos].toInt() == '-'.code) pos++
            if (pos >= end) return null
            if (b[pos].toInt() == '0'.code) {
                pos++
            } else if (!digits()) {
                return null
            }
            if (pos < end && b[pos].toInt() == '.'.code) {
                pos++
                if (!digits()) return null
            }
            if (pos < end && (b[pos].toInt() == 'e'.code || b[pos].toInt() == 'E'.code)) {
                pos++
                if (pos < end && (b[pos].toInt() == '+'.code || b[pos].toInt() == '-'.code)) pos++
                if (!digits()) return null
            }
            return JsonValue.Num(b.decodeToString(start, pos))
        }

        /** One or more ASCII digits. */
        private fun digits(): Boolean {
            val start = pos
            while (pos < end && b[pos] >= '0'.code.toByte() && b[pos] <= '9'.code.toByte()) pos++
            return pos > start
        }

        /** A string starting at the opening quote; validates UTF-8 and escapes. */
        fun string(): String? {
            pos++ // '"'
            var sb: StringBuilder? = null
            var seg = pos // start of the pending raw (unescaped) segment
            while (true) {
                if (pos >= end) return null
                val c = b[pos].toInt() and 0xFF
                when {
                    c == '"'.code -> {
                        val s = b.decodeToString(seg, pos)
                        pos++
                        return if (sb == null) s else sb.append(s).toString()
                    }
                    c == '\\'.code -> {
                        val sbb = sb ?: StringBuilder().also { sb = it }
                        sbb.append(b.decodeToString(seg, pos))
                        pos++
                        if (!escape(sbb)) return null
                        seg = pos
                    }
                    c < 0x20 -> return null
                    c < 0x80 -> pos++
                    else -> if (!utf8(c)) return null
                }
            }
        }

        /** After a backslash: appends the escaped character(s). */
        private fun escape(sb: StringBuilder): Boolean {
            if (pos >= end) return false
            when (b[pos++].toInt().toChar()) {
                '"' -> sb.append('"')
                '\\' -> sb.append('\\')
                '/' -> sb.append('/')
                'b' -> sb.append('\b')
                'f' -> sb.append('\u000C')
                'n' -> sb.append('\n')
                'r' -> sb.append('\r')
                't' -> sb.append('\t')
                'u' -> {
                    val u = hex4()
                    if (u < 0) return false
                    if (u in 0xD800..0xDBFF) { // must be followed by \u of a low surrogate
                        if (end - pos < 6 || b[pos].toInt() != '\\'.code || b[pos + 1].toInt() != 'u'.code) return false
                        pos += 2
                        val lo = hex4()
                        if (lo !in 0xDC00..0xDFFF) return false
                        sb.append(u.toChar()).append(lo.toChar())
                    } else if (u in 0xDC00..0xDFFF) {
                        return false
                    } else {
                        sb.append(u.toChar())
                    }
                }
                else -> return false
            }
            return true
        }

        private fun hex4(): Int {
            if (end - pos < 4) return -1
            var v = 0
            for (i in 0 until 4) {
                val c = b[pos + i].toInt()
                val d = when (c) {
                    in '0'.code..'9'.code -> c - '0'.code
                    in 'a'.code..'f'.code -> c - 'a'.code + 10
                    in 'A'.code..'F'.code -> c - 'A'.code + 10
                    else -> return -1
                }
                v = (v shl 4) or d
            }
            pos += 4
            return v
        }

        /** Validates one multi-byte UTF-8 sequence starting with lead byte [c] (no overlongs, surrogates, > U+10FFFF). */
        private fun utf8(c: Int): Boolean {
            val n: Int
            var lo = 0x80
            var hi = 0xBF
            when {
                c in 0xC2..0xDF -> n = 1
                c == 0xE0 -> { n = 2; lo = 0xA0 }
                c in 0xE1..0xEC || c == 0xEE || c == 0xEF -> n = 2
                c == 0xED -> { n = 2; hi = 0x9F }
                c == 0xF0 -> { n = 3; lo = 0x90 }
                c in 0xF1..0xF3 -> n = 3
                c == 0xF4 -> { n = 3; hi = 0x8F }
                else -> return false
            }
            if (end - pos <= n) return false
            val c1 = b[pos + 1].toInt() and 0xFF
            if (c1 < lo || c1 > hi) return false
            for (i in 2..n) {
                val ci = b[pos + i].toInt() and 0xFF
                if (ci < 0x80 || ci > 0xBF) return false
            }
            pos += n + 1
            return true
        }
    }
}
