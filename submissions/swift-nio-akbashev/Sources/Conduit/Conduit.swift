// Conduit (RealWorld) API server in Swift on SwiftNIO, for the multicore server challenge (SPEC.md).
import Foundation
import Logging
import NIOCore
import NIOPosix
import PostgresNIO
import ServiceLifecycle
import UnixSignals
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

        // Opt-in (NIO_GLOBAL_EXECUTOR=1): NIO's event loops become Swift Concurrency's global executor, so handlers
        // and the Postgres client share one thread per core, and a task resumed by a Postgres reply carries on on the
        // event loop that read it instead of hopping to Swift's cooperative pool. Off by default: it cost 10-30% more
        // CPU per request on macOS, and on Linux about a third of the throughput (tasks stay on the loop that resumed
        // them, so the read lanes' work crowds onto a few loops). It also needs a dynamic Swift runtime: NIO finds the
        // hook with dlsym, which can't see it under build.sh's --static-swift-stdlib. Must run first, on the main thread.
        var nioExecutor = false
        if env["NIO_GLOBAL_EXECUTOR"] == "1" {
            nioExecutor = NIOSingletons.unsafeTryInstallSingletonPosixEventLoopGroupAsConcurrencyGlobalExecutor()
            if !nioExecutor { logger.warning("could not install NIO's event loops as the global executor") }
        }

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

        var dbConfig = PostgresClient.Configuration(
            host: dbHost,
            port: dbURL.port ?? 5432,
            username: dbURL.user ?? "conduit",
            password: dbURL.password,
            database: dbURL.path.split(separator: "/").last.map(String.init),
            tls: .disable
        )
        dbConfig.options.maximumConnections = poolSize
        // Session settings on our own connections only (startup parameters; nothing server-wide). The box's Postgres
        // runs with JIT and parallel query on, and both cost more than they save on statements that take well under
        // a millisecond: a JIT compile is milliseconds, and a parallel plan starts worker processes. The read batches
        // take arrays, and under the default plan_cache_mode Postgres keeps re-planning those on every execution,
        // because a custom plan always looks cheaper for the arrays at hand.
        dbConfig.options.additionalStartupParameters = [
            ("jit", "off"),
            ("max_parallel_workers_per_gather", "0"),
            ("plan_cache_mode", "force_generic_plan"),
        ]
        let db = PostgresClient(configuration: dbConfig)
        let bcrypt = BcryptWorkers(threads: bcryptThreads, lanes: bcryptLanes,
                                   window: .milliseconds(Int(envOr("BCRYPT_WINDOW_MS", "")) ?? 200), limit: bcryptQueue)
        // Read batching: each lane holds one pooled connection, so DB_POOL_SIZE must leave room for writes and logins.
        let reads: ReadBatcher? = envOr("READ_BATCHING", "1") == "0" ? nil : ReadBatcher(db: db, settings: .init(
            lanes: Int(envOr("READ_LANES", "")) ?? System.coreCount,
            window: .milliseconds(Int(envOr("READ_WINDOW_MS", "")) ?? 5),
            minBatch: Int(envOr("READ_BATCH_MIN", "")) ?? 32,
            maxBatch: Int(envOr("READ_BATCH_MAX", "")) ?? 1024
        ))
        let signer = JWTSigner(secret: jwtSecret)
        // Group commit: each write lane holds one pooled connection. WRITE_GROUPING=0: a transaction per write.
        let writes = WriteBatcher(db: db, signer: signer, settings: .init(
            lanes: envOr("WRITE_GROUPING", "1") == "0" ? 0 : Int(envOr("WRITE_LANES", "")) ?? 1,
            maxGroup: Int(envOr("WRITE_GROUP_MAX", "")) ?? 256
        ))
        let app = App(db: db, signer: signer, bcrypt: bcrypt, reads: reads, writes: writes)

        let server = HTTPServer(app: app, host: host, port: port)

        // One ServiceGroup owns everything long-lived. It runs them until SIGTERM or SIGINT, then shuts them down in
        // reverse order: the HTTP server first (in-flight requests finish), then the read lanes, the Postgres pool and
        // the bcrypt threads.
        let services = ServiceGroup(configuration: .init(
            services: [bcrypt, db] + (reads.map { [$0] } ?? []) + [writes, server],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        ))
        logger.info("""
            conduit (swift/nio): pool \(poolSize), \
            bcrypt threads \(bcryptThreads) (queue \(bcryptQueue), \(bcrypt.lanes) in lockstep; cost 6 per hash at widths 1-6: \
            \(calibration.perHash.map { "\($0.components.attoseconds / 1_000_000_000_000) µs" }.joined(separator: ", "))), \
            global executor: \(nioExecutor ? "NIO event loops" : "Swift cooperative pool")
            """)
        try await services.run()
    }

    private static func fail(_ message: Logger.Message) -> Never {
        logger.critical(message)
        exit(1)
    }
}
