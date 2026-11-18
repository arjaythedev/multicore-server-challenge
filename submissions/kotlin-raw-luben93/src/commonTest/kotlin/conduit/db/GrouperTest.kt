package conduit.db

import conduit.pg.Result
import kotlin.coroutines.Continuation
import kotlin.coroutines.EmptyCoroutineContext
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

/** The grouping behind [Sharing.GROUPS]: requests with the same wire key, limit and offset share one set of rows. */
class GrouperTest {
    private fun req(key: String, limit: Int = 0, offset: Long = 0, viewer: Long = 1) =
        ReadReq(viewer, limit, offset, key, Continuation<Result>(EmptyCoroutineContext) {}, null)

    private fun group(vararg reqs: ReadReq): List<Int> {
        val rep = IntArray(reqs.size)
        Grouper().group(arrayOf<ReadReq?>(*reqs), reqs.size, rep)
        return rep.toList()
    }

    @Test
    fun wireKeyIsWhatPostgresWillSee() {
        val plain = "my-slug-é🙂"
        assertSame(plain, wireKey(plain)) // nothing to fix: the same string
        assertEquals("", wireKey("a\u0000b")) // a NUL matches nothing: the key ""
        assertEquals("a�b", wireKey("a\uD800b")) // a lone high surrogate is written as U+FFFD
        assertEquals("a�b", wireKey("a\uDC00b")) // and a lone low one
        assertEquals("a�", wireKey("a\uD800")) // at the end of the key too
        assertEquals("x🙂y", wireKey("x🙂y")) // a surrogate pair stays
        assertEquals("�🙂", wireKey("\uD800🙂")) // a lone one before a pair
    }

    @Test
    fun equalKeyLimitAndOffsetShareTheFirstRequest() {
        val reps = group(
            req("a"), req("b"), req("a"), req("a", offset = 10), req("a"), req("b", limit = 5), req("b"), req("a", offset = 10),
        )
        assertEquals(listOf(0, 1, 0, 3, 0, 5, 1, 3), reps)
    }

    @Test
    fun keysThatPostgresSeesAsEqualShareToo() {
        // "\uD800" is written as U+FFFD, so it is the same text as "�"; both NUL keys are "" (they match nothing)
        assertEquals(listOf(0, 0, 2, 2, 2), group(req("\uD800"), req("�"), req("a\u0000"), req(""), req("b\u0000c")))
    }

    @Test
    fun viewersDoNotSplitGroups() {
        assertEquals(listOf(0, 0, 0), group(req("a", viewer = 1), req("a", viewer = 2), req("a", viewer = 0)))
    }

    @Test
    fun manyRequestsAndTableReuse() {
        val g = Grouper()
        for (round in 0 until 3) {
            val n = 700 + round * 200
            val reqs = arrayOfNulls<ReadReq>(n)
            for (j in 0 until n) reqs[j] = req("k${j % 37}", limit = j % 3, offset = (j % 5).toLong())
            val rep = IntArray(n)
            g.group(reqs, n, rep)
            val first = HashMap<String, Int>()
            for (j in 0 until n) {
                val key = "k${j % 37}/${j % 3}/${j % 5}"
                assertEquals(first.getOrPut(key) { j }, rep[j], "request $j of round $round")
            }
        }
    }
}
