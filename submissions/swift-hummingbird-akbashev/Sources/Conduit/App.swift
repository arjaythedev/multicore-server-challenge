// App state, the bcrypt executor and Postgres helpers.
import Logging
import NIOPosix
import PostgresNIO
import ServiceLifecycle
import Synchronization

struct App: Sendable {
    let db: PostgresClient
    let signer: JWTSigner
    let bcrypt: BcryptWorkers
    /// Batched reads (Reads.swift); nil runs each read as its own statement (READ_BATCHING=0).
    let reads: ReadBatcher?
    /// Group-committed writes (Writes.swift).
    let writes: WriteBatcher

    /// For Hummingbird's per-request loggers and postgres-nio's per-query ones, which nothing here reads: both set
    /// metadata on every request or statement, and swift-log's StreamLogHandler re-renders its metadata string on each
    /// set, logged or not. Our own messages use `logger`.
    static let queryLogger = Logger(label: "conduit.quiet", factory: { _ in SwiftLogNoOpLogHandler() })
    static let logger = Logger(label: "conduit.app")
}

/// A TaskExecutor on its own fixed-size thread pool, for the bcrypt workers: its size caps how many cores a burst of
/// logins can take from the event loops.
final class ThreadPoolExecutor: TaskExecutor {
    private let pool: NIOThreadPool

    init(threads: Int) {
        pool = NIOThreadPool(numberOfThreads: threads)
        pool.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        // The work item's state is ignored on purpose: a pool that is already shutting down still runs the job (on
        // the submitting thread), so no task is ever left suspended forever.
        pool.submit { _ in job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    func shutdown() async throws {
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
