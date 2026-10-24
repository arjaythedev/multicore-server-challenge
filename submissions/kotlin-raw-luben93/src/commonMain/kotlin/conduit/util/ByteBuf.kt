package conduit.util

import kotlin.jvm.JvmField

/**
 * A growable byte buffer: the write side of everything (HTTP responses, JSON, Postgres messages).
 * Fields are public so hot loops can work on [buf] directly; [len] is the write position.
 */
class ByteBuf(initial: Int = 4096) {
    @JvmField var buf: ByteArray = ByteArray(initial)
    @JvmField var len: Int = 0

    fun reset() {
        len = 0
    }

    /** Makes room for [n] more bytes. */
    fun ensure(n: Int) {
        val need = len + n
        if (need > buf.size) grow(need)
    }

    private fun grow(need: Int) {
        var cap = buf.size * 2
        if (cap < need) cap = need
        buf = buf.copyOf(cap)
    }

    fun put(b: Int) {
        if (len == buf.size) grow(len + 1)
        buf[len++] = b.toByte()
    }

    fun put(src: ByteArray) = put(src, 0, src.size)

    fun put(src: ByteArray, off: Int, n: Int) {
        ensure(n)
        src.copyInto(buf, len, off, off + n)
        len += n
    }

    /** Appends the characters of [s], which must be ASCII (no encoding is done). */
    fun putAscii(s: String) {
        val n = s.length
        ensure(n)
        val b = buf
        var p = len
        for (i in 0 until n) b[p++] = s[i].code.toByte()
        len = p
    }

    /** Appends [s] encoded as UTF-8. */
    fun putUtf8(s: String) {
        ensure(s.length * 3)
        val b = buf
        var p = len
        var i = 0
        val n = s.length
        while (i < n) {
            val c = s[i].code
            when {
                c < 0x80 -> b[p++] = c.toByte()
                c < 0x800 -> {
                    b[p++] = (0xC0 or (c shr 6)).toByte()
                    b[p++] = (0x80 or (c and 0x3F)).toByte()
                }
                c in 0xD800..0xDBFF && i + 1 < n && s[i + 1].code in 0xDC00..0xDFFF -> {
                    val cp = 0x10000 + ((c - 0xD800) shl 10) + (s[i + 1].code - 0xDC00)
                    i++ // 4 bytes from 2 chars: within the 3-bytes-per-char reserve
                    b[p++] = (0xF0 or (cp shr 18)).toByte()
                    b[p++] = (0x80 or ((cp shr 12) and 0x3F)).toByte()
                    b[p++] = (0x80 or ((cp shr 6) and 0x3F)).toByte()
                    b[p++] = (0x80 or (cp and 0x3F)).toByte()
                }
                c in 0xD800..0xDFFF -> { // lone surrogate: U+FFFD
                    b[p++] = 0xEF.toByte(); b[p++] = 0xBF.toByte(); b[p++] = 0xBD.toByte()
                }
                else -> {
                    b[p++] = (0xE0 or (c shr 12)).toByte()
                    b[p++] = (0x80 or ((c shr 6) and 0x3F)).toByte()
                    b[p++] = (0x80 or (c and 0x3F)).toByte()
                }
            }
            i++
        }
        len = p
    }

    /** Appends the decimal digits of [v] (ASCII). */
    fun putDecimal(v: Long) {
        if (v == Long.MIN_VALUE) { putAscii("-9223372036854775808"); return }
        ensure(20)
        var x = v
        if (x < 0) { buf[len++] = '-'.code.toByte(); x = -x }
        if (x == 0L) { buf[len++] = '0'.code.toByte(); return }
        var digits = 0
        var t = x
        while (t > 0) { digits++; t /= 10 }
        var p = len + digits
        len = p
        while (x > 0) {
            buf[--p] = ('0'.code + (x % 10).toInt()).toByte()
            x /= 10
        }
    }

    fun putDecimal(v: Int) = putDecimal(v.toLong())

    // Big-endian integers (Postgres wire format)

    fun putShortBE(v: Int) {
        ensure(2)
        buf[len++] = (v shr 8).toByte()
        buf[len++] = v.toByte()
    }

    fun putIntBE(v: Int) {
        ensure(4)
        setIntBE(len, v)
        len += 4
    }

    fun putLongBE(v: Long) {
        ensure(8)
        putIntBE((v ushr 32).toInt())
        putIntBE(v.toInt())
    }

    /** Overwrites 4 bytes at [pos] (length fields patched after the fact). */
    fun setIntBE(pos: Int, v: Int) {
        val b = buf
        b[pos] = (v shr 24).toByte()
        b[pos + 1] = (v shr 16).toByte()
        b[pos + 2] = (v shr 8).toByte()
        b[pos + 3] = v.toByte()
    }

    fun toByteArray(): ByteArray = buf.copyOf(len)
}

// Big-endian reads from any byte array (Postgres messages are parsed in place)

fun ByteArray.intBE(p: Int): Int =
    ((this[p].toInt() and 0xFF) shl 24) or ((this[p + 1].toInt() and 0xFF) shl 16) or
        ((this[p + 2].toInt() and 0xFF) shl 8) or (this[p + 3].toInt() and 0xFF)

fun ByteArray.shortBE(p: Int): Int = ((this[p].toInt() and 0xFF) shl 8) or (this[p + 1].toInt() and 0xFF)

fun ByteArray.longBE(p: Int): Long = (intBE(p).toLong() shl 32) or (intBE(p + 4).toLong() and 0xFFFFFFFFL)
