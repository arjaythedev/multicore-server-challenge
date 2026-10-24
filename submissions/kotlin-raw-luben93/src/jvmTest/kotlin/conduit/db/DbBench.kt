package conduit.db

import conduit.db.TestPg.UNNEST
import conduit.pg.Oid
import conduit.pg.Params
import conduit.platform.locked
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Throughput / latency of the read and write paths alone (no HTTP), closed loop: N virtual clients, each issuing
 * its next request as soon as the previous one completed (on the connection thread, like a handler would).
 * Opt-in: DB_BENCH=1 (DB_BENCH_READS / DB_BENCH_WRITES = connections, DB_BENCH_SECONDS per step).
 */
class DbBench {
    @Test
    fun bench() {
        if (System.getenv("DB_BENCH") != "1") return
        val db = TestPg.db ?: return
        val reads = System.getenv("DB_BENCH_READS")?.toInt() ?: 6
        val writes = System.getenv("DB_BENCH_WRITES")?.toInt() ?: 2
        val seconds = System.getenv("DB_BENCH_SECONDS")?.toDouble() ?: 3.0
        val bySlug = ReadKind("bySlug", UNNEST + "(SELECT a.id, a.slug, a.title FROM articles a WHERE a.slug = r.k) x")
        val page = ReadKind(
            "page", UNNEST + "(SELECT a.id, a.slug, a.title, a.description, a.created_at FROM articles a " +
                "ORDER BY a.id DESC LIMIT r.l OFFSET r.o) x",
        )
        val follow = WriteStmt(
            "follow", "INSERT INTO follows (follower_id, followee_id) VALUES (\$1, \$2) ON CONFLICT DO NOTHING",
            intArrayOf(Oid.INT8, Oid.INT8),
        )
        val unfollow = WriteStmt(
            "unfollow", "DELETE FROM follows WHERE follower_id = \$1 AND followee_id = \$2", intArrayOf(Oid.INT8, Oid.INT8),
        )
        val slugs = TestPg.adminQuery(db, "SELECT slug FROM articles") { rows -> rows.map { it[0]!! } }
        val rt = DbRuntime(TestPg.config(db, reads, writes), listOf(bySlug, page), listOf(follow, unfollow))
        rt.start()
        val out = StringBuilder("DbBench: $reads read + $writes write connections, ${seconds}s per step, " +
            "cpus ${Runtime.getRuntime().availableProcessors()}\n")
        try {
            fun step(name: String, clients: Int, op: suspend (Random) -> Boolean) {
                val rp = rt.readPool
                val wp = rt.writePool
                val (b0, r0) = rp.lock.locked { rp.batches to rp.requests }
                val (t0, j0, g0, gj0) = wp.lock.locked { listOf(wp.trips, wp.jobs, wp.groups, wp.groupedJobs) }
                val count = AtomicLong()
                val errors = AtomicLong()
                val latencyNanos = AtomicLong()
                val start = System.nanoTime()
                val end = start + (seconds * 1e9).toLong()
                val done = CountDownLatch(clients)
                for (c in 0 until clients) {
                    val rnd = Random(c)
                    TestPg.launch({
                        while (System.nanoTime() < end) {
                            val t = System.nanoTime()
                            if (!op(rnd)) errors.incrementAndGet()
                            latencyNanos.addAndGet(System.nanoTime() - t)
                            count.incrementAndGet()
                        }
                    }) { e ->
                        if (e != null) errors.incrementAndGet()
                        done.countDown()
                    }
                }
                done.await(60, TimeUnit.SECONDS)
                val elapsed = (System.nanoTime() - start) / 1e9
                val n = count.get()
                val (b1, r1) = rp.lock.locked { rp.batches to rp.requests }
                val (t1, j1, g1, gj1) = wp.lock.locked { listOf(wp.trips, wp.jobs, wp.groups, wp.groupedJobs) }
                val perTrip = if (r1 > r0) "reads/batch %.1f".format((r1 - r0).toDouble() / (b1 - b0))
                else "jobs/trip %.1f, groups %d (%.1f jobs/group)".format(
                    (j1 - j0).toDouble() / maxOf(1, t1 - t0), g1 - g0, (gj1 - gj0).toDouble() / maxOf(1, g1 - g0),
                )
                out.append(
                    "%-34s clients %5d: %8.0f ops/s, mean latency %7.0f us, %s, errors %d\n".format(
                        name, clients, n / elapsed, latencyNanos.get() / 1e3 / maxOf(1, n), perTrip, errors.get(),
                    ),
                )
                assertEquals(0, errors.get(), "$name: errors")
            }

            val bySlugOp: suspend (Random) -> Boolean = { rnd ->
                val r = rt.read(bySlug, 0, 0, 0, slugs[rnd.nextInt(slugs.size)])
                r.ok && r.rowCount == 1
            }
            val pageOp: suspend (Random) -> Boolean = { rnd ->
                val r = rt.read(page, 0, 20, rnd.nextInt(500).toLong(), "")
                r.ok && r.rowCount == 20
            }
            step("warm-up article-by-slug", 64, bySlugOp)
            for (c in intArrayOf(1, 8, 64, 256, 1024)) step("article-by-slug (1 row)", c, bySlugOp)
            for (c in intArrayOf(1, 64, 256)) step("article page (20 rows)", c, pageOp)
            val followOp: suspend (Random) -> Boolean = { rnd ->
                val a = 70_000L + rnd.nextInt(5000)
                val b = 80_000L + rnd.nextInt(5000)
                val r = if (rnd.nextBoolean()) rt.write(follow, Params().int8(a).int8(b))
                else rt.write(unfollow, Params().int8(a).int8(b))
                r.ok
            }
            for (c in intArrayOf(1, 16, 128)) step("follow/unfollow (group commit)", c, followOp)
        } finally {
            println(out)
            System.err.println(out)
            rt.stop()
        }
    }
}
