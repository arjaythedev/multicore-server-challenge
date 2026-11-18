package conduit

import conduit.app.App
import conduit.auth.Jwt
import conduit.auth.Passwords
import conduit.db.Db
import conduit.db.DbConfig
import conduit.db.WritePool
import conduit.db.sleepNanos
import conduit.http.Gzip
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
    // 6 read + 4 write on the box. 2 write connections sat at ~100% waiting on the WAL flush and their backlog broke
    // p99 (4 keep up). Reads: at the 144k-user cap 6 connections beat 8 (5-minute holds, 2026-10-28: Postgres 139 vs
    // 151 us per request, p95 118 vs 125 ms, p99 210 vs 230): fewer backends compete for the 8 CPUs, batches grow.
    val readConns = envInt("DB_READ_CONNS", maxOf(2, cpus)) // native: 8 + 4 (6 read connections failed 156k on native in the lab)
    val writeConns = envInt("DB_WRITE_CONNS", maxOf(2, cpus / 2))
    // 2 on 8 CPUs: one thread tops out near 36 logins/s on the busy box (bcrypt ~28 ms/hash there) and at 156k lab users (130k on
    // the box) about 42/s arrive, so one thread lost most logins to the 10 s timeout. Idle threads cost nothing and extra
    // threads only take full batches, so this is a cap, not a fixed cost.
    val bcryptThreads = envInt("BCRYPT_THREADS", maxOf(2, (cpus + 3) / 4))
    // ~28 logins/s at 100k users: 400 ms fills 93% of 8-lane batches (mean 7.9 jobs). Logins are ~0.1% of requests,
    // so their latency can't move p95/p99.
    val bcryptWindow = envInt("BCRYPT_BATCH_MS", 400).toLong()
    // BCRYPT_THREADS_MAX (default half the CPUs, never below BCRYPT_THREADS): the workers above BCRYPT_THREADS start hashing
    // only once the oldest queued login has waited BCRYPT_EXTRA_AGE_MS (default: the batch window + 100 ms), i.e. when the base
    // threads cannot keep up (insurance for a login rate above ~36/s per base thread; idle they cost nothing).
    val bcryptExtra = maxOf(0, envInt("BCRYPT_THREADS_MAX", maxOf(bcryptThreads, (cpus + 1) / 2)) - bcryptThreads)
    val bcryptExtraAge = envInt("BCRYPT_EXTRA_AGE_MS", bcryptWindow.toInt() + 100).toLong()
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
    val gatherMs = envInt("READ_GATHER_MS", 30)
    // READ_GATHER_AUTO (default on, 0 = the fixed READ_GATHER_MS): the window is READ_GATHER_MS while the CPUs have room and widens
    // by READ_GATHER_STEP_MS a second up to READ_GATHER_MAX_MS while they are at least READ_GATHER_HIGH_PCT busy (back at READ_GATHER_LOW_PCT).
    val gatherMaxMs = if (envInt("READ_GATHER_AUTO", 1) != 0) envInt("READ_GATHER_MAX_MS", 100) else 0
    // READ_LIFO_MS (lab, 0 = off): adaptive LIFO once a kind's oldest read has waited this long (see DbConfig)
    val lifoMs = envInt("READ_LIFO_MS", 0)

    Jwt.init(secret)
    // HTTP_GZIP: 0 never, 1 always, unset = only while the network link is full (GZIP_ABOVE_MBPS, see http/Gzip.kt)
    Gzip.configure(getenv("HTTP_GZIP"), envInt("GZIP_ABOVE_MBPS", 100))
    // Adaptive bcrypt flush (default 4 lanes / 150 ms like the leaders; BCRYPT_FLUSH_MIN=0 = the plain BCRYPT_BATCH_MS window): BCRYPT_FLUSH_MIN lanes queued and the oldest
    // waiting BCRYPT_FLUSH_AGE_MS flushes a partial batch; BCRYPT_PRIO_LOAD reads queued for Postgres flushes at once.
    val bcryptPrioLoad = envInt("BCRYPT_PRIO_LOAD", 0)
    Passwords.loadProbe = { Db.readsQueued }
    Passwords.start(
        bcryptThreads, bcryptWindow, bcryptQueueMax, skipAbandoned = guard,
        flushMin = envInt("BCRYPT_FLUSH_MIN", 4), flushAgeMs = envInt("BCRYPT_FLUSH_AGE_MS", 150).toLong(),
        priorityLoad = bcryptPrioLoad, niceLevel = envInt("BCRYPT_NICE", 0),
        extraThreads = bcryptExtra, extraAgeMs = bcryptExtraAge,
    )
    val dbConfig = DbConfig.fromUrl(
        dbUrl, readConns, writeConns, options, readQueueMax, writeQueueMax, guard, gatherMicros = gatherMs * 1000,
        lifoMicros = lifoMs * 1000, gatherMaxMicros = gatherMaxMs * 1000,
        gatherStepMicros = envInt("READ_GATHER_STEP_MS", 10) * 1000, gatherHighPct = envInt("READ_GATHER_HIGH_PCT", 75),
        gatherLowPct = envInt("READ_GATHER_LOW_PCT", 60),
    )
    App.configure(
        Db.query(dbConfig, App.COLLATION_PROBE).firstOrNull(),
        appSortsTags = envInt("APP_SORT_TAGS", 1) != 0,
        shareReads = shareReads,
        shareMaxBatch = envInt("READ_MAX_BATCH", 1024),
        // READ_VIEWER_FLAGS (default on): shared lists check favorited/following once per viewer, not twice per row
        viewerFlags = envInt("READ_VIEWER_FLAGS", 1) != 0,
        // READ_FEED_MAX_BATCH (default 512, 0 = READ_MAX_BATCH): most feeds per execution. The feed statement decorates each distinct page article once (READ_FEED_SHARE)
        // and its hub/count work is per batch, so bigger batches cost less per feed (EXPLAIN, per feed: 334 us at 64, 233 us at 200). Lab, 180k users: cap 64 collapsed (p95 6 s,
        // 1.7% timeouts), 192 and 1024 held the whole load (steady-state p95 130-143 ms, p99 184-199 ms). The auto gather window sends bigger feed batches: at 60 ms 512 measured 74-75 us per request against 78 with 192.
        feedMaxBatch = envInt("READ_FEED_MAX_BATCH", 512),
        // READ_FEED_HEAVY (default on; 0 = the plain capped count): skip the capped feed count for viewers who follow an author with 1000+ articles
        feedHeavy = envInt("READ_FEED_HEAVY", 1) != 0,
        // READ_FEED_FLOOR (default on, needs READ_FEED_HEAVY; 0 = off): per-batch floor ids of the shared hub followees bound the page probes
        feedFloor = envInt("READ_FEED_FLOOR", 1) != 0,
        // READ_FEED_SHARE (default on, needs READ_FEED_HEAVY and READ_FEED_FLOOR; 0 = decorate every page row): each distinct page article of a feed batch is decorated once
        feedShared = envInt("READ_FEED_SHARE", 1) != 0,
        // READ_FEED_ROWS (default on, needs READ_FEED_SHARE; 0 = join every page row to its article's columns): the feed statement sends each distinct article of the batch once and the page as (count, id) rows
        feedRows = envInt("READ_FEED_ROWS", 1) != 0,
        globalWin = envInt("READ_GLOBAL_WIN", 1) != 0,
        // READ_SHARED_ROWS (default on, needs READ_SHARE; 0 = fan every row out to every request): comments and the global, tag and author lists send each distinct thread or page once
        sharedRows = envInt("READ_SHARED_ROWS", 1) != 0,
    )
    // SQL_PRINT=1 (diagnostics, .tmp/lab/explain.sh): prints every read statement as "sql<TAB>name<TAB>sql" and exits
    if (envInt("SQL_PRINT", 0) != 0) {
        for (k in App.reads) println("sql\t${k.name}\t${k.sql}")
        return
    }
    WritePool.implicitTx = envInt("WRITE_IMPLICIT_TX", 1) != 0
    Db.start(dbConfig, App.reads, App.writes)
    startHttpServer(host, port, httpThreads, HttpEngine { ex -> App.handle(ex) })
    println(
        "conduit: listening on $host:$port (cpus=$cpus http=$httpThreads db=$readConns+$writeConns " +
            "bcrypt=$bcryptThreads${if (bcryptExtra > 0) "+$bcryptExtra after ${bcryptExtraAge}ms" else ""}; tags sorted by ${App.tagOrder}; reads ${App.readMode}, gather $gatherMs ms${if (gatherMaxMs > gatherMs) "..$gatherMaxMs ms (auto)" else ""}${if (lifoMs > 0) ", LIFO after $lifoMs ms" else ""}; " +
            "overload guard ${if (guard) "on, queue caps $readQueueMax/$writeQueueMax/$bcryptQueueMax" else "off"}; " +
            "gzip ${Gzip.description}; " +
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
