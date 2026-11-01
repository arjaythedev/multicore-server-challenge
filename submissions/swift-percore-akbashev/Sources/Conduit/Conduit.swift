// Conduit (RealWorld) API server in Swift, on event loops of its own, for the multicore server challenge (SPEC.md).
import Foundation
#if canImport(Glibc)
import Glibc
#endif

@main
struct Conduit {
    static let logger = Logger(label: "conduit")

    static func main() async throws {
        let env = ProcessInfo.processInfo.environment

        #if os(Linux)
        // SCHED_BATCH for this thread, so for every thread started after it (no privileges needed). Ours wake up
        // constantly (a request, a Postgres reply), and under the default policy each wakeup can preempt a busy
        // Postgres backend on the same cores; batch threads get the same CPU share without cutting in. SCHED_BATCH=0: off.
        if env["SCHED_BATCH"] != "0" {
            let schedBatch: Int32 = 3 // SCHED_BATCH in <sched.h>, only defined there under _GNU_SOURCE
            var param = sched_param()
            if sched_setscheduler(0, schedBatch, &param) != 0 { logger.warning("could not switch to SCHED_BATCH") }
        }
        #endif

        // A write to a socket the peer has closed fails with EPIPE instead of killing the process.
        signal(SIGPIPE, SIG_IGN)

        func envOr(_ name: String, _ fallback: String) -> String {
            guard let v = env[name], !v.isEmpty else { return fallback }
            return v
        }

        guard let dbURLString = env["DATABASE_URL"], !dbURLString.isEmpty,
              let jwtSecret = env["JWT_SECRET"], !jwtSecret.isEmpty else {
            fail("DATABASE_URL and JWT_SECRET are required")
        }
        guard let dbURL = URL(string: dbURLString), let dbHost = dbURL.host else {
            fail("cannot parse DATABASE_URL: \(dbURLString)")
        }
        let poolSize = Int(envOr("DB_POOL_SIZE", "10")) ?? 10
        let bcryptThreads = Int(envOr("BCRYPT_THREADS", "")) ?? max(1, System.coreCount / 2)
        // Running plus waiting hashes: about 2 s of queued work at the default.
        let bcryptQueue = Int(envOr("BCRYPT_QUEUE", "")) ?? 40 * bcryptThreads
        let calibration = BcryptWorkers.calibrate()
        let bcryptLanes = Int(envOr("BCRYPT_LANES", "")) ?? calibration.lanes
        let host = envOr("HOST", "127.0.0.1")
        let port = Int(envOr("PORT", "3000")) ?? 3000

        // Session settings on our own connections only (startup parameters; nothing server-wide). The box's Postgres
        // runs with JIT and parallel query on, and both cost more than they save on statements that take well under
        // a millisecond: a JIT compile is milliseconds, and a parallel plan starts worker processes. The read batches
        // take arrays, and under the default plan_cache_mode Postgres keeps re-planning those on every execution,
        // because a custom plan always looks cheaper for the arrays at hand.
        let dbConfig = PGConfig(
            host: dbHost,
            port: dbURL.port ?? 5432,
            user: dbURL.user ?? "conduit",
            password: dbURL.password,
            database: dbURL.path.split(separator: "/").last.map(String.init) ?? "conduit",
            parameters: [("jit", "off"), ("max_parallel_workers_per_gather", "0"), ("plan_cache_mode", "force_generic_plan")]
        )
        if env["PG_SELFTEST"] == "1" {
            try await PGSelfTest.run(dbConfig)
            exit(0)
        }
        // DB_POOL_SIZE is every connection we open: one per write lane, and the rest split between the read lanes.
        let writeLanes = max(1, Int(envOr("WRITE_LANES", "")) ?? 4)
        let readLanes = max(1, Int(envOr("READ_LANES", "")) ?? System.coreCount)
        let readConnections = max(1, Int(envOr("READ_CONNECTIONS", "")) ?? (poolSize - writeLanes) / readLanes)
        let bcrypt = BcryptWorkers(threads: bcryptThreads, lanes: bcryptLanes,
                                   window: .milliseconds(Int(envOr("BCRYPT_WINDOW_MS", "")) ?? 200), limit: bcryptQueue)
        let reads = ReadBatcher(config: dbConfig, settings: .init(
            lanes: readLanes,
            connections: readConnections,
            window: .milliseconds(Int(envOr("READ_WINDOW_MS", "")) ?? 30),
            maxBatch: Int(envOr("READ_BATCH_MAX", "")) ?? 1024
        ))
        let signer = JWTSigner(secret: jwtSecret)
        let writes = WriteBatcher(config: dbConfig, signer: signer, settings: .init(
            lanes: writeLanes,
            maxGroup: Int(envOr("WRITE_GROUP_MAX", "")) ?? 256
        ))
        let app = App(signer: signer, bcrypt: bcrypt, reads: reads, writes: writes)

        let server = HTTPServer(app: app, host: host, port: port)

        // Everything long-lived runs until SIGTERM or SIGINT (Lifecycle.swift), then stops in reverse order: the HTTP
        // server first (in-flight requests finish), then the write and read lanes (and their Postgres connections) and
        // the bcrypt threads.
        logger.info("""
            conduit (swift): \(readLanes) read lanes × \(readConnections) connections, \(writeLanes) write lanes, \
            bcrypt threads \(bcryptThreads) (queue \(bcryptQueue), \(bcrypt.lanes) in lockstep; cost 6 per hash at widths 1-6: \
            \(calibration.perHash.map { "\($0.components.attoseconds / 1_000_000_000_000) µs" }.joined(separator: ", "))), \
            \(Loop.all.count) loops
            """)
        try await Services.run([bcrypt, reads, writes, server], stoppingOn: [SIGTERM, SIGINT])
    }

    private static func fail(_ message: String) -> Never {
        logger.critical(message)
        exit(1)
    }
}
