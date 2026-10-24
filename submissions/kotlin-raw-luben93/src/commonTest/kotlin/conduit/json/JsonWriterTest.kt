package conduit.json

import conduit.pg.Row
import conduit.util.ByteBuf
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

private val A = JsonName("a")
private val B = JsonName("b")
private val C = JsonName("c")

/** Runs [block] on a writer over a tiny buffer (so every growth path is exercised) and returns the JSON text. */
private fun json(block: JsonWriter.() -> Unit): String {
    val buf = ByteBuf(1)
    JsonWriter(buf).block()
    return buf.toByteArray().decodeToString()
}

/** A DataRow body with the given column values (null = SQL NULL), parsed into a [Row]. */
internal fun rowOf(vararg cols: ByteArray?): Row {
    val b = ByteBuf()
    b.putShortBE(cols.size)
    for (c in cols) {
        if (c == null) b.putIntBE(-1) else { b.putIntBE(c.size); b.put(c) }
    }
    return Row().also { it.parse(b.toByteArray(), 0) }
}

/** Postgres's binary text[]: 1-D, lower bound 1 (null elements allowed); `null` list -> ndim 0 (empty array). */
internal fun textArrayBytes(items: List<String?>?): ByteArray {
    val b = ByteBuf()
    if (items == null) {
        b.putIntBE(0); b.putIntBE(0); b.putIntBE(25)
        return b.toByteArray()
    }
    b.putIntBE(1); b.putIntBE(if (items.any { it == null }) 1 else 0); b.putIntBE(25)
    b.putIntBE(items.size); b.putIntBE(1)
    for (s in items) {
        if (s == null) b.putIntBE(-1) else s.encodeToByteArray().let { b.putIntBE(it.size); b.put(it) }
    }
    return b.toByteArray()
}

class JsonWriterTest {
    @Test
    fun nestingAndCommas() {
        assertEquals("{}", json { beginObject(); endObject() })
        assertEquals("[]", json { beginArray(); endArray() })
        assertEquals(
            """{"a":1,"b":[1,"x",{"c":null},[],{}],"c":{"a":true,"b":false}}""",
            json {
                beginObject()
                name(A); number(1)
                name(B); beginArray()
                number(1); string("x"); beginObject(); name(C); nul(); endObject(); beginArray(); endArray()
                beginObject(); endObject()
                endArray()
                name(C); beginObject(); name(A); bool(true); name(B); bool(false); endObject()
                endObject()
            },
        )
        assertEquals("""[{"a":1},{"a":2}]""", json {
            beginArray()
            for (i in 1..2) { beginObject(); name(A); number(i.toLong()); endObject() }
            endArray()
        })
    }

    @Test
    fun deepNestingGrowsState() {
        val s = json {
            repeat(100) { beginArray() }
            number(7)
            repeat(100) { endArray() }
        }
        assertEquals("[".repeat(100) + "7" + "]".repeat(100), s)
    }

    @Test
    fun resetClearsState() {
        val buf = ByteBuf()
        val w = JsonWriter(buf)
        w.beginObject(); w.name(A); w.beginArray(); w.number(1) // abandoned mid-way (an error response)
        buf.reset(); w.reset()
        w.beginObject(); w.name(A); w.number(2); w.endObject()
        assertEquals("""{"a":2}""", buf.toByteArray().decodeToString())
    }

    @Test
    fun escaping() {
        val raw = "q\"b\\s/n\nr\rt\tu\u0001\u001f del\u007f é ü 中 🙂 <&>"
        val want = "\"q\\\"b\\\\s/n\\nr\\rt\\tu\\u0001\\u001f del\u007f é ü 中 🙂 <&>\""
        assertEquals(want, json { string(raw) })
        assertEquals(want, json { string(raw.encodeToByteArray(), 0, raw.encodeToByteArray().size) })
        // every control character
        for (c in 0 until 0x20) {
            val e = when (c) {
                0x0A -> "\\n"
                0x0D -> "\\r"
                0x09 -> "\\t"
                else -> "\\u00" + "0123456789abcdef"[c shr 4] + "0123456789abcdef"[c and 15]
            }
            assertEquals("\"x${e}y\"", json { string("x${c.toChar()}y") })
            assertEquals("\"x${e}y\"", json { string(byteArrayOf('x'.code.toByte(), c.toByte(), 'y'.code.toByte()), 0, 3) })
        }
        assertEquals("\"\"", json { string("") })
        assertEquals("null", json { string(null) })
    }

    @Test
    fun manyEscapesInLongStrings() {
        val raw = "\u0001\"\n".repeat(500) + "é".repeat(300)
        val want = "\"" + "\\u0001\\\"\\n".repeat(500) + "é".repeat(300) + "\""
        assertEquals(want, json { string(raw) })
        val bytes = raw.encodeToByteArray()
        assertEquals(want, json { string(bytes, 0, bytes.size) })
    }

    @Test
    fun byteSubrangeAndNonAsciiPassthrough() {
        val b = "xx\"é\u0000yy".encodeToByteArray()
        assertEquals("\"\\\"é\\u0000\"", json { string(b, 2, b.size - 4) })
        // invalid UTF-8 from the database is impossible, but bytes are copied verbatim anyway
        val buf = ByteBuf()
        JsonWriter(buf).string(byteArrayOf(0xff.toByte(), 0x80.toByte()), 0, 2)
        assertEquals(listOf(0x22, 0xff, 0x80, 0x22), buf.toByteArray().map { it.toInt() and 0xff })
    }

    @Test
    fun loneSurrogatesBecomeReplacementChar() {
        assertEquals("\"a�b�\"", json { string("a\uD800b\uDC00") })
        assertEquals("\"🙂\"", json { string("🙂") })
    }

    @Test
    fun numbers() {
        val values = longArrayOf(
            0, 1, -1, 9, 10, -10, 99, 100, 12345, Int.MAX_VALUE.toLong(), Int.MAX_VALUE + 1L, Int.MIN_VALUE.toLong(),
            Int.MIN_VALUE - 1L, 999_999_999_999_999_999L, 1_000_000_000_000_000_000L, Long.MAX_VALUE,
            Long.MIN_VALUE, -Long.MAX_VALUE,
        )
        for (v in values) assertEquals(v.toString(), json { number(v) })
        val r = Random(42)
        repeat(2000) {
            val v = r.nextLong() shr r.nextInt(64)
            assertEquals(v.toString(), json { number(v) })
        }
        assertEquals("[1,-2,3]", json { beginArray(); number(1); number(-2); number(3); endArray() })
    }

    @Test
    fun timestamps() {
        fun ts(micros: Long) = json { timestamp(micros) }
        assertEquals("\"2000-01-01T00:00:00.000Z\"", ts(0))
        assertEquals("\"2000-01-01T00:00:00.000Z\"", ts(999)) // truncated, not rounded
        assertEquals("\"2000-01-01T00:00:00.001Z\"", ts(1000))
        assertEquals("\"2000-01-01T00:00:00.999Z\"", ts(999_999))
        assertEquals("\"1999-12-31T23:59:59.999Z\"", ts(-1)) // floor towards the past
        assertEquals("\"1999-12-31T23:59:59.999Z\"", ts(-1000))
        assertEquals("\"1999-12-31T23:59:59.998Z\"", ts(-1001))
        assertEquals("\"2026-09-01T00:00:00.000Z\"", ts(841_536_000_000_000))
        assertEquals("\"2024-02-29T23:59:59.999Z\"", ts(762_566_399_999_999))
        assertEquals("\"2025-01-15T08:09:10.123Z\"", ts(790_243_750_123_456))
        assertEquals("\"1970-01-01T00:00:00.000Z\"", ts(-946_684_800_000_000))
        assertEquals("\"1900-03-01T12:34:56.789Z\"", ts(-3_150_530_703_210_988))
        assertEquals("\"1600-02-29T01:02:03.004Z\"", ts(-12_617_679_476_995_995))
        assertEquals("\"0001-01-01T00:00:00.000Z\"", ts(-63_082_281_600_000_000))
        assertEquals("\"9999-12-31T23:59:59.999Z\"", ts(252_455_615_999_999_999))
        assertEquals("\"+10000-01-01T00:00:00.000Z\"", ts(252_455_616_000_000_000))
        assertEquals("""{"a":"2000-01-01T00:00:00.000Z","b":1}""", json {
            beginObject(); name(A); timestamp(0); name(B); number(1); endObject()
        })
    }

    @Test
    fun timestampsMatchNaiveCalendar() {
        val r = Random(7)
        repeat(3000) {
            // years 1601..2399
            val micros = r.nextLong(-12_600_000_000_000_000L, 12_600_000_000_000_000L)
            assertEquals("\"" + naive(micros) + "\"", json { timestamp(micros) })
        }
    }

    /** Day-by-year walk from 2000-01-01, the slow obvious way. */
    private fun naive(micros: Long): String {
        var ms = micros.floorDiv(1000L)
        var days = ms.floorDiv(86_400_000L)
        ms -= days * 86_400_000L
        fun leap(y: Int) = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        var y = 2000
        while (days < 0) { y--; days += if (leap(y)) 366 else 365 }
        while (days >= (if (leap(y)) 366 else 365)) { days -= if (leap(y)) 366 else 365; y++ }
        val ml = intArrayOf(31, if (leap(y)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
        var m = 0
        while (days >= ml[m]) { days -= ml[m]; m++ }
        fun p(v: Long, n: Int) = v.toString().padStart(n, '0')
        return "${p(y.toLong(), 4)}-${p(m + 1L, 2)}-${p(days + 1, 2)}T${p(ms / 3_600_000, 2)}:" +
            "${p(ms / 60_000 % 60, 2)}:${p(ms / 1000 % 60, 2)}.${p(ms % 1000, 3)}Z"
    }

    @Test
    fun textColumns() {
        val row = rowOf("plain".encodeToByteArray(), null, "q\"é\n".encodeToByteArray(), ByteArray(0))
        assertEquals("""["plain",null,"q\"é\n",""]""", json {
            beginArray(); for (c in 0 until 4) text(row, c); endArray()
        })
    }

    @Test
    fun textArrays() {
        val row = rowOf(
            textArrayBytes(listOf("dragons", "a\"b", "é🙂", "")),
            textArrayBytes(null),
            null,
            textArrayBytes(listOf("x", null)),
            textArrayBytes(listOf("only")),
        )
        assertEquals(
            """{"a":["dragons","a\"b","é🙂",""],"b":[],"c":[],"a":["x",null],"b":["only"]}""",
            json {
                beginObject()
                name(A); textArray(row, 0)
                name(B); textArray(row, 1)
                name(C); textArray(row, 2)
                name(A); textArray(row, 3)
                name(B); textArray(row, 4)
                endObject()
            },
        )
        assertEquals("""[[],["only"]]""", json { beginArray(); textArray(row, 1); textArray(row, 4); endArray() })
    }

    @Test
    fun textArraysSortedByBytes() {
        val many = (0 until 40).map { "t" + (39 - it).toString().padStart(2, '0') }
        val row = rowOf(
            textArrayBytes(listOf("zz", "dragons", "a\"b", "é", "Z", "", "dragon")),
            textArrayBytes(listOf("x", null, "a")),
            textArrayBytes(listOf("only")),
            textArrayBytes(null),
            textArrayBytes(many),
        )
        assertEquals(
            // unsigned bytes: "" < "Z" < "a\"b" < "dragon" < "dragons" < "zz" < "é" (0xC3)
            """[["","Z","a\"b","dragon","dragons","zz","é"],[null,"a","x"],["only"],[]]""",
            json {
                beginArray()
                textArray(row, 0, sortBytes = true)
                textArray(row, 1, sortBytes = true)
                textArray(row, 2, sortBytes = true)
                textArray(row, 3, sortBytes = true)
                endArray()
            },
        )
        assertEquals(
            many.sorted().joinToString(",", "[", "]") { "\"$it\"" },
            json { textArray(row, 4, sortBytes = true) },
        )
    }

    @Test
    fun twoDimensionalTextArrayIsFlattened() {
        val b = ByteBuf()
        b.putIntBE(2); b.putIntBE(0); b.putIntBE(25)
        b.putIntBE(2); b.putIntBE(1); b.putIntBE(2); b.putIntBE(1)
        for (s in listOf("a", "b", "c", "d")) { b.putIntBE(1); b.put(s.encodeToByteArray()) }
        val row = rowOf(b.toByteArray())
        assertEquals("""["a","b","c","d"]""", json { textArray(row, 0) })
    }

    /** The 8-bytes-per-step scan must find every byte that needs an escape, at every offset of a long run. */
    @Test
    fun longRunsEscapeLikeTheByteLoop() {
        val hex = "0123456789abcdef"
        fun reference(bytes: ByteArray): String {
            val sb = StringBuilder("\"")
            for (x in bytes) {
                val c = x.toInt() and 0xFF
                when {
                    c == '"'.code -> sb.append("\\\"")
                    c == '\\'.code -> sb.append("\\\\")
                    c == '\n'.code -> sb.append("\\n")
                    c == '\r'.code -> sb.append("\\r")
                    c == '\t'.code -> sb.append("\\t")
                    c < 0x20 -> sb.append("\\u00").append(hex[c shr 4]).append(hex[c and 15])
                    else -> sb.append(c.toChar())
                }
            }
            return sb.append('"').toString()
        }
        fun latin(b: ByteArray) = b.joinToString("") { (it.toInt() and 0xFF).toChar().toString() }
        // every byte value at every position of a 24-byte run of plain text, with the run at offsets 0..8
        for (v in 0 until 256) {
            for (pos in 0 until 24) {
                for (off in 0..8) {
                    val bytes = ByteArray(24) { ('a'.code + it % 26).toByte() }
                    bytes[pos] = v.toByte()
                    val src = ByteArray(off) + bytes + ByteArray(5)
                    val out = ByteBuf(1)
                    JsonWriter(out).string(src, off, bytes.size)
                    assertEquals(reference(bytes), latin(out.toByteArray()), "byte $v at $pos, offset $off")
                }
            }
        }
        // random mixes of plain ASCII, UTF-8 high bytes and escapes
        val r = Random(99)
        val alphabet = byteArrayOf(
            'a'.code.toByte(), 'Z'.code.toByte(), ' '.code.toByte(), '"'.code.toByte(), '\\'.code.toByte(), 0, 1,
            0x1F, 0x7F, 0x80.toByte(), 0xC3.toByte(), 0xFF.toByte(), '\n'.code.toByte(),
        )
        repeat(2000) {
            val n = r.nextInt(0, 100)
            val bytes = ByteArray(n) { if (r.nextInt(10) < 7) 'x'.code.toByte() else alphabet[r.nextInt(alphabet.size)] }
            val out = ByteBuf(1)
            JsonWriter(out).string(bytes, 0, n)
            assertEquals(reference(bytes), latin(out.toByteArray()))
        }
    }
}
