// Group commit. Writes wait in one queue, and a write lane (a task on one event loop, with one Postgres connection of
// its own there) runs every write waiting as one transaction, sent as one request (BEGIN, the writes, COMMIT, each
// statement with its own Sync), and answers them all once COMMIT has returned: one commit and one round trip for the
// group. A group's favorites, unfavorites, follows, unfollows and new comments run as one statement per kind, over
// arrays of their parameters, however they were interleaved; every other write is one statement too (three, for an
// article with tags), so nothing in a group waits on another statement's answer. If a statement fails (a sign-up
// whose username is taken), Postgres rolls the group back, and each write runs again in a transaction of its own, so
// one bad write fails alone. A favorite or a new article is answered with the article read in the same transaction,
// after the writes (one statement for all of a group's favorites, one per new article), so it doesn't wait for a read
// batch after the commit; an updated article (its slug may have changed) is read through the read batcher, like any
// GET of it.
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

/// The columns a write answers an article with (PGCursor.article), for an article `a`, its author `u` and a viewer
/// `viewer`: the reference SQL's, tags in name order as in every read.
private let writeArticleColumns = """
    a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
    ARRAY(SELECT t.name FROM article_tags x JOIN tags t ON t.id = x.tag_id WHERE x.article_id = a.id ORDER BY t.name),
    EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = viewer AND f.article_id = a.id),
    (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
    u.username, u.bio, u.image,
    EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = viewer AND f.followee_id = a.author_id)
    """

/// The articles a group's favorites and unfavorites answer with, after them in its transaction.
enum FavoritedArticlesSQL: BatchSQL {
    static let name = "w_favorited_articles"
    static let sql = """
        SELECT r.k, \(writeArticleColumns)
          FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(viewer, slug, k)
          JOIN articles a ON a.slug = r.slug JOIN users u ON u.id = a.author_id
        """
}

/// The article this session inserted last (CreateArticleSQL, earlier in the same transaction), with its tags.
/// `currval` is volatile, so compared row by row it would be a scan of every article; as a subquery it is taken
/// once, and the lookup is by primary key.
enum NewArticleSQL: BatchSQL {
    static let name = "w_new_article"
    static let sql = """
        SELECT \(writeArticleColumns)
          FROM (SELECT $1::int8 AS viewer) r
          JOIN articles a ON a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id'))) JOIN users u ON u.id = a.author_id
        """
}

// ---------- single writes, one statement each ----------

enum BeginSQL: BatchSQL {
    static let name = "w_begin"
    static let sql = "BEGIN"
}

enum CommitSQL: BatchSQL {
    static let name = "w_commit"
    static let sql = "COMMIT"
}

enum RegisterSQL: BatchSQL {
    static let name = "w_register"
    static let sql = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"
}

enum UpdateUserSQL: BatchSQL {
    static let name = "w_update_user"
    static let sql = """
        UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                         password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
         WHERE id = $1
        RETURNING id, username, email, bio, image
        """
}

enum CreateArticleSQL: BatchSQL {
    static let name = "w_create_article"
    static let sql = """
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
          FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
        RETURNING id, slug
        """
}

enum InsertTagsSQL: BatchSQL {
    static let name = "w_insert_tags"
    static let sql = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
}

/// The tags of the article this session inserted last (CreateArticleSQL, just before it in the same transaction).
enum ArticleTagsSQL: BatchSQL {
    static let name = "w_article_tags"
    static let sql = """
        INSERT INTO article_tags (article_id, tag_id)
        SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])
        """
}

/// The article's author, and its slug after the update if the viewer is that author (otherwise it isn't updated).
enum UpdateArticleSQL: BatchSQL {
    static let name = "w_update_article"
    static let sql = """
        WITH a AS (SELECT id, author_id FROM articles WHERE slug = $1),
             u AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description),
                          body = COALESCE($5, body),
                          slug = CASE WHEN $3::text IS NULL THEN slug
                                      ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
                          updated_at = now()
                    WHERE id = (SELECT id FROM a WHERE author_id = $2)
                RETURNING slug)
        SELECT a.author_id, (SELECT slug FROM u) FROM a
        """
}

/// The article's author; the article is deleted if that is the viewer.
enum DeleteArticleSQL: BatchSQL {
    static let name = "w_delete_article"
    static let sql = """
        WITH a AS (SELECT id, author_id FROM articles WHERE slug = $1),
             d AS (DELETE FROM articles WHERE id = (SELECT id FROM a WHERE author_id = $2))
        SELECT author_id FROM a
        """
}

/// The comment's author (if the comment is on that article); the comment is deleted if that is the viewer.
enum DeleteCommentSQL: BatchSQL {
    static let name = "w_delete_comment"
    static let sql = """
        WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2),
             d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = $3))
        SELECT author_id FROM c
        """
}

// ---------- the queue and its lanes ----------

final class WriteBatcher: Service {
    struct Settings {
        /// Write lanes, each with one Postgres connection.
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

    private let config: PGConfig
    private let signer: JWTSigner
    private let settings: Settings
    private let state = Mutex(State())

    init(config: PGConfig, signer: JWTSigner, settings: Settings) {
        self.config = config
        self.signer = signer
        self.settings = settings
    }

    /// Runs `write` in the next group and waits for its commit.
    func run(_ write: Write) async throws -> WriteOutcome {
        try await withCheckedThrowingContinuation { continuation in
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
            for _ in 0..<max(1, settings.lanes) {
                let loop = Loop.next()
                group.addTask(executorPreference: loop) { await self.lane(on: loop) }
            }
            group.addTask {
                try? await gracefulShutdown()
                self.stop()
            }
        }
    }

    private var isStopped: Bool {
        state.withLock { $0.stopped }
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

    /// Commits groups, one at a time, on its connection, from `loop`, where the connection lives. A closed connection
    /// is replaced before the next group.
    private func lane(on loop: Loop) async {
        var connection: PGConnection?
        while !isStopped {
            if connection?.isClosed ?? true {
                do {
                    connection = try await PGConnection.connect(config, on: loop)
                } catch {
                    App.logger.error("write lane could not connect", metadata: ["error": "\(error)"])
                    try? await Task.sleep(for: .milliseconds(200))
                    continue
                }
            }
            guard let group = await nextGroup() else { break }
            await commit(group, on: connection!)
        }
        connection?.close()
    }

    /// Everything waiting (up to `maxGroup`, and up to a second toggle of one favorite or follow), once there is
    /// anything; nil once stopped.
    private func nextGroup() async -> [Waiting]? {
        while true {
            let group = state.withLock { s -> [Waiting]? in
                if s.stopped { return nil }
                var count = 0
                var toggles = Set<String>()
                while count < min(s.queue.count, settings.maxGroup) {
                    if let key = Self.toggle(s.queue[count].write), !toggles.insert(key).inserted { break }
                    count += 1
                }
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

    /// One transaction for the whole group, in one request; every write in it is answered, whatever happens. A failed
    /// statement rolls it back (COMMIT then ends the aborted transaction) and sends each write through a transaction
    /// of its own; a lost connection (when COMMIT's outcome is unknown) fails the group without a retry.
    private func commit(_ group: [Waiting], on connection: PGConnection) async {
        let writes = group.map(\.write)
        do {
            let (request, steps) = build(writes, on: connection)
            let results = try await connection.run(request)
            if (0..<results.count).contains(where: { results.error($0) != nil }) {
                for waiting in group { waiting.continuation.resume(with: await alone(waiting.write, on: connection)) }
                return
            }
            let outcomes = try decode(writes, steps, results)
            for (waiting, outcome) in zip(group, outcomes) { waiting.continuation.resume(returning: outcome) }
        } catch {
            App.logger.error("write group failed", metadata: ["error": "\(error)"])
            for waiting in group { waiting.continuation.resume(throwing: error) }
        }
    }

    /// One write in a transaction of its own; a username or email that is taken is a 422.
    private func alone(_ write: Write, on connection: PGConnection) async -> Result<WriteOutcome, any Error> {
        do {
            let (request, steps) = build([write], on: connection)
            let results = try await connection.run(request)
            if let error = (0..<results.count).lazy.compactMap({ results.error($0) }).first {
                if error.isUniqueViolation {
                    return .success(.response(errorResponse(.unprocessableContent, "username or email is already taken")))
                }
                throw error
            }
            return .success(try decode([write], steps, results)[0])
        } catch {
            return .failure(error)
        }
    }

    // ---------- a group's statements ----------

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

    /// What two writes in one group must not share: the same user's favorite of one article, or follow of one user
    /// (their order matters, and merged runs don't keep the order between kinds).
    private static func toggle(_ write: Write) -> String? {
        switch write {
        case .favorite(let viewer, let slug, _): "f\(viewer) \(slug)"
        case .follow(let viewer, let username, _): "o\(viewer) \(username)"
        default: nil
        }
    }

    /// Where a write's answer is in the request: a statement of its own, a row of a merged kind's, or (favorites
    /// and unfavorites) a row of the statement that reads their articles.
    private enum Step {
        case single(write: Int, statement: Int)
        case run(Merged, writes: [Int], statement: Int)
        case articles(writes: [Int], statement: Int)
    }

    /// The group's statements: every other write in turn, then one statement per merged kind for all the group's
    /// writes of that kind (in the order they arrived), then the articles its favorites answer with. Writes of
    /// different users commute, and `nextGroup` never puts the same toggle of one user twice in a group, so a group
    /// costs about six statements however large it is.
    private func build(_ writes: [Write], on connection: PGConnection) -> (PGRequest, [Step]) {
        var request = connection.request()
        request.execute(BeginSQL.self) { _ in }
        var steps: [Step] = []
        var byKind: [(kind: Merged, writes: [Int])] = []
        for (i, write) in writes.enumerated() {
            guard let kind = Self.merged(write) else {
                steps.append(.single(write: i, statement: Self.add(write, to: &request)))
                continue
            }
            if let k = byKind.firstIndex(where: { $0.kind == kind }) { byKind[k].writes.append(i) } else { byKind.append((kind, [i])) }
        }
        for (kind, indices) in byKind {
            steps.append(.run(kind, writes: indices, statement: request.count))
            Self.add(kind, indices.map { writes[$0] }, to: &request)
        }
        let favorites = byKind.filter { $0.kind == .favorite || $0.kind == .unfavorite }.flatMap(\.writes).sorted()
        if !favorites.isEmpty {
            steps.append(.articles(writes: favorites, statement: request.count))
            var viewers: [Int64] = []
            var slugs: [String] = []
            for i in favorites {
                guard case .favorite(let viewer, let slug, _) = writes[i] else { preconditionFailure("not a favorite") }
                viewers.append(viewer)
                slugs.append(slug)
            }
            request.execute(FavoritedArticlesSQL.self) { b in b.int8Array(viewers); b.textArray(slugs) }
        }
        request.execute(CommitSQL.self) { _ in }
        return (request, steps)
    }

    private static func add(_ kind: Merged, _ writes: [Write], to request: inout PGRequest) {
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
        let binds: (inout PGBinds) -> Void = { b in b.int8Array(viewers); b.textArray(keys) }
        switch kind {
        case .favorite: request.execute(FavoriteSQL.self, binds)
        case .unfavorite: request.execute(UnfavoriteSQL.self, binds)
        case .follow: request.execute(FollowSQL.self, binds)
        case .unfollow: request.execute(UnfollowSQL.self, binds)
        case .comment: request.execute(NewCommentsSQL.self) { b in b.int8Array(viewers); b.textArray(keys); b.textArray(bodies) }
        }
    }

    /// Adds the write's statements; returns the index of the one it is answered from.
    private static func add(_ write: Write, to request: inout PGRequest) -> Int {
        let first = request.count
        switch write {
        case .register(let username, let email, let hash):
            request.execute(RegisterSQL.self) { b in b.text(username); b.text(email); b.text(hash) }
        case .updateUser(let viewer, _, let email, let username, let hash, let bio, let image):
            request.execute(UpdateUserSQL.self) { b in
                b.int8(viewer); b.text(email); b.text(username); b.text(hash); b.text(bio); b.text(image)
            }
        case .createArticle(let viewer, let title, let description, let body, let tags):
            request.execute(CreateArticleSQL.self) { b in b.int8(viewer); b.text(title); b.text(description); b.text(body) }
            if !tags.isEmpty {
                request.execute(InsertTagsSQL.self) { b in b.textArray(tags) }
                request.execute(ArticleTagsSQL.self) { b in b.textArray(tags) }
            }
            request.execute(NewArticleSQL.self) { b in b.int8(viewer) }
            return request.count - 1
        case .updateArticle(let viewer, let slug, let title, let description, let body):
            request.execute(UpdateArticleSQL.self) { b in b.text(slug); b.int8(viewer); b.text(title); b.text(description); b.text(body) }
        case .deleteArticle(let viewer, let slug):
            request.execute(DeleteArticleSQL.self) { b in b.text(slug); b.int8(viewer) }
        case .deleteComment(let viewer, let slug, let id):
            request.execute(DeleteCommentSQL.self) { b in b.int8(id); b.text(slug); b.int8(viewer) }
        case .favorite, .follow, .createComment:
            preconditionFailure("a merged write")
        }
        return first
    }

    // ---------- their answers ----------

    private func decode(_ writes: [Write], _ steps: [Step], _ results: PGResults) throws -> [WriteOutcome] {
        var outcomes = [WriteOutcome?](repeating: nil, count: writes.count)
        let rows = results.rows
        for step in steps {
            switch step {
            case .single(let w, let statement):
                outcomes[w] = try single(writes[w], try results.rows(statement), rows)
            case .run(.favorite, _, _), .run(.unfavorite, _, _):
                break // answered from their articles (.articles)
            case .run(let kind, let indices, let statement):
                let answers = try run(kind, indices.map { writes[$0] }, try results.rows(statement), rows)
                for (i, answer) in zip(indices, answers) { outcomes[i] = answer }
            case .articles(let indices, let statement):
                for row in try results.rows(statement) {
                    var cells = row
                    let k = Int(try cells.int(rows.bytes)) - 1
                    outcomes[indices[k]] = .response(articleResponse(try cells.article(rows.bytes), .ok, rows))
                }
                for i in indices where outcomes[i] == nil {
                    outcomes[i] = .response(errorResponse(.notFound, "article not found"))
                }
            }
        }
        return outcomes.map { $0! }
    }

    private func run(_ kind: Merged, _ writes: [Write], _ statement: PGRowRanges, _ rows: PGRows) throws -> [WriteOutcome] {
        var outcomes = [WriteOutcome?](repeating: nil, count: writes.count)
        for row in statement {
            var cells = row
            let k = Int(try cells.int(rows.bytes)) - 1
            switch kind {
            case .favorite, .unfavorite:
                preconditionFailure("answered from their articles")
            case .follow, .unfollow:
                var profile = try cells.profile(rows.bytes)
                profile.following = kind == .follow
                outcomes[k] = .response(profileResponse(profile, rows.bytes))
            case .comment:
                outcomes[k] = .response(newCommentResponse(try cells.comment(rows.bytes), rows.bytes))
            }
        }
        let missing: Response = switch kind {
        case .favorite, .unfavorite, .comment: errorResponse(.notFound, "article not found")
        case .follow, .unfollow: errorResponse(.notFound, "profile not found")
        }
        return outcomes.map { $0 ?? .response(missing) }
    }

    private func single(_ write: Write, _ statement: PGRowRanges, _ rows: PGRows) throws -> WriteOutcome {
        let first = statement.first
        switch write {
        case .register:
            guard var cells = first else { throw ApiError(.internalServerError, "insert returned no row") }
            let (id, user) = try cells.user(rows.bytes)
            return .response(userResponse(.created, user, token: signer.issue(id: id), rows.bytes))
        case .updateUser(_, let token, _, _, _, _, _):
            guard var cells = first else { return .response(errorResponse(.unauthorized, "unauthorized")) }
            return .response(userResponse(.ok, try cells.user(rows.bytes).user, token: token, rows.bytes))
        case .createArticle:
            guard var cells = first else { throw ApiError(.internalServerError, "insert returned no row") }
            return .response(articleResponse(try cells.article(rows.bytes), .created, rows))
        case .updateArticle(let viewer, _, _, _, _):
            guard var cells = first else { return .response(errorResponse(.notFound, "article not found")) }
            guard try cells.int(rows.bytes) == viewer else { return .response(errorResponse(.forbidden, "not the author")) }
            let slug = try cells.text(rows.bytes)
            return .article(slug: string(slug, rows), viewer: viewer, status: .ok)
        case .deleteArticle(let viewer, _):
            guard var cells = first else { return .response(errorResponse(.notFound, "article not found")) }
            guard try cells.int(rows.bytes) == viewer else { return .response(errorResponse(.forbidden, "not the author")) }
            return .response(emptyResponse(.noContent))
        case .deleteComment(let viewer, _, _):
            guard var cells = first else { return .response(errorResponse(.notFound, "comment not found")) }
            guard try cells.int(rows.bytes) == viewer else { return .response(errorResponse(.forbidden, "not the author")) }
            return .response(emptyResponse(.noContent))
        case .favorite, .follow, .createComment:
            preconditionFailure("a merged write")
        }
    }

    private func articleResponse(_ a: ArticleRow, _ status: Status, _ rows: PGRows) -> Response {
        var out = JSONWriter(capacity: 512 + Int(a.body?.count ?? 0) + 2 * Int(a.title.count + a.description.count))
        out.raw("{\"article\":")
        out.article(a, full: true, rows.bytes)
        out.raw("}")
        return out.response(status)
    }

    private func string(_ t: PGTextRef, _ rows: PGRows) -> String {
        rows.bytes.string(at: Int(t.start), count: Int(t.count))
    }
}
