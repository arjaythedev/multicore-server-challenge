package conduit.db

import conduit.app.App
import conduit.app.Cols
import conduit.app.Sql
import conduit.pg.Result
import conduit.platform.locked
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The shared-rows reads ([Sharing.GROUPS]: comments, article, global/tag/author lists) against Postgres with the real
 * statements: hundreds of concurrent requests with different viewers and keys, so that batches hold groups of equal
 * requests and mixed viewers. Each request must get exactly what the same request gets alone, and its favorited / following
 * flags must match favorites and follows read straight from the tables.
 *
 * The statements are fixed when [Sql] is first used, so this test configures the shared shapes itself and must run alone
 * in its JVM; it does nothing unless SHARED_ROWS_TEST=1:
 *   SHARED_ROWS_TEST=1 gradle jvmTest --tests conduit.db.SharedRowsIntegrationTest
 */
class SharedRowsIntegrationTest {
    private class Fixture(val db: String) {
        val rt: DbRuntime

        val slugs: List<String>
        val commentedSlugs: List<String>
        val tags: List<String>
        val authors: List<String>
        val viewers: List<Long>
        val favs: Set<Pair<Long, Long>>
        val follows: Set<Pair<Long, Long>>

        init {
            App.configure(
                null, appSortsTags = false, shareReads = true, shareMaxBatch = 1024, viewerFlags = true, feedMaxBatch = 64,
                feedHeavy = true, feedFloor = true, feedShared = true, sharedRows = true,
            )
            check(Sql.COMMENTS.sharing == Sharing.GROUPS && Sql.LIST_ALL.sharing == Sharing.GROUPS) {
                "Sql was built before this test configured it: run the test alone (SHARED_ROWS_TEST=1 --tests ...)"
            }
            rt = DbRuntime(TestPg.config(db, 3, 1), Sql.reads, emptyList()).also { it.start() }
            fun col(sql: String) = TestPg.adminQuery(db, sql) { rows -> rows.map { it[0]!! } }
            slugs = col("SELECT slug FROM articles ORDER BY id DESC LIMIT 40")
            commentedSlugs = col(
                "SELECT a.slug FROM (SELECT article_id FROM comments GROUP BY article_id ORDER BY count(*) DESC LIMIT 15) c " +
                    "JOIN articles a ON a.id = c.article_id",
            )
            tags = col("SELECT name FROM tags ORDER BY id LIMIT 12")
            authors = col("SELECT u.username FROM (SELECT DISTINCT author_id FROM articles ORDER BY author_id LIMIT 12) a JOIN users u ON u.id = a.author_id")
            viewers = listOf(0L) + TestPg.adminQuery(
                db,
                "SELECT user_id FROM (SELECT DISTINCT user_id FROM favorites UNION SELECT DISTINCT follower_id FROM follows) t ORDER BY 1 LIMIT 80",
            ) { rows -> rows.map { it[0]!!.toLong() } }
            favs = TestPg.adminQuery(db, "SELECT user_id, article_id FROM favorites") { rows ->
                rows.map { it[0]!!.toLong() to it[1]!!.toLong() }.toSet()
            }
            follows = TestPg.adminQuery(db, "SELECT follower_id, followee_id FROM follows") { rows ->
                rows.map { it[0]!!.toLong() to it[1]!!.toLong() }.toSet()
            }
        }
    }

    companion object {
        private val on = System.getenv("SHARED_ROWS_TEST") == "1"
        private val fixture: Fixture? by lazy { if (on) TestPg.db?.let { Fixture(it) } else null }
    }

    private class Req(val kind: ReadKind, val viewer: Long, val limit: Int, val offset: Long, val key: String)

    /** Everything a handler would render from [r], flags resolved, plus the oracle's verdict on every flag. */
    private fun signature(f: Fixture, q: Req, r: Result, problems: MutableList<String>): String {
        check(r.ok) { "${q.kind.name}: ${r.error}" }
        val sb = StringBuilder()
        fun flags(articleId: Long, authorId: Long, fav: Boolean, fol: Boolean) {
            val wantFav = (q.viewer to articleId) in f.favs
            val wantFol = (q.viewer to authorId) in f.follows
            if (fav != wantFav) problems.add("${q.kind.name} viewer ${q.viewer} article $articleId: favorited $fav, table says $wantFav")
            if (fol != wantFol) problems.add("${q.kind.name} viewer ${q.viewer} author $authorId: following $fol, table says $wantFol")
        }
        sb.append(q.kind.name).append(" rows=").append(r.rowCount).append('\n')
        for (i in 0 until r.rowCount) {
            val row = r.row(i)
            when (q.kind.name) {
                "comments" -> {
                    if (row.isNull(1)) { sb.append("no comments\n"); continue }
                    val author = row.int8(8)
                    val fol = r.hasFlag(author)
                    if (fol != ((q.viewer to author) in f.follows)) {
                        problems.add("comments viewer ${q.viewer} author $author: following $fol, table says ${!fol}")
                    }
                    sb.append(row.int8(1)).append('|').append(row.micros(2)).append('|').append(row.str(4)).append('|')
                        .append(row.str(5)).append('|').append(fol).append('\n')
                }
                "article" -> {
                    val c = Cols.ARTICLE_SHARED // slug, title, description, body, created_at, updated_at, tags, fc, fav, user, bio, image, fol, id, author
                    val fav = r.hasFlag(row.int8(c + 13))
                    val fol = r.hasFlag(-row.int8(c + 14))
                    flags(row.int8(c + 13), row.int8(c + 14), fav, fol)
                    sb.append(row.str(c)).append('|').append(row.str(c + 3)?.length).append('|').append(row.micros(c + 4)).append('|')
                        .append(row.bytes(c + 6)?.joinToString(",")).append('|').append(row.int8(c + 7)).append('|')
                        .append(fav).append('|').append(row.str(c + 9)).append('|').append(fol).append('\n')
                }
                else -> { // a list: count in column 1, articles from Cols.LIST (NULL slug: an empty page)
                    if (i == 0) sb.append("count=").append(row.int8(Cols.LIST_COUNT)).append('\n')
                    if (row.isNull(Cols.LIST)) continue
                    val c = Cols.LIST // slug, title, description, created_at, updated_at, tags, fc, fav, user, bio, image, fol, id, author
                    val fav = r.hasFlag(row.int8(c + 12))
                    val fol = r.hasFlag(-row.int8(c + 13))
                    flags(row.int8(c + 12), row.int8(c + 13), fav, fol)
                    sb.append(row.str(c)).append('|').append(row.micros(c + 3)).append('|')
                        .append(row.bytes(c + 5)?.joinToString(",")).append('|').append(row.int8(c + 6)).append('|')
                        .append(fav).append('|').append(row.str(c + 8)).append('|').append(fol).append('\n')
                }
            }
        }
        return sb.toString()
    }

    private fun requests(f: Fixture, rnd: Random, n: Int): List<Req> = List(n) {
        val viewer = f.viewers[rnd.nextInt(f.viewers.size)]
        when (it % 5) {
            0 -> Req(Sql.ARTICLE_BY_SLUG, viewer, 0, 0, if (rnd.nextInt(12) == 0) "no-such-slug-$it" else f.slugs[rnd.nextInt(f.slugs.size)])
            1 -> Req(Sql.COMMENTS, viewer, 0, 0, if (rnd.nextInt(12) == 0) "bad\u0000key" else f.commentedSlugs[rnd.nextInt(f.commentedSlugs.size)])
            2 -> Req(Sql.LIST_ALL, viewer, intArrayOf(1, 5, 10, 20)[rnd.nextInt(4)], longArrayOf(0, 5, 10, 30)[rnd.nextInt(4)], "")
            3 -> Req(Sql.LIST_TAG, viewer, intArrayOf(5, 10)[rnd.nextInt(2)], longArrayOf(0, 10)[rnd.nextInt(2)],
                if (rnd.nextInt(12) == 0) "no-such-tag" else f.tags[rnd.nextInt(f.tags.size)])
            else -> Req(Sql.LIST_AUTHOR, viewer, intArrayOf(5, 10)[rnd.nextInt(2)], longArrayOf(0, 10)[rnd.nextInt(2)],
                if (rnd.nextInt(12) == 0) "no-such-user" else f.authors[rnd.nextInt(f.authors.size)])
        }
    }

    @Test
    fun concurrentGroupsGetWhatTheyWouldGetAlone() {
        val f = fixture ?: return
        val rnd = Random(20261030)
        val reqs = requests(f, rnd, 600)
        val problems = java.util.Collections.synchronizedList(ArrayList<String>())
        val concurrent = ConcurrentHashMap<Int, String>()
        val failures = java.util.Collections.synchronizedList(ArrayList<String>())
        val before = f.rt.readPool.lock.locked { f.rt.readPool.batches to f.rt.readPool.requests }
        val latch = CountDownLatch(reqs.size)
        val threads = (0 until 4).map { t ->
            Thread {
                for (i in t until reqs.size step 4) {
                    val q = reqs[i]
                    TestPg.launch({
                        val r = f.rt.read(q.kind, q.viewer, q.limit, q.offset, q.key)
                        concurrent[i] = signature(f, q, r, problems)
                    }) { e ->
                        if (e != null) failures.add("$i ${q.kind.name}: ${e::class.simpleName}: ${e.message}")
                        latch.countDown()
                    }
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertTrue(latch.await(60, TimeUnit.SECONDS), "requests still pending: ${latch.count}")
        assertEquals(emptyList(), failures.toList())
        val p = f.rt.readPool
        val (batches, requests) = f.rt.readPool.lock.locked { p.batches - before.first to p.requests - before.second }
        println("sharedRows: $requests requests in $batches batches; ${f.rt.stats()}")
        assertTrue(batches < requests, "expected batching: $batches batches for $requests requests")

        // the same requests, one at a time: each is its own batch and its own group
        var withFlags = 0
        for ((i, q) in reqs.withIndex()) {
            val alone = TestPg.await { signature(f, q, f.rt.read(q.kind, q.viewer, q.limit, q.offset, q.key), problems) }
            assertEquals(alone, concurrent[i], "request $i (${q.kind.name} viewer ${q.viewer} key '${q.key}' ${q.limit}/${q.offset}) differs from the lone one")
            if (alone.contains("|true")) withFlags++
        }
        println("sharedRows: ${reqs.size} requests compared, $withFlags with at least one flag set")
        assertEquals(emptyList(), problems.toList().take(20))
        assertTrue(withFlags > 0, "the fixture should exercise favorited/following flags")
    }
}
