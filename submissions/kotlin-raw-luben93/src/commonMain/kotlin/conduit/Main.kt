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
    val readConns = envInt("DB_READ_CONNS", maxOf(2, (cpus * 3 + 3) / 4))
    val writeConns = envInt("DB_WRITE_CONNS", maxOf(1, (cpus + 3) / 4))
    val bcryptThreads = envInt("BCRYPT_THREADS", maxOf(1, (cpus + 7) / 8))
    // ~28 logins/s at 100k users: 400 ms fills 93% of 8-lane batches (mean 7.9 jobs). Logins are ~0.1% of requests,
    // so their latency can't move p95/p99.
    val bcryptWindow = envInt("BCRYPT_BATCH_MS", 400).toLong()
    val options = getenv("DB_OPTIONS") ?: DEFAULT_OPTIONS

    Jwt.init(secret)
    Passwords.start(bcryptThreads, bcryptWindow)
    val dbConfig = DbConfig.fromUrl(dbUrl, readConns, writeConns, options)
    App.configure(Db.query(dbConfig, App.COLLATION_PROBE).firstOrNull(), appSortsTags = envInt("APP_SORT_TAGS", 1) != 0)
    Db.start(dbConfig, App.reads, App.writes)
    startHttpServer(host, port, httpThreads, HttpEngine { ex -> App.handle(ex) })
    println(
        "conduit: listening on $host:$port (cpus=$cpus http=$httpThreads db=$readConns+$writeConns " +
            "bcrypt=$bcryptThreads; tags sorted by ${App.tagOrder}; $platform)",
    )
    // DB_STATS_S=<seconds> (diagnostics): logs batching statistics periodically.
    val statsEvery = envInt("DB_STATS_S", 0)
    if (statsEvery > 0) {
        startThread("db-stats") {
            val m = Monitor()
            while (true) {
                sleepNanos(m, statsEvery * 1_000_000_000L)
                println(Db.stats())
            }
        }
    }
    parkForever()
}
