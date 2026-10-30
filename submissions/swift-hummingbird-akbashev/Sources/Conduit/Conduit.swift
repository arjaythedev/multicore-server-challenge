// Conduit (RealWorld) API server in Swift + Hummingbird, for the multicore server challenge (SPEC.md).
import Foundation
import HTTPTypes
import Hummingbird
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
        // Running plus waiting hashes; a cost-10 hash is about 50 ms, so the default is about 2 s of queued work.
        let bcryptQueue = Int(envOr("BCRYPT_QUEUE", "")) ?? 40 * bcryptThreads
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
        let bcrypt = ThreadPoolExecutor(threads: bcryptThreads, limit: bcryptQueue)
        // Read batching: each lane holds one pooled connection, so DB_POOL_SIZE must leave room for writes and logins.
        let reads: ReadBatcher? = envOr("READ_BATCHING", "1") == "0" ? nil : ReadBatcher(db: db, settings: .init(
            lanes: Int(envOr("READ_LANES", "")) ?? System.coreCount,
            window: .milliseconds(Int(envOr("READ_WINDOW_MS", "")) ?? 5),
            minBatch: Int(envOr("READ_BATCH_MIN", "")) ?? 32,
            maxBatch: Int(envOr("READ_BATCH_MAX", "")) ?? 1024
        ))
        let app = App(db: db, signer: JWTSigner(secret: jwtSecret), bcrypt: bcrypt, reads: reads)

        let server = Application(
            router: app.router(),
            server: .http1(configuration: .init(idleTimeout: .seconds(75))),
            // Front: direct, so this socket takes every user's connection: a backlog deep enough for a ramp (the
            // kernel caps it at net.core.somaxconn, 65535 on the box) instead of Hummingbird's default 256.
            configuration: .init(address: .hostname(host, port: port), backlog: 65535),
            logger: App.quietLogger
        )

        // One ServiceGroup owns everything long-lived. It runs them until SIGTERM or SIGINT, then shuts them down in
        // reverse order: the HTTP server first (in-flight requests finish), then the read lanes, the Postgres pool and
        // the bcrypt threads.
        let services = ServiceGroup(configuration: .init(
            services: [bcrypt, db] + (reads.map { [$0] } ?? []) + [server],
            gracefulShutdownSignals: [.sigterm, .sigint],
            logger: logger
        ))
        logger.info("""
            conduit (swift/hummingbird) listening on \(host):\(port), pool \(poolSize), \
            bcrypt threads \(bcryptThreads) (queue \(bcryptQueue)), \
            global executor: \(nioExecutor ? "NIO event loops" : "Swift cooperative pool")
            """)
        try await services.run()
    }

    private static func fail(_ message: Logger.Message) -> Never {
        logger.critical(message)
        exit(1)
    }
}

extension App {
    /// The routes. Built in a nonisolated method so no handler closure can pick up the main actor from `main()`.
    func router() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)
        router.post("api/users") { request, ctx in await handle { try await register(request, ctx) } }
        router.post("api/users/login") { request, ctx in await handle { try await login(request, ctx) } }
        router.get("api/user") { request, ctx in await handle { try await currentUser(request, ctx) } }
        router.put("api/user") { request, ctx in await handle { try await updateUser(request, ctx) } }

        router.get("api/profiles/:username") { request, ctx in await handle { try await getProfile(request, ctx) } }
        router.post("api/profiles/:username/follow") { request, ctx in await handle { try await follow(request, ctx, follow: true) } }
        router.delete("api/profiles/:username/follow") { request, ctx in await handle { try await follow(request, ctx, follow: false) } }

        router.get("api/articles") { request, ctx in await handle { try await listArticles(request, ctx) } }
        router.get("api/articles/feed") { request, ctx in await handle { try await feed(request, ctx) } }
        router.post("api/articles") { request, ctx in await handle { try await createArticle(request, ctx) } }
        router.get("api/articles/:slug") { request, ctx in await handle { try await getArticle(request, ctx) } }
        router.put("api/articles/:slug") { request, ctx in await handle { try await updateArticleHandler(request, ctx) } }
        router.delete("api/articles/:slug") { request, ctx in await handle { try await deleteArticle(request, ctx) } }
        router.post("api/articles/:slug/favorite") { request, ctx in await handle { try await favorite(request, ctx, fav: true) } }
        router.delete("api/articles/:slug/favorite") { request, ctx in await handle { try await favorite(request, ctx, fav: false) } }
        router.get("api/articles/:slug/comments") { request, ctx in await handle { try await listComments(request, ctx) } }
        router.post("api/articles/:slug/comments") { request, ctx in await handle { try await createComment(request, ctx) } }
        router.delete("api/articles/:slug/comments/:id") { request, ctx in await handle { try await deleteComment(request, ctx) } }

        router.get("api/tags") { request, ctx in await handle { try await tags(request, ctx) } }

        // Anything else (unknown path, or a known path with another method) is a JSON 404.
        for method: HTTPRequest.Method in [.get, .post, .put, .delete, .patch, .head, .options, .trace, .connect] {
            router.on("**", method: method) { _, _ in errorResponse(.notFound, "not found") }
        }
        return router
    }
}
