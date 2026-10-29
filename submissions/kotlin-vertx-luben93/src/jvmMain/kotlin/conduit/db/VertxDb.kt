package conduit.db

import conduit.pg.Oid
import conduit.pg.Params
import conduit.pg.PgError
import conduit.pg.Result
import conduit.platform.getenv
import conduit.util.ByteBuf
import conduit.util.logSafe
import conduit.util.intBE
import conduit.util.longBE
import io.vertx.core.Future
import io.vertx.core.Vertx
import io.vertx.core.VertxOptions
import io.vertx.core.net.NetClientOptions
import io.vertx.pgclient.PgBuilder
import io.vertx.pgclient.PgConnectOptions
import io.vertx.pgclient.PgConnection
import io.vertx.pgclient.PgException
import io.vertx.sqlclient.Pool
import io.vertx.sqlclient.PoolOptions
import io.vertx.sqlclient.Row
import io.vertx.sqlclient.RowSet
import io.vertx.sqlclient.Tuple
import java.time.OffsetDateTime
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.Continuation
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.coroutines.suspendCoroutine

/**
 * DB_DRIVER=vertx: [Db] on the Vert.x 5 reactive Postgres client (the client of the fastest JVM TechEmpower entries),
 * the way a maintainable production server would talk to Postgres: every read and write its own prepared-statement
 * execution, each write its own transaction, coroutines suspended on the driver's Future and resumed on its event
 * loop. The SQL is ours unchanged; each read runs as a batch of one (READ_SHARE=0 gives the plain per-request
 * statements).
 * - Reads: VERTX_READ_CONNS (default 16) pipelined connections of our own, each read sent to the one with the fewest
 *   reads in flight ([ReadConn]). Neither Vert.x pool spreads reads: a Pool runs one statement per connection at a
 *   time (not pipelined), and the pooled client (PgBuilder.client()) gives each connection a capacity of its whole
 *   pipelining limit (256), so it opens a second connection only once the first has 256 in flight (lab: ~1,700
 *   reads/s on one Postgres backend, the others idle). Postgres runs a connection's statements one after another, so
 *   per-request statements need connections to run in parallel; pipelining only hides the round trips.
 * - Writes: group commit, as our own driver does (VERTX_WRITE_GROUP writes per transaction, VERTX_WRITE_GROUPS
 *   transactions at once, on a separate Pool): every write waits for its WAL flush, and with one transaction per write
 *   the lab managed ~90 writes/s (one or two backends ever committing); since each virtual user waits for its write
 *   before its next page, that throttled the reads too (~1,700/s at any load). Isolated writes (expected to fail:
 *   sign-up, user update) and the jobs of a failed group run alone.
 * - Statement cache: long SQL too (the default cache skips SQL over 2,048 chars, and our shared list statements are
 *   longer: they would be parsed and planned on every execution).
 *
 * The driver decodes rows into Java objects; they are re-encoded here into our binary row layout so the handlers run
 * unchanged. A Vert.x-native app would render from those objects instead, so this costs the variant a little extra.
 */
actual fun driverBackend(driver: String, config: DbConfig, reads: List<ReadKind>, writes: List<WriteStmt>): DbBackend? =
    if (driver == "vertx") VertxDb(config) else null

/**
 * One pipelined read connection and the reads in flight on it. [conn] is null while (re)connecting; a broken
 * connection is replaced in the background, and reads go to the others meanwhile.
 */
private class ReadConn(private val vertx: Vertx, private val options: PgConnectOptions) {
    @Volatile var conn: PgConnection? = null
    val inflight = AtomicInteger()
    private val connecting = AtomicBoolean()

    /** Opens the connection (blocking up to [waitMillis] when > 0, else in the background). */
    fun connect(waitMillis: Long = 0) {
        if (!connecting.compareAndSet(false, true)) return
        val f = PgConnection.connect(vertx, options).onComplete { ar ->
            connecting.set(false)
            if (ar.succeeded()) {
                val c = ar.result()
                c.closeHandler { if (conn === c) { conn = null; reconnectLater() } }
                c.exceptionHandler { } // the close handler follows a broken socket
                conn = c
            } else {
                reconnectLater()
            }
        }
        if (waitMillis > 0) f.toCompletionStage().toCompletableFuture().get(waitMillis, TimeUnit.MILLISECONDS)
    }

    private fun reconnectLater() {
        vertx.setTimer(200) { connect() }
    }
}

internal class VertxDb(config: DbConfig) : DbBackend {
    private val vertx: Vertx
    private val readConns: Array<ReadConn>
    private val writePool: Pool
    private val reads = AtomicLong()
    private val writes = AtomicLong()
    private val failures = AtomicLong()

    /** Most writes per group transaction (VERTX_WRITE_GROUP, default 64; 1 = every write its own transaction). */
    private val groupMax = getenv("VERTX_WRITE_GROUP")?.toIntOrNull()?.coerceAtLeast(1) ?: 64

    /** Group transactions in flight at once (VERTX_WRITE_GROUPS, default 4, like our driver's write connections). */
    private val groupConcurrency = getenv("VERTX_WRITE_GROUPS")?.toIntOrNull()?.coerceAtLeast(1) ?: 4

    init {
        val loops = getenv("VERTX_LOOPS")?.toIntOrNull() ?: if (getenv("HTTP_IO") == "vertx") 4 else 2
        // batched: 8 (lab, 5-minute holds at 144k users: 6 failed with p95 651 ms, 8 passed with 246 / 369 ms, 10 the
        // same as 8); per request: 16
        val nReads = getenv("VERTX_READ_CONNS")?.toIntOrNull() ?: if (getenv("VERTX_BATCH") != "0") 8 else 16
        // the groups, plus room for isolated writes and a failed group's one-by-one retries
        val nWrites = getenv("VERTX_WRITE_CONNS")?.toIntOrNull() ?: (groupConcurrency + 4)
        val pipeline = getenv("VERTX_PIPELINE")?.toIntOrNull() ?: 256
        vertx = conduit.platform.SharedVertx.instance // the same event loops as HTTP_IO=vertx
        val connect = PgConnectOptions()
            .setHost(config.host).setPort(config.port).setDatabase(config.database)
            .setUser(config.user).setPassword(config.password)
            .setPipeliningLimit(pipeline)
            .setCachePreparedStatements(true)
            .setPreparedStatementCacheMaxSize(256)
            .setPreparedStatementCacheSqlLimit(65536)
            .setProperties(sessionSettings(config.options))
        // connected from this (non-Vert.x) thread, each connection gets its own context, spread over the event loops
        readConns = Array(nReads) { ReadConn(vertx, connect).also { it.connect(waitMillis = 60_000) } }
        writePool = PgBuilder.pool()
            .with(PoolOptions().setMaxSize(nWrites).setEventLoopSize(loops))
            .with(NetClientOptions().setTcpNoDelay(true))
            .connectingTo(connect)
            .using(vertx)
            .build()
        if (getenv("VERTX_BATCH") != "0" && config.gatherMicros > 0) startGatherClock()
        println(
            "db: vert.x pg client, reads $nReads connections pipelined x$pipeline (least in flight" +
                (if (getenv("VERTX_BATCH") != "0") ", batched, gather ${config.gatherMicros / 1000} ms" else ", per request") + "), " +
                "writes $nWrites connections (group commit: up to $groupMax per transaction, $groupConcurrency at once), " +
                "$loops event loops",
        )
    }

    /** The open read connection with the fewest reads in flight (ties: the first); null if none is open. */
    private fun pick(): ReadConn? {
        var best: ReadConn? = null
        var min = Int.MAX_VALUE
        for (c in readConns) {
            if (c.conn == null) continue
            val n = c.inflight.get()
            if (n < min) {
                min = n
                best = c
                if (n == 0) break
            }
        }
        return best
    }

    // ---- batched reads (VERTX_BATCH, default on): our own driver's batching on Vert.x connections ----
    // Requests of one kind queue for up to the gather window (READ_GATHER_MS) or until the kind's batch is full, then
    // leave as ONE execution of the kind's array statement (the same SQL as our driver, shared reads included); rows
    // come back routed by column 0 (r.i) to each request. Per-request statements cost Postgres ~2x per request
    // (lab, 96k users: 198 vs 108 us), and Postgres is what runs out first: per request, this stack held ~75k box.

    private class Pending(val viewer: Long, val limit: Int, val offset: Long, val key: String, val cont: Continuation<Result>)

    private class Batcher(val kind: ReadKind) {
        val lock = Any()
        var queue = ArrayList<Pending>()
        var oldest = 0L
    }

    private val batching = getenv("VERTX_BATCH") != "0"
    private val gatherNanos = config.gatherMicros * 1000L
    private val batchers = HashMap<ReadKind, Batcher>()
    private val batches = AtomicLong()

    private fun batcher(kind: ReadKind): Batcher = synchronized(batchers) { batchers.getOrPut(kind) { Batcher(kind) } }

    /** Every eighth of the window (at least 1 ms): sends the kinds whose oldest request has waited it out. */
    private fun startGatherClock() {
        val tick = maxOf(1L, gatherNanos / 8_000_000L)
        vertx.setPeriodic(tick) {
            val now = System.nanoTime()
            val all = synchronized(batchers) { batchers.values.toList() }
            for (b in all) {
                val due = synchronized(b.lock) { b.queue.isNotEmpty() && now - b.oldest >= gatherNanos }
                if (due) flush(b)
            }
        }
    }

    private suspend fun readBatched(kind: ReadKind, viewer: Long, limit: Int, offset: Long, key: String): Result {
        val b = batcher(kind)
        return suspendCoroutine { c ->
            val full = synchronized(b.lock) {
                if (b.queue.isEmpty()) b.oldest = System.nanoTime()
                b.queue.add(Pending(viewer, limit, offset, if (key.indexOf('\u0000') >= 0) "" else key, c))
                gatherNanos <= 0L || b.queue.size >= kind.maxBatch
            }
            if (full) flush(b)
        }
    }

    /** Sends what [b] has queued (up to its kind's batch size; the rest waits for the next flush). */
    private fun flush(b: Batcher) {
        val take = synchronized(b.lock) {
            if (b.queue.isEmpty()) return
            val max = b.kind.maxBatch.coerceAtLeast(1)
            if (b.queue.size <= max) {
                val all = b.queue
                b.queue = ArrayList()
                all
            } else {
                val first = ArrayList(b.queue.subList(0, max))
                b.queue = ArrayList(b.queue.subList(max, b.queue.size))
                b.oldest = System.nanoTime() // conservative: the rest leaves within one more window
                first
            }
        }
        batches.incrementAndGet()
        val rc = pick()
        val conn = rc?.conn
        if (rc == null || conn == null) {
            failAll(take, PgError("08006", "no read connection"))
            return
        }
        rc.inflight.incrementAndGet()
        val q = conn.preparedQuery(b.kind.sql)
        val f = if (b.kind.broadcast) q.execute() else q.execute(
            Tuple.of(
                Array(take.size) { it }, Array(take.size) { take[it].viewer }, Array(take.size) { take[it].limit },
                Array(take.size) { take[it].offset }, Array(take.size) { take[it].key },
            ),
        )
        f.onComplete { ar ->
            rc.inflight.decrementAndGet()
            if (ar.failed()) {
                val e = ar.cause()
                failAll(take, if (e is PgException) PgError(e.sqlState ?: "XX000", e.errorMessage ?: e.message ?: "")
                else PgError("08006", e.message ?: e.toString()))
                return@onComplete
            }
            // object-mode rows: the driver's decoded values, shared read-only by the requests they belong to
            val rows = values(ar.result())
            val per = Array(take.size) { Result() }
            if (b.kind.broadcast) {
                for (r in per) for (v in rows) r.addObjRow(v)
            } else {
                for (v in rows) { // column 0 = r.i, the request's index in this batch
                    val i = (v[0] as Number).toInt()
                    if (i in per.indices) per[i].addObjRow(v)
                }
            }
            for (j in take.indices) {
                per[j].affected = per[j].rowCount.toLong()
                resumeRead(take[j], per[j])
            }
        }
    }

    private fun failAll(take: List<Pending>, err: PgError) {
        failures.addAndGet(take.size.toLong())
        for (p in take) resumeRead(p, Result().also { it.error = err })
    }

    private fun resumeRead(p: Pending, r: Result) {
        try {
            p.cont.resume(r)
        } catch (e: Throwable) { // one handler failing must not skip the rest of the batch
            logSafe({ "db: vert.x read continuation threw" }, e)
        }
    }

    override suspend fun read(kind: ReadKind, viewer: Long, limit: Int, offset: Long, key: String): Result {
        reads.incrementAndGet()
        if (batching) return readBatched(kind, viewer, limit, offset, key)
        val rc = pick()
        val conn = rc?.conn
        if (rc == null || conn == null) {
            failures.incrementAndGet()
            return Result().also { it.error = PgError("08006", "no read connection") }
        }
        rc.inflight.incrementAndGet()
        try {
            val q = conn.preparedQuery(kind.sql)
            val f = if (kind.broadcast) q.execute() else q.execute(
                Tuple.of(
                    arrayOf(0), arrayOf(viewer), arrayOf(limit), arrayOf(offset),
                    arrayOf(if (key.indexOf('\u0000') >= 0) "" else key),
                ),
            )
            return run(f)
        } finally {
            rc.inflight.decrementAndGet()
        }
    }

    override suspend fun write(stmt: WriteStmt, params: Params, isolated: Boolean): Result {
        writes.incrementAndGet()
        val tuple = tupleOf(stmt, params)
        if (isolated || groupMax <= 1) return run(writePool.preparedQuery(stmt.sql).execute(tuple))
        return try {
            toResult(suspendCoroutine { c -> enqueue(WriteJob(stmt.sql, tuple, c)) })
        } catch (e: Exception) {
            errorResult(e)
        }
    }

    // ---- group commit: concurrent writes share one transaction and one WAL flush ----

    /** One queued write; [cont] is resumed with its rows only after its group's COMMIT (or its own retry). */
    private class WriteJob(val sql: String, val tuple: Tuple, val cont: Continuation<RowSet<Row>>)

    private val queueLock = Any()
    private val queue = ArrayDeque<WriteJob>()
    private var groupsInFlight = 0
    private val groups = AtomicLong()

    private fun enqueue(j: WriteJob) {
        val batch = synchronized(queueLock) {
            queue.addLast(j)
            if (groupsInFlight >= groupConcurrency) return
            groupsInFlight++
            takeLocked()
        }
        runGroup(batch)
    }

    private fun takeLocked(): List<WriteJob> {
        val n = minOf(queue.size, groupMax)
        return List(n) { queue.removeFirst() }
    }

    /**
     * Runs [batch] as one transaction on a pooled connection: all statements pipelined, then COMMIT; every job is
     * resumed after the commit. If any statement fails the transaction rolls back, and each job is retried on its own
     * (its own transaction), so each caller gets its own statement's outcome. Then takes the next batch, if any.
     */
    private fun runGroup(batch: List<WriteJob>) {
        groups.incrementAndGet()
        writePool.withTransaction { conn ->
            Future.all(batch.map { conn.preparedQuery(it.sql).execute(it.tuple) }).map { all ->
                List(batch.size) { i -> all.resultAt<RowSet<Row>>(i) }
            }
        }.onComplete { ar ->
            if (ar.succeeded()) {
                val rows = ar.result()
                for (i in batch.indices) resumeJob(batch[i]) { it.resume(rows[i]) }
            } else {
                for (j in batch) {
                    writePool.preparedQuery(j.sql).execute(j.tuple).onComplete { one ->
                        resumeJob(j) { c -> if (one.succeeded()) c.resume(one.result()) else c.resumeWithException(one.cause()) }
                    }
                }
            }
            val next = synchronized(queueLock) {
                if (queue.isEmpty()) {
                    groupsInFlight--
                    null
                } else takeLocked()
            }
            if (next != null) runGroup(next)
        }
    }

    /** Resumes one job; a handler that throws must not stop the rest of its group. */
    private inline fun resumeJob(j: WriteJob, f: (Continuation<RowSet<Row>>) -> Unit) {
        try {
            f(j.cont)
        } catch (e: Throwable) {
            logSafe({ "db: vert.x write continuation threw" }, e)
        }
    }

    override fun stats(): String =
        "db: vert.x reads ${reads.get()} read batches ${batches.get()} writes ${writes.get()} write groups ${groups.get()} failures ${failures.get()}"

    private suspend fun run(f: Future<RowSet<Row>>): Result = try {
        toResult(f.coAwait())
    } catch (e: Exception) {
        errorResult(e)
    }

    private fun toResult(rows: RowSet<Row>): Result {
        val r = Result()
        for (v in values(rows)) r.addObjRow(v)
        r.affected = rows.rowCount().toLong()
        return r
    }

    private fun errorResult(e: Exception): Result {
        failures.incrementAndGet()
        val r = Result()
        r.error = if (e is PgException) PgError(e.sqlState ?: "XX000", e.errorMessage ?: e.message ?: "")
        else PgError("08006", e.message ?: e.toString()) // connection lost, pool closed, ...
        return r
    }
}

/** Suspends until the Future completes; resumes on the thread that completed it (the connection's event loop). */
// Not named await(): Vert.x 5's Future has a member await() that BLOCKS the calling thread (and throws on an event
// loop), and a Kotlin member always wins over an extension of the same name. That silently turned every query into a
// blocking wait (lab: ~1,700 req/s ceiling; "Cannot be called on a Vert.x event-loop thread" on chained writes).
private suspend fun <T> Future<T>.coAwait(): T = suspendCoroutine { c ->
    onComplete { ar -> if (ar.succeeded()) c.resume(ar.result()) else c.resumeWithException(ar.cause()) }
}

/** "-c k=v -c k2=v2" -> startup parameters (Postgres takes any setting as a startup parameter). */
private fun sessionSettings(options: String): Map<String, String> {
    val m = LinkedHashMap<String, String>()
    val t = options.trim().split(Regex("\\s+"))
    var i = 0
    while (i < t.size) {
        val kv = if (t[i] == "-c" && i + 1 < t.size) t[++i] else t[i]
        val eq = kv.indexOf('=')
        if (eq > 0) m[kv.substring(0, eq)] = kv.substring(eq + 1)
        i++
    }
    return m
}

/** Our binary-encoded [params] (see [Params]) back to driver values, by the statement's declared parameter types. */
private fun tupleOf(stmt: WriteStmt, params: Params): Tuple {
    val b = params.out.buf
    var p = 0
    val t = Tuple.tuple()
    for (oid in stmt.paramOids) {
        val n = b.intBE(p)
        p += 4
        if (n < 0) {
            t.addValue(null)
            continue
        }
        when (oid) {
            Oid.INT8 -> t.addLong(b.longBE(p))
            Oid.INT4 -> t.addInteger(b.intBE(p))
            Oid.BOOL -> t.addBoolean(b[p].toInt() != 0)
            Oid.TEXT_ARRAY -> t.addValue(textArray(b, p))
            else -> t.addString(b.decodeToString(p, p + n))
        }
        p += n
    }
    return t
}

/** Binary text[] (1-D, no NULLs, as [Params.textArray] writes it) -> String[]. */
private fun textArray(b: ByteArray, at: Int): Array<String> {
    val ndim = b.intBE(at)
    if (ndim == 0) return emptyArray()
    val count = b.intBE(at + 12)
    var p = at + 20
    return Array(count) {
        val n = b.intBE(p)
        p += 4
        b.decodeToString(p, p + n).also { p += n }
    }
}

/** Postgres epoch (2000-01-01T00:00:00Z) in Unix seconds. */
private const val PG_EPOCH = 946_684_800L

/**
 * The driver's rows as object-mode values ([conduit.pg.Row.objs]): Int, Long, Boolean, String and String[] as the
 * driver decoded them (no copy, no re-encoding); timestamptz converted to microseconds since 2000 (what the renderer
 * takes); Short widened to Int.
 */
private fun values(rows: RowSet<Row>): List<Array<Any?>> {
    val out = ArrayList<Array<Any?>>(rows.size())
    for (row in rows) {
        val n = row.size()
        out.add(Array(n) { c ->
            when (val v = row.getValue(c)) {
                is OffsetDateTime -> (v.toEpochSecond() - PG_EPOCH) * 1_000_000L + v.nano / 1000
                is Short -> v.toInt()
                else -> v
            }
        })
    }
    return out
}
