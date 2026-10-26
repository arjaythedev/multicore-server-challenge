package conduit.json

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

private fun parse(s: String): JsonValue? = JsonReader.parse(s.encodeToByteArray())
private fun parse(b: List<Int>): JsonValue? = JsonReader.parse(ByteArray(b.size) { b[it].toByte() })

/** A compact canonical rendering, to compare whole trees at once. */
private fun show(v: JsonValue?): String = when (v) {
    null -> "ERROR"
    JsonValue.Null -> "null"
    is JsonValue.Bool -> v.value.toString()
    is JsonValue.Num -> "#" + v.text
    is JsonValue.Str -> "'" + v.value + "'"
    is JsonValue.Arr -> v.items.joinToString(",", "[", "]") { show(it) }
    is JsonValue.Obj -> v.members.entries.joinToString(",", "{", "}") { (k, x) -> "'$k':" + show(x) }
}

class JsonReaderTest {
    @Test
    fun scalars() {
        assertSame(JsonValue.Null, parse("null"))
        assertEquals("true", show(parse("true")))
        assertEquals("false", show(parse(" \t\r\nfalse \n")))
        for (n in listOf("0", "-0", "7", "-12", "1.5", "-0.25", "1e9", "1E+9", "2.5e-3", "123456789012345678901234567890"))
            assertEquals("#$n", show(parse(n)))
        assertEquals("''", show(parse("\"\"")))
    }

    @Test
    fun requestBodies() {
        val v = parse("""{"user":{"email":"a@b.c","password":"pw","bio":null,"n":5,"tags":["x","y"],"ok":true}}""")
        assertEquals("{'user':{'email':'a@b.c','password':'pw','bio':null,'n':#5,'tags':['x','y'],'ok':true}}", show(v))
        val user = assertIs<JsonValue.Obj>(assertIs<JsonValue.Obj>(v)["user"])
        assertEquals("a@b.c", assertIs<JsonValue.Str>(user["email"]).value)
        assertNull(user["missing"])
        assertEquals("{}", show(parse("{}")))
        assertEquals("[]", show(parse(" [ ] ")))
        assertEquals("[{},[[]],#1]", show(parse("[ {} , [ [ ] ] , 1 ]")))
    }

    @Test
    fun duplicateKeysLastWinsSourceOrderKept() {
        assertEquals("{'a':#3,'b':#2}", show(parse("""{"a":1,"b":2,"a":3}""")))
        assertEquals("{'z':#1,'a':#2,'m':#3}", show(parse("""{"z":1,"a":2,"m":3}""")))
    }

    @Test
    fun stringEscapesAndUnicode() {
        assertEquals("'\"\\/\b\u000C\n\r\t'", show(parse("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"")))
        assertEquals("'<b>&</b>'", show(parse("\"\\u003cb\\u003e\\u0026\\u003c/b\\u003e\"")))
        assertEquals("'é中\u0000'", show(parse("\"\\u00e9\\u4E2D\\u0000\"")))
        assertEquals("'🙂'", show(parse("\"\\ud83d\\ude42\"")))
        assertEquals("'x🙂y'", show(parse("\"x\\uD83D\\uDE42y\"")))
        // raw UTF-8: 2, 3 and 4 byte sequences, and the escape/raw mix
        assertEquals("'ünïcode 中 🙂 \"q\"'", show(parse("\"ünïcode 中 🙂 \\\"q\\\"\"")))
        assertEquals("'Conformance comment <b>&</b> \"quoted\" ünïcode'",
            show(parse("\"Conformance comment \\u003cb\\u003e\\u0026\\u003c/b\\u003e \\\"quoted\\\" ünïcode\"")))
        assertEquals("'\u007f'", show(parse("\"\u007f\"")))
        // edges of the valid UTF-8 ranges
        assertTrue(parse(listOf(0x22, 0xC2, 0x80, 0x22)) is JsonValue.Str)
        assertTrue(parse(listOf(0x22, 0xDF, 0xBF, 0x22)) is JsonValue.Str)
        assertTrue(parse(listOf(0x22, 0xE0, 0xA0, 0x80, 0x22)) is JsonValue.Str)
        assertTrue(parse(listOf(0x22, 0xED, 0x9F, 0xBF, 0x22)) is JsonValue.Str) // U+D7FF
        assertTrue(parse(listOf(0x22, 0xEE, 0x80, 0x80, 0x22)) is JsonValue.Str) // U+E000
        assertTrue(parse(listOf(0x22, 0xF0, 0x90, 0x80, 0x80, 0x22)) is JsonValue.Str)
        assertTrue(parse(listOf(0x22, 0xF4, 0x8F, 0xBF, 0xBF, 0x22)) is JsonValue.Str) // U+10FFFF
        assertEquals("\uDBFF\uDFFF", (parse(listOf(0x22, 0xF4, 0x8F, 0xBF, 0xBF, 0x22)) as JsonValue.Str).value)
    }

    @Test
    fun invalidSyntax() {
        val bad = listOf(
            "", " ", "nul", "nulls", "truex", "True", "NaN", "Infinity", "-", "+1", "01", "-01", "1.", ".1", "1e",
            "1e+", "0x10", "1 2", "[1,]", "[,1]", "[1 2]", "[", "]", "{", "}", "{\"a\"}", "{\"a\":}", "{\"a\":1,}",
            "{,}", "{a:1}", "{'a':1}", "{\"a\" 1}", "{\"a\":1 \"b\":2}", "{1:2}", "[1]]", "{}}", "{} x", "\"abc",
            "\"\\\"", "\"\\x\"", "\"\\u12\"", "\"\\u12g4\"", "\"\\U0041\"", "\"\\ud800\"", "\"\\udc00\"",
            "\"\\ud800\\u0041\"", "\"\\ud800x\"", "\"\\ude42\\ud83d\"", "\"tab\there\"", "\"nl\nhere\"",
            "\u00a0[]", "[]\u000b", "/*c*/1",
        )
        for (s in bad) assertNull(parse(s), "should reject: $s")
    }

    @Test
    fun invalidUtf8() {
        val bad = listOf(
            listOf(0x22, 0xFF, 0x22), // never valid
            listOf(0x22, 0x80, 0x22), // lone continuation
            listOf(0x22, 0xC0, 0x80, 0x22), // overlong NUL
            listOf(0x22, 0xC1, 0xBF, 0x22), // overlong
            listOf(0x22, 0xE0, 0x80, 0x80, 0x22), // overlong 3-byte
            listOf(0x22, 0xED, 0xA0, 0x80, 0x22), // UTF-16 surrogate D800
            listOf(0x22, 0xF0, 0x80, 0x80, 0x80, 0x22), // overlong 4-byte
            listOf(0x22, 0xF4, 0x90, 0x80, 0x80, 0x22), // > U+10FFFF
            listOf(0x22, 0xF5, 0x80, 0x80, 0x80, 0x22),
            listOf(0x22, 0xC3, 0x22), // truncated
            listOf(0x22, 0xE4, 0xB8, 0x22), // truncated
            listOf(0x22, 0xC3), // truncated at end of input
            listOf(0xEF, 0xBB, 0xBF, 0x7B, 0x7D), // BOM + {}
            listOf(0x5B, 0xC3, 0xA9, 0x5D), // non-ASCII outside a string
        )
        for (b in bad) assertNull(parse(b), "should reject: $b")
    }

    @Test
    fun depthLimit() {
        assertNotNull(parse("[".repeat(64) + "]".repeat(64)))
        assertNull(parse("[".repeat(65) + "]".repeat(65)))
        assertNotNull(parse("{\"a\":".repeat(63) + "[]" + "}".repeat(63)))
        assertNull(parse("{\"a\":".repeat(64) + "[]" + "}".repeat(64)))
        assertNull(parse("[".repeat(100_000))) // no stack overflow, no exception
    }

    @Test
    fun subrange() {
        val b = "xx{\"a\":[1]}yy".encodeToByteArray()
        assertEquals("{'a':[#1]}", show(JsonReader.parse(b, 2, b.size - 4)))
        assertNull(JsonReader.parse(b, 2, b.size - 3))
        assertNull(JsonReader.parse(b, 2, 3)) // cut inside the object
        assertNull(JsonReader.parse(b, -1, 3))
        assertNull(JsonReader.parse(b, 2, 100))
    }
}
