// App state and Postgres helpers.
import Crypto
import Foundation
import Hummingbird
import HummingbirdCore
import Logging
import PostgresNIO

struct App: Sendable {
    let db: PostgresClient
    let secret: SymmetricKey

    static let queryLogger = Logger(label: "conduit.query")

    // bcrypt (cost 10) is deliberately CPU-bound: run it off the event loops.
    private static let bcryptQueue = DispatchQueue(label: "conduit.bcrypt", qos: .userInitiated, attributes: .concurrent)

    func bcryptHash(_ password: String) async throws -> String {
        guard password.utf8.count <= 72 else { throw ApiError(.unprocessableContent, "password is too long") }
        return try await withCheckedThrowingContinuation { cont in
            App.bcryptQueue.async {
                do {
                    cont.resume(returning: try Bcrypt.hash(password))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    func bcryptVerify(_ password: String, hash: String) async -> Bool {
        guard password.utf8.count <= 72 else { return false }
        return await withCheckedContinuation { cont in
            App.bcryptQueue.async {
                cont.resume(returning: (try? Bcrypt.verify(password, hash: hash)) ?? false)
            }
        }
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
        let rows = try await db.query(PostgresQuery(unsafeSQL: sql, binds: binds))
        for try await row in rows {
            return row
        }
        return nil
    }

    /// Run a query and collect all rows.
    func queryAll(_ sql: String, _ values: [any PostgresEncodable] = []) async throws -> [PostgresRow] {
        let rows = try await db.query(makeQuery(sql, values))
        var out = [PostgresRow]()
        for try await row in rows { out.append(row) }
        return out
    }

    /// Run a statement, ignoring its result.
    func exec(_ sql: String, _ values: [any PostgresEncodable] = []) async throws {
        _ = try await db.query(makeQuery(sql, values))
    }

    func exec(_ sql: String, binds: PostgresBindings) async throws {
        _ = try await db.query(PostgresQuery(unsafeSQL: sql, binds: binds))
    }

    /// Run a block inside a transaction on one connection; rolls back on error.
    func transaction<T: Sendable>(_ block: (PostgresConnection) async throws -> T) async throws -> T {
        try await db.withConnection { conn in
            do {
                _ = try await conn.query(makeQuery("BEGIN", []), logger: App.queryLogger)
                let result = try await block(conn)
                _ = try await conn.query(makeQuery("COMMIT", []), logger: App.queryLogger)
                return result
            } catch {
                _ = try? await conn.query(makeQuery("ROLLBACK", []), logger: App.queryLogger)
                throw error
            }
        }
    }
}
