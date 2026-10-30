// Cross-request read batching. A read waits a few milliseconds in one queue; then a lane (one Postgres connection)
// answers every read waiting, of every endpoint, with one statement per kind of read present, each over arrays of
// distinct keys (`unnest(...) WITH ORDINALITY`): identical reads share one row, and every article in the batch is
// enriched once (tags, favorite count, author), however many reads show it. Rule 5 holds: only reads already queued
// when a batch is taken share it, and nothing outlives the batch.
import HTTPTypes
import Logging
import NIOCore
import PostgresNIO
import ServiceLifecycle
import Synchronization

enum PageKind: Hashable, Sendable {
    case all
    case tag(String)
    case author(String)
    case favorited(String)
    case feed(Int64)
}

enum Read: Sendable {
    case page(PageKind, limit: Int64, offset: Int64)
    case article(slug: String)
    case comments(slug: String)
    case profile(username: String)
    case user(id: Int64)
    case tags
}

enum ReadResult: Sendable {
    case page(total: Int64, articles: [ArticleRow])
    case article(ArticleRow?)
    case comments([CommentRow]?)
    case profile(ProfileRow?)
    case user(UserRow?)
    case tags([PGText])
}

// ---------- SQL ----------
// Page statements return the counts (k <= 0: the count of key -k) and the page rows (k > 0: an article id and its
// author) of every distinct page in the batch. Counts and pages are exactly the reference SQL's, keyed by array.

protocol BatchSQL {
    static var name: String { get }
    static var sql: String { get }
}

enum PagesAllSQL: BatchSQL {
    static let name = "b_pages_all"
    static let sql = """
        SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s), NULL::int8
        UNION ALL
        SELECT r.k, p.id, p.author_id FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k)
          CROSS JOIN LATERAL (SELECT a.id, a.author_id FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) p
        """
}

enum PagesByTagSQL: BatchSQL {
    static let name = "b_pages_tag"
    static let sql = """
        SELECT -r.k, (SELECT count(*) FROM (SELECT 1 FROM article_tags at
                        WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.tag) LIMIT 1000) s), NULL::int8
          FROM unnest($1::text[]) WITH ORDINALITY r(tag, k)
        UNION ALL
        SELECT r.k, a.id, a.author_id FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(tag, lim, off, k)
          CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at
                               WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.tag)
                               ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p
          JOIN articles a ON a.id = p.article_id
        """
}

enum PagesByAuthorSQL: BatchSQL {
    static let name = "b_pages_author"
    static let sql = """
        SELECT -r.k, (SELECT count(*) FROM (SELECT 1 FROM articles a
                        WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.username) LIMIT 1000) s), NULL::int8
          FROM unnest($1::text[]) WITH ORDINALITY r(username, k)
        UNION ALL
        SELECT r.k, p.id, p.author_id FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k)
          CROSS JOIN LATERAL (SELECT a.id, a.author_id FROM articles a
                               WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = r.username)
                               ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) p
        """
}

enum PagesByFavoriteSQL: BatchSQL {
    static let name = "b_pages_favorite"
    static let sql = """
        SELECT -r.k, (SELECT count(*) FROM (SELECT 1 FROM favorites f
                        WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.username) LIMIT 1000) s), NULL::int8
          FROM unnest($1::text[]) WITH ORDINALITY r(username, k)
        UNION ALL
        SELECT r.k, a.id, a.author_id FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k)
          CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f
                               WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.username)
                               ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p
          JOIN articles a ON a.id = p.article_id
        """
}

enum PagesFeedSQL: BatchSQL {
    static let name = "b_pages_feed"
    static let sql = """
        SELECT -r.k, (SELECT count(*) FROM (SELECT 1 FROM articles a
                        WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) LIMIT 1000) s),
               NULL::int8
          FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)
        UNION ALL
        SELECT r.k, p.id, p.author_id FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY r(v, lim, off, k)
          CROSS JOIN LATERAL (SELECT x.id, x.author_id FROM follows fo
                               CROSS JOIN LATERAL (SELECT a2.id, a2.author_id FROM articles a2 WHERE a2.author_id = fo.followee_id
                                                    ORDER BY a2.id DESC LIMIT r.lim + r.off) x
                               WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.lim OFFSET r.off) p
        """
}

/// Single articles: slug -> id and author.
enum ArticlesBySlugSQL: BatchSQL {
    static let name = "b_articles_slug"
    static let sql = """
        SELECT r.k, a.id, a.author_id FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug
        """
}

/// Comment threads: one row per comment (newest 100), or one row of NULLs for an article without comments; no row
/// for no such article.
enum CommentsBySlugSQL: BatchSQL {
    static let name = "b_comments_slug"
    static let sql = """
        SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
          FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug
          LEFT JOIN LATERAL (SELECT cm.id, cm.body, cm.created_at, cm.updated_at, cm.author_id FROM comments cm
                              WHERE cm.article_id = a.id ORDER BY cm.created_at DESC, cm.id DESC LIMIT 100) c ON true
          LEFT JOIN users u ON u.id = c.author_id
        """
}

enum ProfilesByNameSQL: BatchSQL {
    static let name = "b_profiles"
    static let sql = """
        SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k)
          JOIN users u ON u.username = r.username
        """
}

enum UsersByIDSQL: BatchSQL {
    static let name = "b_users"
    static let sql = """
        SELECT r.k, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k)
          JOIN users u ON u.id = r.id
        """
}

/// Every article any read of the batch shows, once: its columns, tag ids, favorite count and author. Bodies only for
/// the articles a single-article read asked for. Tag names come from one read of the tags table per batch (TagsSQL).
enum ArticleDetailsSQL: BatchSQL {
    static let name = "b_article_details"
    static let sql = """
        SELECT a.id, a.slug, a.title, a.description, CASE WHEN a.id = ANY($2::int8[]) THEN a.body END,
               a.created_at, a.updated_at,
               ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id),
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
               u.username, u.bio, u.image
          FROM unnest($1::int8[]) r(id) JOIN articles a ON a.id = r.id JOIN users u ON u.id = a.author_id
        """
}

/// The tags table, in the database's own name order: it answers GET /api/tags and orders every article's tagList
/// (the reference SQL's `ORDER BY t.name`), once per batch instead of a join per article.
enum TagsSQL: BatchSQL {
    static let name = "b_tags"
    static let sql = "SELECT id, name FROM tags ORDER BY name"
}

/// The viewer-dependent flags the batch needs: (0, viewer, article) for each favorite, (1, viewer, user) for each follow.
/// Each viewer's candidates are one primary-key range scan (`= ANY`) instead of a probe per pair.
enum ViewerFlagsSQL: BatchSQL {
    static let name = "b_flags"
    static let sql = """
        WITH p AS (SELECT x.v, array_agg(x.t) AS ts FROM unnest($1::int8[], $2::int8[]) x(v, t) GROUP BY x.v),
             q AS (SELECT x.v, array_agg(x.t) AS ts FROM unnest($3::int8[], $4::int8[]) x(v, t) GROUP BY x.v)
        SELECT 0::int8, p.v, f.article_id FROM p
          CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.ts)) f
        UNION ALL
        SELECT 1::int8, q.v, fo.followee_id FROM q
          CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.ts)) fo
        """
}

struct BatchStatement<Q: BatchSQL>: PostgresPreparedStatement {
    typealias Row = PostgresRow
    static var name: String { Q.name }
    static var sql: String { Q.sql }

    let binds: PostgresBindings

    func makeBindings() throws -> PostgresBindings {
        binds
    }

    func decodeRow(_ row: PostgresRow) throws -> PostgresRow {
        row
    }
}

// ---------- the queue and its lanes ----------

final class ReadBatcher: Service {
    struct Settings {
        /// Postgres connections the lanes hold, one each.
        var lanes: Int
        /// The longest the oldest read waits for others before its batch is taken.
        var window: Duration
        /// A batch is taken at once when this many reads (or the recent average batch, if larger) are waiting.
        var minBatch: Int
        /// The most reads one batch takes.
        var maxBatch: Int
    }

    fileprivate struct Waiting: Sendable {
        let id: UInt64
        let read: Read
        let viewer: Int64
        let since: ContinuousClock.Instant
        let continuation: CheckedContinuation<ReadResult, any Error>
    }

    private struct State {
        var queue: [Waiting] = []
        var nextID: UInt64 = 0
        /// One lane at a time collects the next batch; the others wait for their turn here.
        var collecting = false
        var waitingForTurn: [CheckedContinuation<Void, Never>] = []
        /// The collecting lane, while the queue is empty.
        var waitingForWork: CheckedContinuation<Void, Never>?
        /// Moving average of recent batch sizes: under steady load a batch goes as soon as a typical one is waiting,
        /// instead of every read sitting out the window.
        var typicalBatch = 0.0
        var stopped = false
    }

    private let db: PostgresClient
    private let settings: Settings
    private let state = Mutex(State())
    private let clock = ContinuousClock()

    init(db: PostgresClient, settings: Settings) {
        self.db = db
        self.settings = settings
    }

    /// Queues `read` for the next batch and waits for its result.
    func read(_ read: Read, viewer: Int64) async throws -> ReadResult {
        let id = state.withLock { s in
            s.nextID &+= 1
            return s.nextID
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiting = Waiting(id: id, read: read, viewer: viewer, since: clock.now, continuation: continuation)
                let (queued, wake) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
                    if s.stopped { return (false, nil) }
                    s.queue.append(waiting)
                    defer { s.waitingForWork = nil }
                    return (true, s.waitingForWork)
                }
                if !queued { continuation.resume(throwing: ApiError(.serviceUnavailable, "shutting down")) }
                wake?.resume()
            }
        } onCancel: {
            let cancelled = state.withLock { s -> Waiting? in
                guard let i = s.queue.firstIndex(where: { $0.id == id }) else { return nil }
                return s.queue.remove(at: i)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
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

    private var isStopped: Bool {
        state.withLock { $0.stopped }
    }

    private func stop() {
        let (queued, turns, work) = state.withLock { s in
            s.stopped = true
            defer { s.queue = []; s.waitingForTurn = []; s.waitingForWork = nil }
            return (s.queue, s.waitingForTurn, s.waitingForWork)
        }
        for waiting in queued { waiting.continuation.resume(throwing: ApiError(.serviceUnavailable, "shutting down")) }
        for turn in turns { turn.resume() }
        work?.resume()
    }

    /// One Postgres connection, held for the lane's life; a lost connection is replaced.
    private func lane() async {
        while !isStopped {
            do {
                try await db.withConnection { connection in
                    while let batch = await self.nextBatch() {
                        try await self.answer(batch, on: connection)
                    }
                }
            } catch {
                App.logger.error("read lane failed", metadata: ["error": "\(error)"])
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Waits for this lane's turn to collect, then until a typical batch is waiting or the queue's oldest read has
    /// waited `window`, and takes the batch. nil once stopped.
    private func nextBatch() async -> [Waiting]? {
        while true {
            await withCheckedContinuation { (turn: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.stopped || !s.collecting {
                        s.collecting = true
                        return true
                    }
                    s.waitingForTurn.append(turn)
                    return false
                }
                if now { turn.resume() }
            }
            await withCheckedContinuation { (work: CheckedContinuation<Void, Never>) in
                let now = state.withLock { s -> Bool in
                    if s.stopped || !s.queue.isEmpty { return true }
                    s.waitingForWork = work
                    return false
                }
                if now { work.resume() }
            }
            while true {
                let deadline = state.withLock { s -> ContinuousClock.Instant? in
                    let enough = min(settings.maxBatch, max(settings.minBatch, Int(s.typicalBatch.rounded())))
                    guard !s.stopped, let oldest = s.queue.first, s.queue.count < enough else { return nil }
                    return oldest.since + settings.window
                }
                guard let deadline, deadline > clock.now else { break }
                try? await Task.sleep(until: deadline, clock: clock)
            }
            let (batch, next, stopped) = state.withLock { s -> ([Waiting], CheckedContinuation<Void, Never>?, Bool) in
                let count = min(s.queue.count, settings.maxBatch)
                let batch = Array(s.queue.prefix(count))
                s.queue.removeFirst(count)
                if count > 0 { s.typicalBatch = s.typicalBatch == 0 ? Double(count) : 0.9 * s.typicalBatch + 0.1 * Double(count) }
                let next = s.waitingForTurn.isEmpty ? nil : s.waitingForTurn.removeFirst()
                s.collecting = next != nil
                return (batch, next, s.stopped)
            }
            next?.resume()
            if !batch.isEmpty { return batch }
            if stopped { return nil }
        }
    }

    /// Answers a batch; on failure every read in it gets the error.
    private func answer(_ batch: [Waiting], on connection: PostgresConnection) async throws {
        do {
            var plan = BatchPlan(batch)
            try await plan.execute(on: connection)
            for (i, waiting) in batch.enumerated() {
                waiting.continuation.resume(returning: plan.result(i, viewer: waiting.viewer))
            }
        } catch {
            for waiting in batch { waiting.continuation.resume(throwing: error) }
            throw error
        }
    }
}

extension ReadBatcher {
    func page(_ kind: PageKind, limit: Int64, offset: Int64, viewer: Int64) async throws -> (total: Int64, articles: [ArticleRow]) {
        guard case .page(let total, let articles) = try await read(.page(kind, limit: limit, offset: offset), viewer: viewer) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        return (total, articles)
    }

    func article(slug: String, viewer: Int64) async throws -> ArticleRow? {
        guard case .article(let article) = try await read(.article(slug: slug), viewer: viewer) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        return article
    }

    func comments(slug: String, viewer: Int64) async throws -> [CommentRow]? {
        guard case .comments(let comments) = try await read(.comments(slug: slug), viewer: viewer) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        return comments
    }

    func profile(username: String, viewer: Int64) async throws -> ProfileRow? {
        guard case .profile(let profile) = try await read(.profile(username: username), viewer: viewer) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        return profile
    }

    func user(id: Int64) async throws -> UserRow? {
        guard case .user(let user) = try await read(.user(id: id), viewer: id) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        return user
    }

    func tags() async throws -> [PGText] {
        guard case .tags(let tags) = try await read(.tags, viewer: 0) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        return tags
    }
}

// ---------- one batch ----------

/// Distinct keys in first-seen order. A key's ordinal (1-based) is what the batched statements tag its rows with.
private struct Ordinals<Key: Hashable> {
    private(set) var keys: [Key] = []
    private var index: [Key: Int] = [:]

    mutating func ordinal(_ key: Key) -> Int {
        if let i = index[key] { return i }
        keys.append(key)
        index[key] = keys.count
        return keys.count
    }
}

private struct PageKey<Filter: Hashable>: Hashable {
    let filter: Filter
    let limit: Int64
    let offset: Int64
}

private struct ArticleRef {
    let id: Int64
    let author: Int64
}

/// The distinct pages of one list kind in a batch, and what Postgres returned for them.
private struct PageFamily<Filter: Hashable> {
    var counts = Ordinals<Filter>()
    var pages = Ordinals<PageKey<Filter>>()
    /// Indexed by ordinal (1-based; the global list's one count is at 0), sized by `prepare` once the keys are known,
    /// so a batch's results take no dictionary of their own.
    private(set) var totals: [Int64] = []
    private(set) var rows: [[ArticleRef]] = []

    var isEmpty: Bool { pages.keys.isEmpty }

    mutating func prepare() {
        guard !isEmpty else { return }
        totals = Array(repeating: 0, count: counts.keys.count + 1)
        rows = Array(repeating: [], count: pages.keys.count + 1)
    }

    /// Reads a page statement's rows: (k <= 0: -k's count) or (k > 0: a page row).
    mutating func take(_ row: PostgresRow) throws {
        var cells = RowCursor(row)
        let k = Int(try cells.int())
        let value = try cells.int()
        if k <= 0 {
            totals[-k] = value
        } else {
            if rows[k].isEmpty { rows[k].reserveCapacity(Int(pages.keys[k - 1].limit)) }
            rows[k].append(ArticleRef(id: value, author: try cells.int()))
        }
    }
}

private struct Pair: Hashable {
    let viewer: Int64
    let target: Int64
}

private struct CommentRef {
    let row: CommentRow
    let author: Int64
}

private struct BatchPlan {
    /// Where each read's result comes from: the ordinals of its keys in the families below.
    private enum Slot {
        case all(page: Int)
        case tag(count: Int, page: Int)
        case author(count: Int, page: Int)
        case favorited(count: Int, page: Int)
        case feed(count: Int, page: Int)
        case article(Int)
        case comments(Int)
        case profile(Int)
        case user(Int)
        case tags
    }

    private var slots: [Slot] = []
    private var all = PageFamily<Bool>()
    private var byTag = PageFamily<String>()
    private var byAuthor = PageFamily<String>()
    private var byFavorite = PageFamily<String>()
    private var feed = PageFamily<Int64>()
    private var slugs = Ordinals<String>()
    private var commentSlugs = Ordinals<String>()
    private var usernames = Ordinals<String>()
    private var userIDs = Ordinals<Int64>()
    private var wantsTags = false

    // Indexed by the ordinal of their key (1-based), sized at the end of init.
    private var articleRefs: [ArticleRef?] = []
    private var threads: [[CommentRef]?] = []
    private var profiles: [(id: Int64, row: ProfileRow)?] = []
    private var users: [UserRow?] = []
    private var tagNames: [PGText] = []
    private var details: [Int64: ArticleRow] = [:]
    private var favorites = Set<Pair>()
    private var follows = Set<Pair>()

    fileprivate init(_ batch: [ReadBatcher.Waiting]) {
        slots.reserveCapacity(batch.count)
        for waiting in batch {
            switch waiting.read {
            case .page(.all, let limit, let offset):
                _ = all.counts.ordinal(true)
                slots.append(.all(page: all.pages.ordinal(PageKey(filter: true, limit: limit, offset: offset))))
            case .page(.tag(let tag), let limit, let offset):
                slots.append(.tag(count: byTag.counts.ordinal(tag),
                                  page: byTag.pages.ordinal(PageKey(filter: tag, limit: limit, offset: offset))))
            case .page(.author(let name), let limit, let offset):
                slots.append(.author(count: byAuthor.counts.ordinal(name),
                                     page: byAuthor.pages.ordinal(PageKey(filter: name, limit: limit, offset: offset))))
            case .page(.favorited(let name), let limit, let offset):
                slots.append(.favorited(count: byFavorite.counts.ordinal(name),
                                        page: byFavorite.pages.ordinal(PageKey(filter: name, limit: limit, offset: offset))))
            case .page(.feed(let viewer), let limit, let offset):
                slots.append(.feed(count: feed.counts.ordinal(viewer),
                                   page: feed.pages.ordinal(PageKey(filter: viewer, limit: limit, offset: offset))))
            case .article(let slug):
                slots.append(.article(slugs.ordinal(slug)))
            case .comments(let slug):
                slots.append(.comments(commentSlugs.ordinal(slug)))
            case .profile(let username):
                slots.append(.profile(usernames.ordinal(username)))
            case .user(let id):
                slots.append(.user(userIDs.ordinal(id)))
            case .tags:
                wantsTags = true
                slots.append(.tags)
            }
        }
        self.viewers = batch.map(\.viewer)
        all.prepare()
        byTag.prepare()
        byAuthor.prepare()
        byFavorite.prepare()
        feed.prepare()
        if !slugs.keys.isEmpty { articleRefs = Array(repeating: nil, count: slugs.keys.count + 1) }
        if !commentSlugs.keys.isEmpty { threads = Array(repeating: nil, count: commentSlugs.keys.count + 1) }
        if !usernames.keys.isEmpty { profiles = Array(repeating: nil, count: usernames.keys.count + 1) }
        if !userIDs.keys.isEmpty { users = Array(repeating: nil, count: userIDs.keys.count + 1) }
    }

    private let viewers: [Int64]

    // ---------- execution ----------

    mutating func execute(on connection: PostgresConnection) async throws {
        // Phase 1: what each read is about.
        if !all.isEmpty {
            var binds = PostgresBindings(capacity: 2)
            binds.append(all.pages.keys.map(\.limit))
            binds.append(all.pages.keys.map(\.offset))
            for try await row in try await connection.execute(BatchStatement<PagesAllSQL>(binds: binds), logger: App.queryLogger) {
                try all.take(row)
            }
        }
        try await run(PagesByTagSQL.self, &byTag, on: connection)
        try await run(PagesByAuthorSQL.self, &byAuthor, on: connection)
        try await run(PagesByFavoriteSQL.self, &byFavorite, on: connection)
        if !feed.isEmpty {
            var binds = PostgresBindings(capacity: 4)
            binds.append(feed.counts.keys)
            binds.append(feed.pages.keys.map(\.filter))
            binds.append(feed.pages.keys.map(\.limit))
            binds.append(feed.pages.keys.map(\.offset))
            for try await row in try await connection.execute(BatchStatement<PagesFeedSQL>(binds: binds), logger: App.queryLogger) {
                try feed.take(row)
            }
        }
        if !slugs.keys.isEmpty {
            var binds = PostgresBindings(capacity: 1)
            binds.append(slugs.keys)
            for try await row in try await connection.execute(BatchStatement<ArticlesBySlugSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let k = try cells.int()
                articleRefs[Int(k)] = ArticleRef(id: try cells.int(), author: try cells.int())
            }
        }
        if !commentSlugs.keys.isEmpty {
            var binds = PostgresBindings(capacity: 1)
            binds.append(commentSlugs.keys)
            for try await row in try await connection.execute(BatchStatement<CommentsBySlugSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let k = Int(try cells.int())
                if threads[k] == nil { threads[k] = [] } // found; stays empty for an article without comments
                guard let id = try cells.intOrNull() else { continue }
                let body = try cells.text()
                let createdAt = try cells.timestamp()
                let updatedAt = try cells.timestamp()
                let author = try cells.int()
                let username = try cells.text()
                let bio = try cells.textOrNull()
                let image = try cells.textOrNull()
                let row = CommentRow(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt,
                                     author: ProfileRow(username: username, bio: bio, image: image, following: false))
                threads[k]?.append(CommentRef(row: row, author: author))
            }
        }
        if !usernames.keys.isEmpty {
            var binds = PostgresBindings(capacity: 1)
            binds.append(usernames.keys)
            for try await row in try await connection.execute(BatchStatement<ProfilesByNameSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let k = Int(try cells.int())
                let id = try cells.int()
                let username = try cells.text()
                let bio = try cells.textOrNull()
                let image = try cells.textOrNull()
                profiles[k] = (id, ProfileRow(username: username, bio: bio, image: image, following: false))
            }
        }
        if !userIDs.keys.isEmpty {
            var binds = PostgresBindings(capacity: 1)
            binds.append(userIDs.keys)
            for try await row in try await connection.execute(BatchStatement<UsersByIDSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let k = Int(try cells.int())
                users[k] = try cells.user().user
            }
        }

        // Phase 2: every article shown, once, and the viewer flags.
        var ids = Set<Int64>()
        ids.reserveCapacity(slots.count * 4)
        var favoritePairs = Set<Pair>()
        var followPairs = Set<Pair>()
        for (i, slot) in slots.enumerated() {
            let viewer = viewers[i]
            func show(_ refs: [ArticleRef]) {
                for ref in refs {
                    ids.insert(ref.id)
                    if viewer != 0 {
                        favoritePairs.insert(Pair(viewer: viewer, target: ref.id))
                        followPairs.insert(Pair(viewer: viewer, target: ref.author))
                    }
                }
            }
            switch slot {
            case .all(let page): show(all.rows[page])
            case .tag(_, let page): show(byTag.rows[page])
            case .author(_, let page): show(byAuthor.rows[page])
            case .favorited(_, let page): show(byFavorite.rows[page])
            case .feed(_, let page): show(feed.rows[page])
            case .article(let k): if let ref = articleRefs[k] { show([ref]) }
            case .comments(let k):
                if viewer != 0, let thread = threads[k] {
                    for comment in thread { followPairs.insert(Pair(viewer: viewer, target: comment.author)) }
                }
            case .profile(let k):
                if viewer != 0, let profile = profiles[k] { followPairs.insert(Pair(viewer: viewer, target: profile.id)) }
            case .user, .tags:
                break
            }
        }
        var tagIDs: [Int64: [Int32]] = [:]
        tagIDs.reserveCapacity(ids.count)
        details.reserveCapacity(ids.count)
        if !ids.isEmpty {
            var binds = PostgresBindings(capacity: 2)
            binds.append(Array(ids))
            binds.append(articleRefs.compactMap { $0?.id })
            for try await row in try await connection.execute(BatchStatement<ArticleDetailsSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let id = try cells.int()
                let slug = try cells.text()
                let title = try cells.text()
                let description = try cells.text()
                let body = try cells.textOrNull()
                let createdAt = try cells.timestamp()
                let updatedAt = try cells.timestamp()
                tagIDs[id] = try cells.int4Array()
                let favoritesCount = try cells.int()
                let username = try cells.text()
                let bio = try cells.textOrNull()
                let image = try cells.textOrNull()
                details[id] = ArticleRow(slug: slug, title: title, description: description, body: body, tagList: [],
                                         createdAt: createdAt, updatedAt: updatedAt, favorited: false,
                                         favoritesCount: favoritesCount,
                                         author: ProfileRow(username: username, bio: bio, image: image, following: false))
            }
        }
        // After the details, so every tag they name already exists. Tags are never deleted.
        if !details.isEmpty || wantsTags {
            var rank: [Int32: Int] = [:]
            rank.reserveCapacity(256)
            for try await row in try await connection.execute(BatchStatement<TagsSQL>(binds: PostgresBindings()), logger: App.queryLogger) {
                var cells = RowCursor(row)
                rank[try cells.int4()] = tagNames.count
                tagNames.append(try cells.text())
            }
            for (id, tags) in tagIDs {
                details[id]?.tagList = tags.compactMap { rank[$0] }.sorted().map { tagNames[$0] }
            }
        }
        if !favoritePairs.isEmpty || !followPairs.isEmpty {
            var binds = PostgresBindings(capacity: 4)
            binds.append(favoritePairs.map(\.viewer))
            binds.append(favoritePairs.map(\.target))
            binds.append(followPairs.map(\.viewer))
            binds.append(followPairs.map(\.target))
            for try await row in try await connection.execute(BatchStatement<ViewerFlagsSQL>(binds: binds), logger: App.queryLogger) {
                var cells = RowCursor(row)
                let kind = try cells.int()
                let pair = Pair(viewer: try cells.int(), target: try cells.int())
                switch kind {
                case 0: favorites.insert(pair)
                case 1: follows.insert(pair)
                default: throw RowError.typeMismatch("flag kind", .int8)
                }
            }
        }
    }

    private func run<Q: BatchSQL>(_ sql: Q.Type, _ family: inout PageFamily<String>, on connection: PostgresConnection) async throws {
        guard !family.isEmpty else { return }
        var binds = PostgresBindings(capacity: 4)
        binds.append(family.counts.keys)
        binds.append(family.pages.keys.map(\.filter))
        binds.append(family.pages.keys.map(\.limit))
        binds.append(family.pages.keys.map(\.offset))
        for try await row in try await connection.execute(BatchStatement<Q>(binds: binds), logger: App.queryLogger) {
            try family.take(row)
        }
    }

    // ---------- results ----------

    func result(_ i: Int, viewer: Int64) -> ReadResult {
        switch slots[i] {
        case .all(let page): return .page(total: all.totals[0], articles: articles(all.rows[page], viewer: viewer))
        case .tag(let count, let page): return .page(total: byTag.totals[count], articles: articles(byTag.rows[page], viewer: viewer))
        case .author(let count, let page):
            return .page(total: byAuthor.totals[count], articles: articles(byAuthor.rows[page], viewer: viewer))
        case .favorited(let count, let page):
            return .page(total: byFavorite.totals[count], articles: articles(byFavorite.rows[page], viewer: viewer))
        case .feed(let count, let page): return .page(total: feed.totals[count], articles: articles(feed.rows[page], viewer: viewer))
        case .article(let k):
            guard let ref = articleRefs[k] else { return .article(nil) }
            return .article(articles([ref], viewer: viewer).first)
        case .comments(let k):
            guard let thread = threads[k] else { return .comments(nil) }
            let sorted = thread.sorted {
                $0.row.createdAt.micros != $1.row.createdAt.micros ? $0.row.createdAt.micros > $1.row.createdAt.micros : $0.row.id > $1.row.id
            }
            return .comments(sorted.map { comment in
                var row = comment.row
                row.author.following = follows.contains(Pair(viewer: viewer, target: comment.author))
                return row
            })
        case .profile(let k):
            guard let profile = profiles[k] else { return .profile(nil) }
            var row = profile.row
            row.following = follows.contains(Pair(viewer: viewer, target: profile.id))
            return .profile(row)
        case .user(let k): return .user(users[k])
        case .tags: return .tags(tagNames)
        }
    }

    /// A page's articles, newest first, with this viewer's flags.
    private func articles(_ refs: [ArticleRef]?, viewer: Int64) -> [ArticleRow] {
        guard let refs else { return [] }
        return refs.sorted { $0.id > $1.id }.compactMap { ref in
            guard var row = details[ref.id] else { return nil }
            row.favorited = favorites.contains(Pair(viewer: viewer, target: ref.id))
            row.author.following = follows.contains(Pair(viewer: viewer, target: ref.author))
            return row
        }
    }
}
