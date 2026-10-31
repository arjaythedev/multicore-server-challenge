// Group commit. Writes wait in one queue, and a write lane (one Postgres connection) runs every write waiting as one
// transaction and answers them all once COMMIT has returned: one commit for the group instead of one per write.
// Consecutive favorites, unfavorites, follows, unfollows and new comments of a group run as one statement each, over
// arrays of their parameters, in the order they arrived. If a statement fails (a sign-up whose username is taken),
// the group is rolled back and each write runs again in a transaction of its own, so one bad write fails alone.
// Writes that answer with an article (favorite, create, update) read it after the commit through the read batcher,
// like any GET of it.
import Logging
import NIOCore
import PostgresNIO
import ServiceLifecycle
import Synchronization

enum Write: Sendable {
    case register(username: String, email: String, hash: String)
    case updateUser(viewer: Int64, token: String, email: String?, username: String?, hash: String?, bio: String?, image: String?)
    case favorite(viewer: Int64, slug: String, on: Bool)
    case follow(viewer: Int64, username: String, on: Bool)
    case createArticle(viewer: Int64, title: String, description: String, body: String, tags: [String])
    case updateArticle(viewer: Int64, slug: String, title: String?, description: String?, body: String?)
    case deleteArticle(viewer: Int64, slug: String)
    case createComment(viewer: Int64, slug: String, body: String)
    case deleteComment(viewer: Int64, slug: String, id: Int64)
}

/// What a committed write answers with.
enum WriteOutcome: Sendable {
    case response(Response)
    /// The article to read (through the read batcher) and answer with, under `status`.
    case article(slug: String, viewer: Int64, status: Status)
}

// ---------- merged statements ----------

enum FavoriteSQL: BatchSQL {
    static let name = "w_favorite"
    static let sql = """
        WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(viewer, slug, k)),
             a AS (SELECT r.k, r.viewer, x.id FROM r JOIN articles x ON x.slug = r.slug),
             ins AS (INSERT INTO favorites (user_id, article_id) SELECT DISTINCT viewer, id FROM a ON CONFLICT DO NOTHING)
        SELECT k FROM a
        """
}

enum UnfavoriteSQL: BatchSQL {
    static let name = "w_unfavorite"
    static let sql = """
        WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(viewer, slug, k)),
             a AS (SELECT r.k, r.viewer, x.id FROM r JOIN articles x ON x.slug = r.slug),
             del AS (DELETE FROM favorites f USING a WHERE f.user_id = a.viewer AND f.article_id = a.id)
        SELECT k FROM a
        """
}

enum FollowSQL: BatchSQL {
    static let name = "w_follow"
    static let sql = """
        WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(viewer, username, k)),
             u AS (SELECT r.k, r.viewer, x.id, x.username, x.bio, x.image FROM r JOIN users x ON x.username = r.username),
             ins AS (INSERT INTO follows (follower_id, followee_id) SELECT DISTINCT viewer, id FROM u ON CONFLICT DO NOTHING)
        SELECT k, username, bio, image FROM u
        """
}

enum UnfollowSQL: BatchSQL {
    static let name = "w_unfollow"
    static let sql = """
        WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(viewer, username, k)),
             u AS (SELECT r.k, r.viewer, x.id, x.username, x.bio, x.image FROM r JOIN users x ON x.username = r.username),
             del AS (DELETE FROM follows f USING u WHERE f.follower_id = u.viewer AND f.followee_id = u.id)
        SELECT k, username, bio, image FROM u
        """
}

/// New comments, their ids drawn in the order the requests arrived.
enum NewCommentsSQL: BatchSQL {
    static let name = "w_comments"
    static let sql = """
        WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[], $3::text[]) WITH ORDINALITY r(viewer, slug, body, k)),
             a AS (SELECT r.k, r.viewer, r.body, x.id AS article_id FROM r JOIN articles x ON x.slug = r.slug),
             n AS (SELECT s.*, nextval(pg_get_serial_sequence('comments', 'id')) AS id FROM (SELECT * FROM a ORDER BY k) s),
             c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, article_id, viewer, body FROM n
                   RETURNING id, body, created_at, updated_at, author_id)
        SELECT n.k, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
          FROM c JOIN n ON n.id = c.id JOIN users u ON u.id = c.author_id
        """
}

// ---------- the queue and its lanes ----------

final class WriteBatcher: Service {
    struct Settings {
        /// Postgres connections the write lanes hold, one each; 0 runs each write in its own transaction instead.
        var lanes: Int
        /// The most writes one transaction takes.
        var maxGroup: Int
    }

    fileprivate struct Waiting: Sendable {
        let write: Write
        let continuation: CheckedContinuation<WriteOutcome, any Error>
    }

    private struct State {
        var queue: [Waiting] = []
        var waitingForWork: [CheckedContinuation<Void, Never>] = []
        var stopped = false
    }

    private let db: PostgresClient
    private let signer: JWTSigner
    private let settings: Settings
    private let state = Mutex(State())

    init(db: PostgresClient, signer: JWTSigner, settings: Settings) {
        self.db = db
        self.signer = signer
        self.settings = settings
    }

    /// Runs `write` in the next group and waits for its commit.
    func run(_ write: Write) async throws -> WriteOutcome {
        guard settings.lanes > 0 else {
            return try await db.withConnection { connection in try await self.alone(write, on: connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let (queued, wake) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
                if s.stopped { return (false, nil) }
                s.queue.append(Waiting(write: write, continuation: continuation))
                return (true, s.waitingForWork.isEmpty ? nil : s.waitingForWork.removeFirst())
            }
            if !queued { continuation.resume(throwing: ApiError(.serviceUnavailable, "shutting down")) }
            wake?.resume()
        }
    }

    func run() async throws {
        await withDiscardingTaskGroup { group in
            for _ in 0..<settings.lanes {
                group.addTask { await self.lane() }
            }
            group.addTask {
                try? await gracefulShutdown()
                self.stop()
            }
        }
    }

    private func stop() {
        let (queued, idle) = state.withLock { s in
            s.stopped = true
            defer { s.queue = []; s.waitingForWork = [] }
            return (s.queue, s.waitingForWork)
        }
        for waiting in queued { waiting.continuation.resume(throwing: ApiError(.serviceUnavailable, "shutting down")) }
        for lane in idle { lane.resume() }
    }

    /// One Postgres connection, held for the lane's life; a lost connection is replaced.
    private func lane() async {
        while !state.withLock({ $0.stopped }) {
            do {
                try await db.withConnection { connection in
                    while let group = await self.nextGroup() {
                        try await self.commit(group, on: connection)
                    }
                }
            } catch {
                App.logger.error("write lane failed", metadata: ["error": "\(error)"])
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Everything waiting (up to `maxGroup`), once there is anything; nil once stopped.
    private func nextGroup() async -> [Waiting]? {
        while true {
            let group = state.withLock { s -> [Waiting]? in
                if s.stopped { return nil }
                let count = min(s.queue.count, settings.maxGroup)
                defer { s.queue.removeFirst(count) }
                return Array(s.queue.prefix(count))
            }
            guard let group else { return nil }
            if !group.isEmpty { return group }
            await withCheckedContinuation { (work: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.stopped || !s.queue.isEmpty { return true }
                    s.waitingForWork.append(work)
                    return false
                }
                if now { work.resume() }
            }
        }
    }

    /// One transaction for the whole group. An error from Postgres rolls it back and sends each write through a
    /// transaction of its own; a lost connection (when COMMIT's outcome is unknown) fails the group and the lane
    /// reconnects.
    private func commit(_ group: [Waiting], on connection: PostgresConnection) async throws {
        do {
            try await connection.exec("BEGIN")
            let outcomes = try await execute(group.map(\.write), on: connection)
            try await connection.exec("COMMIT")
            for (waiting, outcome) in zip(group, outcomes) { waiting.continuation.resume(returning: outcome) }
        } catch let error as PSQLError where error.serverInfo != nil {
            try await connection.exec("ROLLBACK")
            for waiting in group {
                do {
                    waiting.continuation.resume(returning: try await alone(waiting.write, on: connection))
                } catch {
                    waiting.continuation.resume(throwing: error)
                }
            }
        } catch {
            for waiting in group { waiting.continuation.resume(throwing: error) }
            throw error
        }
    }

    /// One write in a transaction of its own; a username or email that is taken is a 422.
    private func alone(_ write: Write, on connection: PostgresConnection) async throws -> WriteOutcome {
        do {
            try await connection.exec("BEGIN")
            let outcome = try await execute([write], on: connection)[0]
            try await connection.exec("COMMIT")
            return outcome
        } catch let error as PSQLError where error.serverInfo != nil {
            try await connection.exec("ROLLBACK")
            if isUniqueViolation(error) {
                return .response(errorResponse(.unprocessableContent, "username or email is already taken"))
            }
            throw error
        }
    }

    // ---------- the statements of a group ----------

    private enum Merged: Equatable {
        case favorite, unfavorite, follow, unfollow, comment
    }

    private static func merged(_ write: Write) -> Merged? {
        switch write {
        case .favorite(_, _, let on): on ? .favorite : .unfavorite
        case .follow(_, _, let on): on ? .follow : .unfollow
        case .createComment: .comment
        default: nil
        }
    }

    /// The writes' statements, in order; runs of the same merged kind as one statement.
    private func execute(_ writes: [Write], on connection: PostgresConnection) async throws -> [WriteOutcome] {
        var outcomes: [WriteOutcome] = []
        outcomes.reserveCapacity(writes.count)
        var start = 0
        while start < writes.count {
            guard let kind = Self.merged(writes[start]) else {
                outcomes.append(try await single(writes[start], on: connection))
                start += 1
                continue
            }
            var end = start + 1
            while end < writes.count, Self.merged(writes[end]) == kind { end += 1 }
            outcomes += try await run(kind, writes[start..<end], on: connection)
            start = end
        }
        return outcomes
    }

    private func run(_ kind: Merged, _ writes: ArraySlice<Write>, on connection: PostgresConnection) async throws -> [WriteOutcome] {
        var viewers: [Int64] = []
        var keys: [String] = []
        var bodies: [String] = []
        for write in writes {
            switch write {
            case .favorite(let viewer, let slug, _), .createComment(let viewer, let slug, _):
                viewers.append(viewer)
                keys.append(slug)
                if case .createComment(_, _, let body) = write { bodies.append(body) }
            case .follow(let viewer, let username, _):
                viewers.append(viewer)
                keys.append(username)
            default:
                preconditionFailure("not a merged write")
            }
        }
        var binds = PostgresBindings(capacity: 3)
        binds.append(viewers)
        binds.append(keys)
        if kind == .comment { binds.append(bodies) }

        var outcomes = [WriteOutcome?](repeating: nil, count: writes.count)
        switch kind {
        case .favorite, .unfavorite:
            let rows = kind == .favorite
                ? try await connection.execute(BatchStatement<FavoriteSQL>(binds: binds), logger: App.queryLogger)
                : try await connection.execute(BatchStatement<UnfavoriteSQL>(binds: binds), logger: App.queryLogger)
            for try await row in rows {
                var cells = RowCursor(row)
                let k = Int(try cells.int()) - 1
                outcomes[k] = .article(slug: keys[k], viewer: viewers[k], status: .ok)
            }
            return outcomes.map { $0 ?? .response(errorResponse(.notFound, "article not found")) }
        case .follow, .unfollow:
            let rows = kind == .follow
                ? try await connection.execute(BatchStatement<FollowSQL>(binds: binds), logger: App.queryLogger)
                : try await connection.execute(BatchStatement<UnfollowSQL>(binds: binds), logger: App.queryLogger)
            for try await row in rows {
                var cells = RowCursor(row)
                let k = Int(try cells.int()) - 1
                let username = try cells.text()
                let bio = try cells.textOrNull()
                let image = try cells.textOrNull()
                outcomes[k] = .response(profileResponse(ProfileRow(username: username, bio: bio, image: image,
                                                                   following: kind == .follow)))
            }
            return outcomes.map { $0 ?? .response(errorResponse(.notFound, "profile not found")) }
        case .comment:
            for try await row in try await connection.execute(BatchStatement<NewCommentsSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let k = Int(try cells.int()) - 1
                outcomes[k] = .response(try newCommentResponse(&cells))
            }
            return outcomes.map { $0 ?? .response(errorResponse(.notFound, "article not found")) }
        }
    }

    /// A write that isn't merged with others: its statements as SPEC.md lists them.
    private func single(_ write: Write, on connection: PostgresConnection) async throws -> WriteOutcome {
        do {
            switch write {
            case .register(let username, let email, let hash):
                guard let row = try await connection.firstRow(
                    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
                    [username, email, hash]
                ) else { throw ApiError(.internalServerError, "insert returned no row") }
                let (id, user) = try row.user()
                return .response(userResponse(.created, user, token: signer.issue(id: id)))

            case .updateUser(let viewer, let token, let email, let username, let hash, let bio, let image):
                var binds = PostgresBindings(capacity: 6)
                binds.append(viewer)
                binds.append(email)
                binds.append(username)
                binds.append(hash)
                binds.append(bio)
                binds.append(image)
                guard let row = try await connection.firstRow(updateUserSQL, binds: binds) else {
                    throw ApiError(.unauthorized, "unauthorized")
                }
                return .response(userResponse(.ok, try row.user().user, token: token))

            case .createArticle(let viewer, let title, let description, let body, let tags):
                guard let row = try await connection.firstRow(insertArticle, [viewer, title, description, body]) else {
                    throw ApiError(.internalServerError, "insert returned no row")
                }
                var cells = RowCursor(row)
                let id = try cells.int()
                let slug = String(buffer: try cells.text().bytes)
                if !tags.isEmpty {
                    try await connection.exec(insertTags, [tags])
                    try await connection.exec(insertArticleTags, [id, tags])
                }
                return .article(slug: slug, viewer: viewer, status: .created)

            case .updateArticle(let viewer, let slug, let title, let description, let body):
                let id = try await ownArticle(slug, viewer: viewer, on: connection)
                var binds = PostgresBindings(capacity: 4)
                binds.append(id)
                binds.append(title)
                binds.append(description)
                binds.append(body)
                guard let row = try await connection.firstRow(updateArticleSQL, binds: binds) else {
                    throw ApiError(.notFound, "article not found")
                }
                var cells = RowCursor(row)
                return .article(slug: String(buffer: try cells.text().bytes), viewer: viewer, status: .ok)

            case .deleteArticle(let viewer, let slug):
                let id = try await ownArticle(slug, viewer: viewer, on: connection)
                try await connection.exec("DELETE FROM articles WHERE id = $1", [id])
                return .response(emptyResponse(.noContent))

            case .deleteComment(let viewer, let slug, let id):
                guard let row = try await connection.firstRow(
                    "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
                    [id, slug]
                ) else { throw ApiError(.notFound, "comment not found") }
                var cells = RowCursor(row)
                guard try cells.int() == viewer else { throw ApiError(.forbidden, "not the author") }
                try await connection.exec("DELETE FROM comments WHERE id = $1", [id])
                return .response(emptyResponse(.noContent))

            case .favorite, .follow, .createComment:
                return try await execute([write], on: connection)[0]
            }
        } catch let error as ApiError {
            return .response(errorResponse(error.status, error.message))
        }
    }

    /// SELECT id, author_id FROM articles WHERE slug = $1: 404 if missing, 403 if not the viewer's.
    private func ownArticle(_ slug: String, viewer: Int64, on connection: PostgresConnection) async throws -> Int64 {
        guard let row = try await connection.firstRow("SELECT id, author_id FROM articles WHERE slug = $1", [slug]) else {
            throw ApiError(.notFound, "article not found")
        }
        var cells = RowCursor(row)
        let id = try cells.int()
        guard try cells.int() == viewer else { throw ApiError(.forbidden, "not the author") }
        return id
    }
}

extension PostgresConnection {
    func firstRow(_ sql: String, _ values: [any PostgresEncodable] = []) async throws -> PostgresRow? {
        try await firstRow(sql, binds: makeQuery(sql, values).binds)
    }

    @_disfavoredOverload
    func firstRow(_ sql: String, binds: PostgresBindings) async throws -> PostgresRow? {
        for try await row in try await query(PostgresQuery(unsafeSQL: sql, binds: binds), logger: App.queryLogger) {
            return row
        }
        return nil
    }

    func exec(_ sql: String, _ values: [any PostgresEncodable] = []) async throws {
        _ = try await query(makeQuery(sql, values), logger: App.queryLogger)
    }
}
