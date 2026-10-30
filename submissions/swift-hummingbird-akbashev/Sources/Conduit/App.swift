// App state, the bcrypt executor and Postgres helpers.
import HTTPTypes
import HummingbirdBcrypt
import Logging
import NIOPosix
import PostgresNIO
import ServiceLifecycle
import Synchronization

struct App: Sendable {
    let db: PostgresClient
    let signer: JWTSigner
    let bcrypt: ThreadPoolExecutor
    /// Batched reads (Reads.swift); nil runs each read as its own statement (READ_BATCHING=0).
    let reads: ReadBatcher?

    /// For Hummingbird's per-request loggers and postgres-nio's per-query ones, which nothing here reads: both set
    /// metadata on every request or statement, and swift-log's StreamLogHandler re-renders its metadata string on each
    /// set, logged or not (2 allocations per request, plus the formatting). Our own messages use `logger`.
    static let quietLogger = Logger(label: "conduit.quiet", factory: { _ in SwiftLogNoOpLogHandler() })
    static let queryLogger = quietLogger
    static let logger = Logger(label: "conduit.app")

    // bcrypt (cost 10) is deliberately CPU-bound, so it must never run on an event loop. The request's own task moves
    // onto the bcrypt threads for the hash and comes back afterwards: the @concurrent function hops to the task's
    // preferred executor on entry, which withTaskExecutorPreference has set to those threads. Past the executor's
    // admission limit a login or sign-up is a 503 straight away, rather than a wait longer than any client will give it.

    func bcryptHash(_ password: String) async throws -> String {
        guard password.utf8.count <= 72 else { throw ApiError(.unprocessableContent, "password is too long") }
        guard bcrypt.enter() else { throw ApiError(.serviceUnavailable, "server busy") }
        defer { bcrypt.leave() }
        return await withTaskExecutorPreference(bcrypt) { await App.hash(password) }
    }

    func bcryptVerify(_ password: String, hash: String) async throws -> Bool {
        guard password.utf8.count <= 72 else { return false }
        guard bcrypt.enter() else { throw ApiError(.serviceUnavailable, "server busy") }
        defer { bcrypt.leave() }
        return await withTaskExecutorPreference(bcrypt) { await App.verify(password, hash: hash) }
    }

    @concurrent private static func hash(_ password: String) async -> String {
        Bcrypt.hash(password, cost: 10) // SPEC.md: cost 10 (HummingbirdBcrypt defaults to 12)
    }

    @concurrent private static func verify(_ password: String, hash: String) async -> Bool {
        Bcrypt.verify(password, hash: hash)
    }
}

/// A TaskExecutor on its own fixed-size thread pool. Its size caps how many cores a burst of logins can take from the
/// event loops. `enter()` caps the work running or waiting at `limit`, so the queue can't grow without bound under
/// overload. A Service, so the ServiceGroup stops its threads on shutdown.
final class ThreadPoolExecutor: TaskExecutor, Service {
    private let pool: NIOThreadPool
    private let limit: Int
    private let admitted = Atomic<Int>(0)

    init(threads: Int, limit: Int) {
        pool = NIOThreadPool(numberOfThreads: threads)
        self.limit = limit
        pool.start()
    }

    /// Admits one more piece of work unless `limit` are already running or waiting; each `true` needs a `leave()`.
    func enter() -> Bool {
        if admitted.wrappingAdd(1, ordering: .relaxed).newValue <= limit { return true }
        admitted.wrappingSubtract(1, ordering: .relaxed)
        return false
    }

    func leave() {
        admitted.wrappingSubtract(1, ordering: .relaxed)
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        // The work item's state is ignored on purpose: a pool that is already shutting down still runs the job (on
        // the submitting thread), so no task is ever left suspended forever.
        pool.submit { _ in job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    func run() async throws {
        try? await gracefulShutdown()
        try await pool.shutdownGracefully()
    }
}

// ---------- query helpers ----------

func makeQuery(_ sql: String, _ values: [any PostgresEncodable]) throws -> PostgresQuery {
    var binds = PostgresBindings(capacity: values.count)
    for v in values { try binds.append(v) }
    return PostgresQuery(unsafeSQL: sql, binds: binds)
}

extension App {
    /// Run a query, returning the first row (or nil).
    func queryRow(_ sql: String, _ values: [any PostgresEncodable] = []) async throws -> PostgresRow? {
        try await queryRow(sql, binds: makeQuery(sql, values).binds)
    }

    @_disfavoredOverload
    func queryRow(_ sql: String, binds: PostgresBindings) async throws -> PostgresRow? {
        let rows = try await db.query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: App.queryLogger)
        for try await row in rows {
            return row
        }
        return nil
    }

    /// Run a statement, ignoring its result.
    func exec(_ sql: String, _ values: [any PostgresEncodable] = []) async throws {
        _ = try await db.query(makeQuery(sql, values), logger: App.queryLogger)
    }

    func exec(_ sql: String, binds: PostgresBindings) async throws {
        _ = try await db.query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: App.queryLogger)
    }
}
