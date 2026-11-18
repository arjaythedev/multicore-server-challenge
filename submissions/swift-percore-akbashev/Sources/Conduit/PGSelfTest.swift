// PG_SELFTEST=1: exercises the Postgres client against DATABASE_URL and exits. A development check, not part of serving.
import Foundation

enum UnnestSQL: PGPrepared {
    static let name = "selftest_unnest"
    static let sql = "SELECT x, y FROM unnest($1::int8[], $2::text[]) AS t(x, y)"
}

enum TwiceSQL: PGPrepared {
    static let name = "selftest_twice"
    static let sql = "SELECT $1::int8 * 2"
}

enum PGSelfTest {
    static func run(_ config: PGConfig) async throws {
        let loop = Loop.next()
        try await Task(executorPreference: loop) {
            let t0 = ContinuousClock.now
            let connection = try await PGConnection.connect(config, on: loop)
            print("connected and authenticated in \(ContinuousClock.now - t0)")
            func text(_ r: PGResults, _ t: PGTextRef) -> String {
                r.rows.bytes.string(at: Int(t.start), count: Int(t.count))
            }

            // 1. Every type the server reads.
            var request = connection.request()
            request.execute("""
                SELECT 42::int8, 7::int4, true, 'hé "x"'::text, NULL::text, ARRAY[3,1,2]::int4[], ARRAY['a','b é']::text[],
                       '2025-04-01 12:00:00.123456+00'::timestamptz
                """)
            var r = try await connection.run(request)
            var c = try r.rows(0)[0]
            print("types:", try c.int(r.rows.bytes), try c.int4(r.rows.bytes), try c.bool(r.rows.bytes), text(r, try c.text(r.rows.bytes)),
                  try c.textOrNull(r.rows.bytes) == nil ? "NULL" : "?", try c.int4Array(r.rows.bytes),
                  try c.textArray(r.rows.bytes).map { text(r, $0) }, PGTimestamp(micros: try c.timestamp(r.rows.bytes).micros).unixMillis)

            // 2. A pipeline: a prepared statement with array binds, a failing statement, and one more after it.
            request = connection.request()
            request.execute(UnnestSQL.self) { b in b.int8Array([1, 2, 3]); b.textArray(["a", "b", "c"]) }
            request.execute("SELECT 1/0")
            request.execute("SELECT count(*) FROM users")
            r = try await connection.run(request)
            print("pipeline: \(r.count) statements")
            for row in try r.rows(0) { var c = row; print("  unnest:", try c.int(r.rows.bytes), text(r, try c.text(r.rows.bytes))) }
            print("  1/0:", r.error(1).map { "\($0)" } ?? "no error?")
            var c3 = try r.rows(2)[0]
            print("  users:", try c3.int(r.rows.bytes))

            // 3. The prepared statement again (no Parse this time), with empty arrays.
            request = connection.request()
            request.execute(UnnestSQL.self) { b in b.int8Array([]); b.textArray([]) }
            r = try await connection.run(request)
            print("prepared again, empty arrays: \(try r.rows(0).count) rows")

            // 4. A prepared statement first used in a transaction that already failed: Postgres skips its Parse, so
            // the next request must parse it again.
            request = connection.request()
            request.execute("BEGIN")
            request.execute("SELECT 1/0")
            request.execute(TwiceSQL.self) { b in b.int8(21) }
            request.execute("COMMIT")
            r = try await connection.run(request)
            print("in a failed transaction:", r.error(2).map { "\($0)" } ?? "no error?")
            request = connection.request()
            request.execute(TwiceSQL.self) { b in b.int8(21) }
            r = try await connection.run(request)
            if let error = r.error(0) { print("  after it:", error) } else { var c = try r.rows(0)[0]; print("  after it:", try c.int(r.rows.bytes)) }

            // 5. Round trips: one statement per request, then many statements in one request.
            let n = 2000
            var start = ContinuousClock.now
            for i in 0..<n {
                request = connection.request()
                request.execute(UnnestSQL.self) { b in b.int8Array([Int64(i)]); b.textArray(["x"]) }
                r = try await connection.run(request)
            }
            print("\(n) sequential requests: \((ContinuousClock.now - start) / n) per round trip")
            start = ContinuousClock.now
            request = connection.request()
            for i in 0..<n {
                request.execute(UnnestSQL.self) { b in b.int8Array([Int64(i)]); b.textArray(["x"]) }
            }
            r = try await connection.run(request)
            print("\(n) statements pipelined in one request: \(ContinuousClock.now - start) in all, \(r.count) answered")

            // 6. A closed connection fails what waits on it, and anything after.
            connection.close()
            do {
                request = connection.request()
                request.execute("SELECT pg_sleep(1)")
                _ = try await connection.run(request)
                print("closed: no error?")
            } catch {
                print("after close:", error)
            }
        }.value
    }
}
