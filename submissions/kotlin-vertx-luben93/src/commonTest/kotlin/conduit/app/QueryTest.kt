package conduit.app

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull

class QueryTest {
    private fun ok(q: String?, filters: Boolean = true): ListQuery = assertNotNull(ListQuery.parse(q, filters), q)

    private fun check(q: String?, limit: Int, offset: Long, filter: Int = Filter.NONE, key: String = "") {
        val p = ok(q)
        assertEquals(limit, p.limit, "limit of $q")
        assertEquals(offset, p.offset, "offset of $q")
        assertEquals(filter, p.filter, "filter of $q")
        assertEquals(key, p.key, "key of $q")
    }

    @Test
    fun defaults() {
        check(null, 20, 0)
        check("", 20, 0)
        check("&", 20, 0)
        check("foo=bar", 20, 0)
    }

    @Test
    fun limitAndOffset() {
        check("limit=1", 1, 0)
        check("limit=100", 100, 0)
        check("limit=5&offset=5", 5, 5)
        check("limit=05&offset=005", 5, 5)
        check("offset=100000000", 20, 100000000)
        check("&limit=10&offset=0", 10, 0) // the feed page check's leading '&'
        check("limit=10&limit=abc", 10, 0) // first occurrence wins
        check("limit=%35", 5, 0)           // decoded before validation
        check("limit=0000000000000000000000001", 1, 0)
        check("offset=9223372036854775807", 20, ListQuery.MAX_OFFSET) // clamped: r.l + r.o can't overflow
    }

    @Test
    fun invalidIs422() {
        for (q in listOf(
            "limit=0", "limit=101", "limit=-1", "limit=abc", "limit=", "limit", "limit=1.5", "limit=%2B5",
            "limit=%205", "limit=+5", "offset=-1", "offset=abc", "offset=", "offset=99999999999999999999",
            "offset=9223372036854775808", "limit=1e2", "limit=10&offset=x",
        )) assertNull(ListQuery.parse(q, true), q)
        assertNull(ListQuery.parse("limit=0", false), "feed limit=0")
    }

    @Test
    fun skippedPairsLikeGo() {
        check("limit=%zz", 20, 0)               // malformed escape: pair dropped
        check("limit=%zz&limit=7", 7, 0)        // ... so the next occurrence is the first
        check("limit=1;offset=2", 20, 0)        // ';' in a pair: dropped
    }

    @Test
    fun valuesPostgresCantHold() {
        // A filter value with NUL or invalid UTF-8 still applies (precedence), but matches nothing.
        check("tag=a%00b&author=bob", 20, 0, Filter.TAG, Url.INVALID)
        check("author=%FF", 20, 0, Filter.AUTHOR, Url.INVALID)
        check("favorited=%C3", 20, 0, Filter.FAVORITED, Url.INVALID)
        check("t%00g=x", 20, 0) // an undecodable key is just an unknown key
        // and limit/offset holding such bytes are not digits: 422, as in Go
        assertNull(ListQuery.parse("limit=%00", true))
        assertNull(ListQuery.parse("offset=1%FF", true))
    }

    @Test
    fun filters() {
        check("tag=nain", 20, 0, Filter.TAG, "nain")
        check("author=bob&limit=10", 10, 0, Filter.AUTHOR, "bob")
        check("favorited=conformance_user2", 20, 0, Filter.FAVORITED, "conformance_user2")
        check("author=V&tag=T", 20, 0, Filter.TAG, "T")                 // tag > author
        check("favorited=F&author=A", 20, 0, Filter.AUTHOR, "A")        // author > favorited
        check("tag=&author=A&limit=10", 10, 0, Filter.AUTHOR, "A")      // empty tag is ignored
        check("tag=&tag=x", 20, 0)                                      // first (empty) occurrence wins
        check("tag=two+words", 20, 0, Filter.TAG, "two words")
        check("tag=a%2Bb", 20, 0, Filter.TAG, "a+b")
        check("t%61g=x", 20, 0, Filter.TAG, "x")                        // keys are decoded too
        check("author=%C3%BC", 20, 0, Filter.AUTHOR, "ü")
    }

    @Test
    fun feedIgnoresFilters() {
        val p = ok("tag=nain&limit=5&offset=5", filters = false)
        assertEquals(Filter.NONE, p.filter)
        assertEquals("", p.key)
        assertEquals(5, p.limit)
        assertEquals(5L, p.offset)
    }

    @Test
    fun digits() {
        assertEquals(0L, ListQuery.digits("0"))
        assertEquals(42L, ListQuery.digits("0042"))
        assertEquals(Long.MAX_VALUE, ListQuery.digits("9223372036854775807"))
        assertEquals(-1L, ListQuery.digits("9223372036854775808"))
        assertEquals(-1L, ListQuery.digits(""))
        assertEquals(-1L, ListQuery.digits("12a"))
        assertEquals(-1L, ListQuery.digits("-1"))
    }
}
