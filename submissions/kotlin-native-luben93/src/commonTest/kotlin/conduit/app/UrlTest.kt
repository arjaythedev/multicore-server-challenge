package conduit.app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

class UrlTest {
    @Test
    fun plainIsUnchanged() {
        val s = "headru-tut-5000"
        assertSame(s, Url.decode(s))
        assertEquals("tut", Url.decode(s, 7, 10))
        assertEquals("", Url.decode(s, 3, 3))
        assertEquals("a+b", Url.decode("a+b"))
    }

    @Test
    fun escapes() {
        assertEquals("a b", Url.decode("a%20b"))
        assertEquals("a b", Url.decode("a+b", plus = true))
        assertEquals("a+b", Url.decode("a%2Bb", plus = true))
        assertEquals("a/b", Url.decode("a%2fb"))
        assertEquals("+5", Url.decode("%2B5", plus = true))
        assertEquals(" 5", Url.decode("%205", plus = true))
        assertEquals("ü", Url.decode("%C3%BC"))
        assertEquals("😀", Url.decode("%F0%9F%98%80"))
        assertEquals("xüy", Url.decode("xü%79")) // raw non-ASCII next to an escape
        assertEquals("100%", Url.decode("100%25"))
    }

    @Test
    fun rejectsMalformedEscapes() {
        assertNull(Url.decode("%"))
        assertNull(Url.decode("a%2"))
        assertNull(Url.decode("%zz"))
        assertNull(Url.decode("%g0"))
        assertNull(Url.decode("ab%", 0, 3))
    }

    @Test
    fun rejectsWhatPostgresTextRejects() {
        assertNull(Url.decode("a%00b"))
        assertNull(Url.decode("a\u0000b"))
        assertNull(Url.decode("%FF"))
        assertNull(Url.decode("%C3"))          // truncated sequence
        assertNull(Url.decode("%C0%AF"))       // overlong '/'
        assertNull(Url.decode("%E0%80%AF"))    // overlong
        assertNull(Url.decode("%ED%A0%80"))    // UTF-16 surrogate
        assertNull(Url.decode("%F4%90%80%80")) // above U+10FFFF
        assertNull(Url.decode("%80"))          // continuation byte first
        // query values report unrepresentable text separately from malformed escapes
        assertEquals(Url.INVALID, Url.decode("a%00b", plus = true, invalid = Url.INVALID))
        assertEquals(Url.INVALID, Url.decode("%FF", plus = true, invalid = Url.INVALID))
        assertNull(Url.decode("%zz", plus = true, invalid = Url.INVALID))
        assertEquals("ok", Url.decode("ok", plus = true, invalid = Url.INVALID))
    }

    @Test
    fun utf8Validator() {
        fun ok(vararg b: Int) = Url.validUtf8(ByteArray(b.size) { b[it].toByte() }, 0, b.size)
        assertTrue(ok())
        assertTrue(ok(0x41))
        assertTrue(ok(0xC3, 0xBC))
        assertTrue(ok(0xE2, 0x82, 0xAC))
        assertTrue(ok(0xF0, 0x9F, 0x98, 0x80))
        assertTrue(ok(0xF4, 0x8F, 0xBF, 0xBF))
        assertTrue(ok(0xEF, 0xBF, 0xBD))
        assertFalse(ok(0x00))
        assertFalse(ok(0xE2, 0x82))
        assertFalse(ok(0xC1, 0xBF))
        assertFalse(ok(0xF5, 0x80, 0x80, 0x80))
    }
}
