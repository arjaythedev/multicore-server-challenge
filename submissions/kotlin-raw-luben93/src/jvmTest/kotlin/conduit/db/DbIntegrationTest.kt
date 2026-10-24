package conduit.db

import conduit.db.TestPg.UNNEST
import conduit.pg.Oid
import conduit.pg.Params
import conduit.pg.Result
import conduit.platform.locked
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Against the lab Postgres: a copy of conduit_dev, the server role over SCRAM, test-only statements shaped like the
 * real ones (the 5-array unnest + LATERAL batch form, single-statement writes).
 */
class DbIntegrationTest {
    private class Article(val id: Long, val slug: String, val title: String)
    private class User(val id: Long, val username: String, val bio: String?)

    private class Fixture(val db: String) {
        val tags = ReadKind("tags", UNNEST + "(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) x")
        val bySlug = ReadKind("bySlug", UNNEST + "(SELECT a.id, a.slug, a.title FROM articles a WHERE a.slug = r.k) x")
        val page = ReadKind("page", UNNEST + "(SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o) x")
        val user = ReadKind(
            "user", UNNEST + "(SELECT u.id, u.username, u.bio FROM users u WHERE u.id = r.v) x", maxBatch = 8,
        )
        val divide = ReadKind("divide", UNNEST + "(SELECT 100 / r.l AS q) x")
        val settings = ReadKind(
            "settings", UNNEST + "(SELECT current_setting('plan_cache_mode') AS a, current_setting('jit') AS b, " +
                "current_setting('application_name') AS c, current_user::text AS d, " +
                "current_setting('client_encoding') AS e) x",
        )
        val slow = ReadKind("slow", UNNEST + "(SELECT r.o AS tag FROM pg_sleep(r.l / 1000.0)) x", maxInflight = 1)

        val sleep = WriteStmt("sleep", "SELECT 1 FROM pg_sleep(\$1 / 1000.0)", intArrayOf(Oid.INT4))
        val follow = WriteStmt(
            "follow", "INSERT INTO follows (follower_id, followee_id) VALUES (\$1, \$2) ON CONFLICT DO NOTHING",
            intArrayOf(Oid.INT8, Oid.INT8),
        )
        val userInsert = WriteStmt(
            "userInsert", "INSERT INTO users (username, email, password_hash) VALUES (\$1, \$2, 'x') RETURNING id",
            intArrayOf(Oid.TEXT, Oid.TEXT),
        )
        val setBio = WriteStmt(
            "setBio", "UPDATE users SET bio = \$2 WHERE id = \$1 RETURNING id, bio", intArrayOf(Oid.INT8, Oid.TEXT),
        )

        val rt = DbRuntime(
            TestPg.config(db, 3, 2), listOf(tags, bySlug, page, user, divide, settings, slow),
            listOf(sleep, follow, userInsert, setBio),
        ).also { it.start() }

        val expectedTags = TestPg.adminQuery(db, "SELECT name FROM tags ORDER BY name") { rows -> rows.map { it[0]!! } }
        val articles = TestPg.adminQuery(db, "SELECT id, slug, title FROM articles ORDER BY id DESC") { rows ->
            rows.map { Article(it[0]!!.toLong(), it[1]!!, it[2]!!) }
        }
        val users = TestPg.adminQuery(db, "SELECT id, username, bio FROM users WHERE id <= 500 ORDER BY id") { rows ->
            rows.map { User(it[0]!!.toLong(), it[1]!!, it[2]) }
        }
    }

    companion object {
        private val fixture: Fixture? by lazy { TestPg.db?.let { Fixture(it) } }
    }

    private fun check(cond: Boolean, what: () -> String) {
        if (!cond) throw AssertionError(what())
    }

    /** Also proves the contract that nothing completes inline: we must be on a connection thread, not the caller's. */
    private fun Result.expectOk(what: String) {
        check(ok) { "$what: $error" }
        val t = Thread.currentThread().name
        check(t.startsWith("pg-read-") || t.startsWith("pg-write-")) { "$what resumed on thread $t" }
    }

    @Test
    fun concurrentReadsGetExactlyTheirOwnRows() {
        val f = fixture ?: return
        val rt = f.rt
        val before = rt.readPool.lock.locked { rt.readPool.batches to rt.readPool.requests }
        val failures = ConcurrentLinkedQueue<String>()
        val total = 200
        val latch = CountDownLatch(total)
        val threads = (0 until 4).map { t ->
            Thread {
                val rnd = Random(t)
                repeat(total / 4) { k ->
                    val which = (t + k) % 5
                    val a = f.articles[rnd.nextInt(f.articles.size)]
                    val limit = 1 + rnd.nextInt(20)
                    val offset = rnd.nextInt(300)
                    val u = f.users[rnd.nextInt(f.users.size)]
                    TestPg.launch({
                        when (which) {
                            0 -> {
                                val r = rt.read(f.tags, 0, 0, 0, "")
                                r.expectOk("tags")
                                check(r.rowCount == f.expectedTags.size) { "tags: ${r.rowCount} rows" }
                                for (i in 0 until r.rowCount) {
                                    check(r.row(i).str(1) == f.expectedTags[i]) { "tags[$i]: ${r.row(i).str(1)}" }
                                }
                            }
                            1 -> {
                                val r = rt.read(f.bySlug, 0, 0, 0, a.slug)
                                r.expectOk("bySlug")
                                check(r.rowCount == 1) { "bySlug ${a.slug}: ${r.rowCount} rows" }
                                val row = r.row(0)
                                check(row.int8(1) == a.id && row.str(2) == a.slug && row.str(3) == a.title) {
                                    "bySlug ${a.slug}: got id ${row.int8(1)} ${row.str(2)}"
                                }
                            }
                            2 -> {
                                val r = rt.read(f.page, 0, limit, offset.toLong(), "")
                                r.expectOk("page")
                                val want = f.articles.subList(offset, offset + limit).map { it.id }
                                val got = (0 until r.rowCount).map { r.row(it).int8(1) }
                                check(got == want) { "page $limit/$offset: $got != $want" }
                            }
                            3 -> {
                                val r = rt.read(f.user, u.id, 0, 0, "")
                                r.expectOk("user")
                                check(r.rowCount == 1) { "user ${u.id}: ${r.rowCount} rows" }
                                val row = r.row(0)
                                check(row.int8(1) == u.id && row.str(2) == u.username && row.str(3) == u.bio) {
                                    "user ${u.id}: got ${row.int8(1)} ${row.str(2)}"
                                }
                            }
                            else -> {
                                // a key that matches nothing, and one Postgres could not even accept as text: both
                                // must come back empty without failing whatever shares their batch
                                val key = if (k % 2 == 0) "no-such-slug-$t-$k" else "bad\u0000key"
                                val r = rt.read(f.bySlug, 0, 0, 0, key)
                                r.expectOk("bySlug miss")
                                check(r.rowCount == 0) { "bySlug miss: ${r.rowCount} rows" }
                            }
                        }
                    }) { e ->
                        if (e != null) failures.add("${e::class.simpleName}: ${e.message}")
                        latch.countDown()
                    }
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        assertTrue(latch.await(60, TimeUnit.SECONDS), "requests still pending: ${latch.count}")
        assertEquals(emptyList(), failures.toList())
        val p = rt.readPool
        val (batches, requests) = p.lock.locked { p.batches - before.first to p.requests - before.second }
        println("concurrentReads: $requests requests in $batches batches; ${rt.stats()}")
        assertEquals(total.toLong(), requests)
        assertTrue(batches < requests, "expected some batching: $batches batches for $requests requests")
    }

    @Test
    fun anErrorFailsItsBatchButNotTheConnection() {
        val f = fixture ?: return
        val code = TestPg.await { f.rt.read(f.divide, 0, 0, 0, "").error?.code }
        assertEquals("22012", code) // division_by_zero
        val q = TestPg.await {
            val r = f.rt.read(f.divide, 0, 4, 0, "")
            if (r.ok) r.row(0).int4(1) else -1
        }
        assertEquals(25, q)
    }

    @Test
    fun startupPacketSetsTheSession() {
        val f = fixture ?: return
        val got = TestPg.await {
            val r = f.rt.read(f.settings, 0, 0, 0, "")
            if (!r.ok) listOf(r.error.toString()) else (1..5).map { r.row(0).str(it) }
        }
        assertEquals(listOf("force_generic_plan", "off", "conduit", "conduit", "UTF8"), got)
    }

    @Test
    fun startFailsFastOnBadStatementOrPassword() {
        val db = TestPg.db ?: return
        val bad = ReadKind("broken", UNNEST + "(SELECT no_such_column FROM articles a) x")
        val t0 = System.nanoTime()
        val e = runCatching { DbRuntime(TestPg.config(db, 1, 1), listOf(bad), emptyList()).start() }.exceptionOrNull()
        assertTrue(e is IllegalStateException && "read kind 'broken'" in e.message!! && "42703" in e.message!!, "$e")
        val wrong = DbConfig.fromUrl("postgres://conduit:wrong@${TestPg.host}:${TestPg.port}/$db", 1, 1, "")
        val e2 = runCatching { DbRuntime(wrong, emptyList(), emptyList()).start() }.exceptionOrNull()
        assertTrue(e2 is IllegalStateException && "28P01" in e2.message!!, "$e2")
        assertTrue(System.nanoTime() - t0 < 10_000_000_000L, "should not have retried")
    }

    @Test
    fun maxInflightKeepsAKindOffOtherConnections() {
        val f = fixture ?: return
        // two 300 ms requests of a kind limited to one connection: the second cannot start before the first ends
        // (it is queued behind it, so it runs in the next batch), while another kind runs meanwhile
        val t0 = System.nanoTime()
        val done = CountDownLatch(2)
        val ends = ConcurrentLinkedQueue<Long>()
        repeat(2) { k ->
            TestPg.launch({
                val r = f.rt.read(f.slow, 0, 300, k.toLong(), "")
                r.expectOk("slow")
                ends.add((System.nanoTime() - t0) / 1_000_000)
            }) { e ->
                if (e != null) ends.add(-1)
                done.countDown()
            }
            Thread.sleep(20)
        }
        val tagsMs = TestPg.await {
            f.rt.read(f.tags, 0, 0, 0, "").expectOk("tags")
            (System.nanoTime() - t0) / 1_000_000
        }
        assertTrue(done.await(10, TimeUnit.SECONDS))
        val sorted = ends.sorted()
        println("maxInflight: slow requests ended at $sorted ms, tags at $tagsMs ms")
        assertTrue(sorted[0] >= 290 && sorted[1] >= 590, "ends $sorted")
        assertTrue(tagsMs < 250, "tags waited behind the slow kind: $tagsMs ms")
    }

    @Test
    fun groupCommitIsolatesAFailingStatement() {
        val f = fixture ?: return
        val rt = f.rt
        val pairs = (1..100).map { 50_000L + it to 60_000L + it }
        TestPg.adminQuery(f.db, "DELETE FROM follows WHERE follower_id BETWEEN 50001 AND 50100") {}
        val takenEmail = TestPg.adminQuery(f.db, "SELECT email FROM users WHERE id = 1") { it[0][0]!! }
        val tag = Random.nextInt(1_000_000)
        val p0 = rt.writePool
        val (groups0, reruns0) = p0.lock.locked { p0.groups to p0.reruns }

        val failures = ConcurrentLinkedQueue<String>()
        val outcomes = ConcurrentLinkedQueue<String>()
        val total = 2 + pairs.size + 1 + 50 + 3
        val latch = CountDownLatch(total)
        fun go(block: suspend () -> Unit) = TestPg.launch(block) { e ->
            if (e != null) failures.add("${e::class.simpleName}: ${e.message}")
            latch.countDown()
        }
        // occupy both write connections so everything below queues up and leaves in groups
        repeat(2) { go { rt.write(f.sleep, Params().int4(300), isolated = true).expectOk("sleep") } }
        Thread.sleep(50)
        val threads = (0 until 4).map { t ->
            Thread {
                for (k in pairs.indices) {
                    if (k % 4 != t) continue
                    val (a, b) = pairs[k]
                    go {
                        val r = rt.write(f.follow, Params().int8(a).int8(b))
                        r.expectOk("follow $a->$b")
                        check(r.affected == 1L) { "follow $a->$b: affected ${r.affected}" }
                    }
                    if (k == 37) {
                        go {
                            // group-able on purpose: it must fail alone, the rest of its group must commit
                            val r = rt.write(f.userInsert, Params().text("dup-$tag").text(takenEmail))
                            outcomes.add("dup:${r.error?.code}")
                        }
                    }
                    if (k < 50) {
                        val uid = 1000L + k // outside the users the read test compares (ids <= 500)
                        go {
                            val r = rt.write(f.setBio, Params().int8(uid).text("bio-$tag-$uid"))
                            r.expectOk("setBio $uid")
                            check(r.rowCount == 1 && r.affected == 1L) { "setBio $uid: ${r.rowCount} rows" }
                            check(r.row(0).int8(0) == uid && r.row(0).str(1) == "bio-$tag-$uid") {
                                "setBio $uid: got row for ${r.row(0).int8(0)}"
                            }
                        }
                    }
                }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join() }
        // isolated writes riding along: one duplicate, two new users
        go { outcomes.add("isoDup:${rt.write(f.userInsert, Params().text("iso-dup-$tag").text(takenEmail), true).error?.code}") }
        for (n in 1..2) {
            go {
                val r = rt.write(f.userInsert, Params().text("iso-$tag-$n").text("iso-$tag-$n@example.com"), true)
                r.expectOk("iso insert")
                check(r.rowCount == 1 && r.row(0).int8(0) > 0) { "iso insert: no id" }
                outcomes.add("iso:ok")
            }
        }
        assertTrue(latch.await(60, TimeUnit.SECONDS), "writes still pending: ${latch.count}")
        assertEquals(emptyList(), failures.toList())
        assertEquals(listOf("dup:23505", "iso:ok", "iso:ok", "isoDup:23505"), outcomes.sorted())

        val committed = TestPg.adminQuery(
            f.db, "SELECT count(*) FROM follows WHERE follower_id BETWEEN 50001 AND 50100 AND followee_id = follower_id + 10000",
        ) { it[0][0]!!.toInt() }
        assertEquals(100, committed)
        val bios = TestPg.adminQuery(f.db, "SELECT count(*) FROM users WHERE bio = 'bio-$tag-' || id") { it[0][0]!!.toInt() }
        assertEquals(50, bios)
        val dups = TestPg.adminQuery(f.db, "SELECT count(*) FROM users WHERE username LIKE '%dup-$tag'") { it[0][0]!!.toInt() }
        assertEquals(0, dups)
        val p = rt.writePool
        val (groups, reruns) = p.lock.locked { p.groups - groups0 to p.reruns - reruns0 }
        println("groupCommit: $groups groups, $reruns reruns; ${rt.stats()}")
        assertTrue(groups >= 2, "expected group commits, got $groups")
        assertTrue(reruns >= 1, "the duplicate's group should have been rolled back and re-run")
    }

    @Test
    fun brokenConnectionsFailInFlightRequestsAndReconnect() {
        val f = fixture ?: return
        val slow = ReadKind("slow", UNNEST + "(SELECT r.o AS tag FROM pg_sleep(r.l / 1000.0)) x")
        val tags = ReadKind("tags", UNNEST + "(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) x")
        val follow = WriteStmt(
            "follow", "INSERT INTO follows (follower_id, followee_id) VALUES (\$1, \$2) ON CONFLICT DO NOTHING",
            intArrayOf(Oid.INT8, Oid.INT8),
        )
        val rt = DbRuntime(TestPg.config(f.db, 2, 1), listOf(slow, tags), listOf(follow))
        rt.start()
        try {
            val inFlight = java.util.concurrent.CompletableFuture<String?>()
            TestPg.launch({ inFlight.complete(rt.read(slow, 0, 3000, 1, "").error?.code) }) { e ->
                if (e != null) inFlight.completeExceptionally(e)
            }
            Thread.sleep(300)
            val pids = (rt.readPool.workers.toList() + rt.writePool.workers.toList()).mapNotNull { it.conn?.backendPid }
            assertEquals(3, pids.size)
            assertTrue(pids.all { it > 0 }, "backend pids $pids")
            // only these pids: never filter pg_stat_activity with pg_terminate_backend in the same WHERE (the planner
            // may evaluate the terminate first, on every backend of the cluster)
            TestPg.adminQuery("postgres", "SELECT pg_terminate_backend(p) FROM unnest(ARRAY[${pids.joinToString()}]::int[]) AS p") {}
            assertEquals("08006", inFlight.get(10, TimeUnit.SECONDS))

            // reads and writes work again once the workers have reconnected (immediately, or a second later)
            val deadline = System.nanoTime() + 15_000_000_000L
            var readOk = false
            var writeOk = false
            while (System.nanoTime() < deadline && !(readOk && writeOk)) {
                if (!readOk) readOk = TestPg.await { rt.read(tags, 0, 0, 0, "").let { it.ok && it.rowCount == f.expectedTags.size } }
                if (!writeOk) writeOk = TestPg.await { rt.write(follow, Params().int8(50_200).int8(60_200)).ok }
                if (!(readOk && writeOk)) Thread.sleep(200)
            }
            println("brokenConnections: ${rt.stats()}")
            assertTrue(readOk && writeOk, "no recovery: read $readOk write $writeOk; ${rt.stats()}")
            assertTrue(rt.readPool.lock.locked { rt.readPool.reconnects } >= 2)
            assertTrue(rt.writePool.lock.locked { rt.writePool.reconnects } >= 1)
        } finally {
            rt.stop()
        }
    }
}
