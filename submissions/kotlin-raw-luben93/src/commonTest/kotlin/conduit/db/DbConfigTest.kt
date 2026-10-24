package conduit.db

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class DbConfigTest {
    private fun parse(url: String) = DbConfig.fromUrl(url, 6, 2, "-c jit=off")

    @Test
    fun ciStyleUrl() {
        val c = parse("postgres://conduit:conduit@127.0.0.1:5432/challenge_test_123")
        assertEquals("127.0.0.1", c.host)
        assertEquals(5432, c.port)
        assertEquals("conduit", c.user)
        assertEquals("conduit", c.password)
        assertEquals("challenge_test_123", c.database)
        assertEquals(6, c.readConns)
        assertEquals(2, c.writeConns)
        assertEquals("-c jit=off", c.options)
    }

    @Test
    fun percentDecodingAndScheme() {
        val c = parse("postgresql://u%40x:p%3Aw%2F%C3%A9@db.example:6543/my%20db?sslmode=disable")
        assertEquals("u@x", c.user)
        assertEquals("p:w/é", c.password)
        assertEquals("db.example", c.host)
        assertEquals(6543, c.port)
        assertEquals("my db", c.database)
    }

    @Test
    fun defaults() {
        val c = parse("postgres://u:p@host/db")
        assertEquals(5432, c.port)
        val d = parse("postgres://[::1]:5433/db")
        assertEquals("::1", d.host)
        assertEquals(5433, d.port)
        assertEquals("postgres", d.user)
        assertEquals("", d.password)
        val e = parse("postgres://alice@localhost")
        assertEquals("alice", e.database)
        assertEquals("", e.password)
    }

    @Test
    fun unencodedAtInPassword() {
        val c = parse("postgres://u:p@w@host:1/db")
        assertEquals("u", c.user)
        assertEquals("p@w", c.password)
        assertEquals("host", c.host)
        assertEquals(1, c.port)
    }

    @Test
    fun malformedPercentKept() {
        assertEquals("a%zz", parse("postgres://a%zz:x@h/d").user)
        assertEquals("ab%", parse("postgres://ab%:x@h/d").user)
    }

    @Test
    fun rejects() {
        assertFailsWith<IllegalArgumentException> { parse("mysql://u:p@h/d") }
        assertFailsWith<IllegalArgumentException> { parse("postgres://u:p@h:notaport/d") }
    }
}
