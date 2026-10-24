package conduit.app

import conduit.auth.Jwt
import conduit.http.Exchange
import conduit.http.Method
import conduit.json.JsonValue
import conduit.json.JsonWriter
import conduit.util.ByteBuf
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

// Bodies are built as JsonValue trees directly (the parser is tested in the json track).
private fun obj(vararg m: Pair<String, JsonValue>) = JsonValue.Obj(linkedMapOf(*m))
private fun s(v: String) = JsonValue.Str(v)
private fun arr(vararg v: JsonValue) = JsonValue.Arr(v.toList())
private val nul = JsonValue.Null
private fun num(t: String) = JsonValue.Num(t)
private fun user(vararg m: Pair<String, JsonValue>) = obj("user" to obj(*m))
private fun article(vararg m: Pair<String, JsonValue>) = obj("article" to obj(*m))

class BodiesTest {
    @Test
    fun register() {
        val ok = assertNotNull(Bodies.register(user("username" to s("u"), "email" to s("e@x"), "password" to s("p"))))
        assertEquals("u", ok.username); assertEquals("e@x", ok.email); assertEquals("p", ok.password)
        // unknown members at both levels are ignored
        assertNotNull(Bodies.register(obj(
            "user" to obj("username" to s("u"), "email" to s("e"), "password" to s("p"), "bio" to s("b"), "admin" to JsonValue.Bool(true)),
            "extra" to num("1"),
        )))
        for (bad in listOf(
            null, nul, s("x"), arr(), obj(), obj("user" to s("string")), obj("user" to nul),
            user("username" to s("u"), "email" to s("e")),                                   // missing password
            user("username" to s(""), "email" to s("e"), "password" to s("p")),              // empty username
            user("username" to s("u"), "email" to nul, "password" to s("p")),                // null email
            user("username" to num("123"), "email" to s("e"), "password" to s("p")),         // wrong type
            user("username" to s("u"), "email" to s("e"), "password" to s("x".repeat(73))),  // > 72 bytes
            user("username" to s("u\u0000"), "email" to s("e"), "password" to s("p")),       // NUL
        )) assertNull(Bodies.register(bad), "$bad")
        assertNotNull(Bodies.register(user("username" to s("u"), "email" to s("e"), "password" to s("x".repeat(72)))))
        // 72 bytes is the limit in UTF-8, not chars: 36 x "ü" = 72 bytes ok, 37 = 74 bytes not
        assertNotNull(Bodies.register(user("username" to s("u"), "email" to s("e"), "password" to s("ü".repeat(36)))))
        assertNull(Bodies.register(user("username" to s("u"), "email" to s("e"), "password" to s("ü".repeat(37)))))
    }

    @Test
    fun login() {
        assertNotNull(Bodies.login(user("email" to s("e"), "password" to s("p"))))
        assertNull(Bodies.login(user("email" to s("e"))))
        assertNull(Bodies.login(user("email" to s(""), "password" to s("p"))))
        assertNull(Bodies.login(obj("email" to s("e"), "password" to s("p"))))
        // a long password is not a 422 at login (it is a 401 after the lookup)
        assertNotNull(Bodies.login(user("email" to s("e"), "password" to s("x".repeat(100)))))
        // NUL is a 401 at login (no such user), checked by the handler before the lookup
        val withNul = assertNotNull(Bodies.login(user("email" to s("e\u0000"), "password" to s("p"))))
        assertTrue(Bodies.hasNul(withNul.email))
    }

    @Test
    fun updateUser() {
        val all = assertNotNull(Bodies.updateUser(user(
            "email" to s("e"), "username" to s("u"), "password" to s("p"), "bio" to s("b"), "image" to s("i"),
        )))
        assertEquals("e", all.email); assertEquals("u", all.username); assertEquals("p", all.password)
        assertEquals("b", all.bio); assertEquals("i", all.image)
        val nulls = assertNotNull(Bodies.updateUser(user(
            "email" to nul, "username" to nul, "password" to nul, "bio" to nul, "image" to nul,
        )))
        assertNull(nulls.email); assertNull(nulls.username); assertNull(nulls.password); assertNull(nulls.bio)
        assertNull(nulls.image)
        assertNotNull(Bodies.updateUser(user()))
        val emptyBio = assertNotNull(Bodies.updateUser(user("bio" to s(""), "image" to s(""))))
        assertEquals("", emptyBio.bio); assertEquals("", emptyBio.image)
        for (bad in listOf(
            user("email" to s("")), user("username" to s("")), user("password" to s("")), user("bio" to num("5")),
            user("image" to JsonValue.Bool(false)), obj("bio" to s("b")), obj("user" to arr()),
            user("password" to s("x".repeat(73))),
        )) assertNull(Bodies.updateUser(bad), "$bad")
    }

    @Test
    fun createArticle() {
        val a = assertNotNull(Bodies.article(article(
            "title" to s("T"), "description" to s("D"), "body" to s("B"), "tagList" to arr(s("nain"), s("z"), s("z")),
        )))
        assertEquals("T", a.title); assertEquals(listOf("nain", "z", "z"), a.tags)
        for (tags in listOf(null, nul, arr())) {
            val m = mutableListOf<Pair<String, JsonValue>>("title" to s("T"), "description" to s("D"), "body" to s("B"))
            if (tags != null) m += "tagList" to tags
            assertEquals(emptyList(), assertNotNull(Bodies.article(article(*m.toTypedArray()))).tags)
        }
        for (bad in listOf(
            article("description" to s("D"), "body" to s("B")),
            article("title" to s("T"), "description" to s(""), "body" to s("B")),
            article("title" to s("T"), "description" to s("D"), "body" to nul),
            article("title" to num("7"), "description" to s("D"), "body" to s("B")),
            article("title" to s("T"), "description" to s("D"), "body" to s("B"), "tagList" to s("x")),
            article("title" to s("T"), "description" to s("D"), "body" to s("B"), "tagList" to arr(s("ok"), s(""))),
            article("title" to s("T"), "description" to s("D"), "body" to s("B"), "tagList" to arr(num("1"))),
            article("title" to s("T"), "description" to s("D"), "body" to s("B"), "tagList" to arr(nul)),
            article("title" to s("T"), "description" to s("D"), "body" to s("B"), "tagList" to obj()),
            obj("title" to s("T"), "description" to s("D"), "body" to s("B")),
            null,
        )) assertNull(Bodies.article(bad), "$bad")
    }

    @Test
    fun updateArticle() {
        val u = assertNotNull(Bodies.articleUpdate(article("body" to s("Updated body"), "title" to nul)))
        assertNull(u.title); assertEquals("Updated body", u.body); assertNull(u.description)
        // titles are kept verbatim, spaces included
        assertEquals("  T  ", assertNotNull(Bodies.articleUpdate(article("title" to s("  T  ")))).title)
        assertNotNull(Bodies.articleUpdate(article()))
        assertNull(Bodies.articleUpdate(article("title" to s(""))))
        assertNull(Bodies.articleUpdate(article("body" to num("1"))))
        assertNull(Bodies.articleUpdate(obj("body" to s("b"))))
    }

    @Test
    fun comment() {
        val text = "Conformance comment <b>&</b> \"quoted\" ünïcode"
        assertEquals(text, Bodies.comment(obj("comment" to obj("body" to s(text)))))
        assertNull(Bodies.comment(obj("comment" to obj("body" to s("")))))
        assertNull(Bodies.comment(obj("comment" to obj())))
        assertNull(Bodies.comment(obj("body" to s("x"))))
        assertNull(Bodies.comment(null))
    }

    @Test
    fun utf8Length() {
        assertEquals(0, Bodies.utf8Length(""))
        assertEquals(3, Bodies.utf8Length("abc"))
        assertEquals(2, Bodies.utf8Length("ü"))
        assertEquals(3, Bodies.utf8Length("€"))
        assertEquals(4, Bodies.utf8Length("😀"))
        assertEquals(3, Bodies.utf8Length("\uD83D")) // lone surrogate -> U+FFFD
    }

    @Test
    fun authHeader() {
        Jwt.init("multicore-server-challenge")
        val t = Jwt.sign(42, nowSec())
        // raw header bytes (as the engine passes them, here at an offset) and the String-only fallback
        fun bytes(h: String, keep: Boolean = true): Pair<Int, AuthEx> {
            val ex = AuthEx(null)
            val b = "xx$h".encodeToByteArray()
            ex.authBuf = b; ex.authOff = 2; ex.authLen = b.size - 2
            return Auth.check(ex, keep) to ex
        }
        fun string(h: String?): Int = Auth.check(AuthEx(h), true)
        val (ok, ex) = bytes("Token $t")
        assertEquals(Auth.VALID, ok); assertEquals(42, ex.viewer); assertEquals(t, ex.token)
        assertNull(bytes("Token $t", keep = false).second.token)
        assertEquals(Auth.VALID, string("Token $t"))
        assertEquals(Auth.NONE, string(null)); assertEquals(Auth.NONE, string("")); assertEquals(Auth.NONE, bytes("").first)
        for (bad in listOf("Bearer $t", "token $t", t, "Token", "Token ", "Token ${t}x", "Token  $t")) {
            assertEquals(Auth.INVALID, bytes(bad).first, bad)
            assertEquals(Auth.INVALID, string(bad), bad)
        }
    }
}

/** Just enough of an Exchange for [Auth.check]. */
private class AuthEx(override val authorization: String?) : Exchange() {
    override val method = Method.GET
    override val path = "/"
    override val query: String? = null
    override val body = ByteArray(0)
    override val out = ByteBuf(16)
    override val json = JsonWriter(out)
    override fun send(status: Int) {}
    override fun sendEmpty(status: Int) {}
    override fun sendError(status: Int, message: String) {}
}
