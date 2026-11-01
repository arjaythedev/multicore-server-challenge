package conduit

import conduit.app.App
import conduit.auth.Jwt
import conduit.auth.Passwords
import conduit.db.Db
import conduit.db.DbConfig
import conduit.db.sleepNanos
import conduit.http.HttpEngine
import conduit.platform.Monitor
import conduit.platform.cpuCount
import conduit.platform.getenv
import conduit.platform.parkForever
import conduit.platform.platformInit
import conduit.platform.startHttpServer
import conduit.platform.startThread

// Session settings sent in the startup packet (no extra round trip): generic plans (no planning per execution),
// no JIT or parallel workers (pure overhead for small queries), no Memoize (in a batched statement it could hand one
// request a row another request's lookup fetched).
private const val DEFAULT_OPTIONS =
    "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0 -c enable_memoize=off"

private fun envInt(name: String, default: Int): Int = getenv(name)?.trim()?.toIntOrNull() ?: default

fun main() {
    val platform = platformInit()
    val dbUrl = getenv("DATABASE_URL") ?: error("DATABASE_URL is required")
    val secret = getenv("JWT_SECRET") ?: error("JWT_SECRET is required")
    val host = getenv("HOST") ?: "127.0.0.1"
    val port = envInt("PORT", 3000)

    // Sizing for the box's 8 cores shared with Postgres: few runnable threads, few Postgres backends.
    val cpus = cpuCount()
    val httpThreads = envInt("HTTP_THREADS", maxOf(1, (cpus + 3) / 4))
    // 8 read + 4 write on the box: with 6 + 2 the write connections sat at ~100% waiting on the WAL flush and their
    // backlog broke p99, and Postgres had idle cores while the read connections queued (lab, 2026-10-28)
    // 6 read: at the 144k-user cap 6 beat 8 (5-minute holds, 2026-10-28: Postgres 139 vs 151 us per request, p95 118 vs
    // 125 ms): fewer backends compete for the 8 CPUs. With DB_DRIVER=vertx: the pool has read + write connections.
    val readConns = envInt("DB_READ_CONNS", maxOf(2, cpus * 3 / 4))
    val writeConns = envInt("DB_WRITE_CONNS", maxOf(2, cpus / 2))
    // 3 bcrypt threads on 8 CPUs (still cost 10 per hash): this stack runs ~25 threads, and one bcrypt thread got ~1/4
    // core at the top: ~20 hashes/s for ~40 needed, logins queued 5 s (lab, 144k users); with 3 the wait was 0.16 s
    val bcryptThreads = envInt("BCRYPT_THREADS", maxOf(1, (cpus * 3 + 7) / 8))
    // ~28 logins/s at 100k users: 400 ms fills 93% of 8-lane batches (mean 7.9 jobs). Logins are ~0.1% of requests,
    // so their latency can't move p95/p99.
    val bcryptWindow = envInt("BCRYPT_BATCH_MS", 400).toLong()
    val options = getenv("DB_OPTIONS") ?: DEFAULT_OPTIONS
    // Overload guard (OVERLOAD_GUARD=0 turns it off): queued work whose client has given up is dropped unrun, and a
    // full read, write or bcrypt queue answers 503 at once (0 = no cap). The caps sit far above what a load that
    // passes ever queues; they bound memory for the loads that don't.
    val guard = envInt("OVERLOAD_GUARD", 1) != 0
    val readQueueMax = if (guard) envInt("READ_QUEUE_MAX", 65536) else 0
    val writeQueueMax = if (guard) envInt("WRITE_QUEUE_MAX", 8192) else 0
    val bcryptQueueMax = if (guard) envInt("BCRYPT_QUEUE_MAX", 2048) else 0
    // READ_SHARE (default on): the requests of a batch share their counts, pages and article columns (ReadShare in
    // app/Sql.kt), up to READ_MAX_BATCH per execution. READ_GATHER_MS: a kind waits this long for company before it is
    // sent (0: as soon as a connection is free). Big batches are what make sharing pay: in the lab, 20 ms and sharing
    // took Postgres from 170 to 127 us per request at 120k users (lab/reports/omarchy-20261027.md).
    val shareReads = envInt("READ_SHARE", 1) != 0
    val gatherMs = envInt("READ_GATHER_MS", 20)

    Jwt.init(secret)
    // BCRYPT_NICE: the bcrypt threads' scheduling priority (Linux nice; our own threads, rule 12). Every hash is still
    // cost 10. 0 here (the raw build uses 10): this stack leaves no CPU slack at the top, and at nice 10 logins starved
    // (lab, 144k users: bcrypt queue wait 5-6 s, ~19,000 timeouts, vs 0.5 s for the raw build)
    Passwords.start(bcryptThreads, bcryptWindow, bcryptQueueMax, skipAbandoned = guard, nice = envInt("BCRYPT_NICE", 0))
    val dbConfig = DbConfig.fromUrl(
        dbUrl, readConns, writeConns, options, readQueueMax, writeQueueMax, guard, gatherMicros = gatherMs * 1000,
    )
    App.configure(
        Db.query(dbConfig, App.COLLATION_PROBE).firstOrNull(),
        appSortsTags = envInt("APP_SORT_TAGS", 1) != 0,
        shareReads = shareReads,
        shareMaxBatch = envInt("READ_MAX_BATCH", 256),
        // READ_VIEWER_FLAGS (default on): shared lists check favorited/following once per viewer, not twice per row
        viewerFlags = envInt("READ_VIEWER_FLAGS", 1) != 0,
        // the Vert.x driver gets timestamps as float8 epoch seconds (one Double instead of four java.time objects)
        // (VERTX_EPOCH_TS=0: plain timestamptz columns, for A/B)
        epochTimestamps = getenv("DB_DRIVER")?.trim() == "vertx" && envInt("VERTX_EPOCH_TS", 1) != 0,
        // READ_FEED_MAX_BATCH (default 32, 0 = READ_MAX_BATCH): feeds share nothing, so they leave in small batches
        feedMaxBatch = envInt("READ_FEED_MAX_BATCH", 32),
    )
    // SQL_PRINT=1 (diagnostics, .tmp/lab/explain.sh): prints every read statement as "sql<TAB>name<TAB>sql" and exits
    if (envInt("SQL_PRINT", 0) != 0) {
        for (k in App.reads) println("sql\t${k.name}\t${k.sql}")
        return
    }
    // DB_DRIVER=vertx (JVM; start.sh's default): the Vert.x reactive Postgres client instead of our wire client (no
    // batching / group commit). Unset, empty or "own": our client.
    val driver = getenv("DB_DRIVER")?.trim()?.takeUnless { it == "own" } ?: ""
    Db.start(dbConfig, App.reads, App.writes, driver)
    startHttpServer(host, port, httpThreads, HttpEngine { ex -> App.handle(ex) })
    println(
        "conduit: listening on $host:$port (cpus=$cpus http=$httpThreads db=${driver.ifEmpty { "own" }} " +
            "$readConns+$writeConns " +
            "bcrypt=$bcryptThreads; tags sorted by ${App.tagOrder}; reads ${App.readMode}, gather $gatherMs ms; " +
            "overload guard ${if (guard) "on, queue caps $readQueueMax/$writeQueueMax/$bcryptQueueMax" else "off"}; " +
            "$platform)",
    )
    // DB_STATS_S=<seconds> (diagnostics): logs batching statistics periodically.
    val statsEvery = envInt("DB_STATS_S", 0)
    if (statsEvery > 0) {
        startThread("db-stats") {
            val m = Monitor()
            while (true) {
                sleepNanos(m, statsEvery * 1_000_000_000L)
                println(Db.stats())
                println("interval ${statsEvery}s: " + Db.intervalStats(statsEvery * 1_000_000_000L) + " || " +
                    Passwords.intervalStats())
            }
        }
    }
    parkForever()
}
