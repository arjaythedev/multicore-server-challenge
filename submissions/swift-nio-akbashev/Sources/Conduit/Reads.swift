// Cross-request read batching. A read waits a few milliseconds in one queue; then a lane (one Postgres connection)
// answers every read waiting, of every endpoint, with one statement per kind of read present, each over arrays of
// distinct keys (`unnest(...) WITH ORDINALITY`): identical reads share one row, and every article in the batch is
// enriched once (tags, favorite count, author), however many reads show it. Rule 5 holds: only reads already queued
// when a batch is taken share it, and nothing outlives the batch. Results go back to each read's connection on its
// event loop, which writes the JSON.
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

/// A read's answer. Articles, comments and the tags body are written to JSON once per batch, into `json`, which
/// every result of the batch shares; each result says which parts of it are its own, with its viewer's flags.
enum ReadResult: Sendable {
    case page(total: Int64, articles: [ArticleView], json: ByteBuffer)
    case article(ArticleView?, json: ByteBuffer)
    case comments([CommentView]?, json: ByteBuffer)
    case profile(ProfileRow?)
    case user(UserRow?)
    case tags(Range<Int32>, json: ByteBuffer)
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

/// Feeds, shared between the viewers of a batch: the viewers' follows (kind 0: viewer, followee), each distinct
/// followee's article count capped at 1,000 (kind 1: followee, count), and each followee's newest articles, as many as
/// the most any of its viewers' pages needs (kind 2: followee, article id). A popular author is looked at once for
/// every viewer who follows them. The counts and pages are put together per viewer in BatchPlan.feedPages; they are
/// exactly the reference SQL's, since articles have one author: the count of a viewer's followees' articles capped at
/// 1,000 is the sum of the followees' counts capped at 1,000 each, then again at 1,000.
enum FeedSQL: BatchSQL {
    static let name = "b_feed"
    static let sql = """
        WITH v AS (SELECT * FROM unnest($1::int8[], $2::int8[]) r(viewer, want)),
             e AS (SELECT fo.follower_id AS viewer, fo.followee_id AS followee, v.want
                     FROM v JOIN follows fo ON fo.follower_id = v.viewer),
             d AS (SELECT followee, max(want) AS want FROM e GROUP BY followee)
        SELECT 0::int8, viewer, followee FROM e
        UNION ALL
        SELECT 1::int8, d.followee, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = d.followee LIMIT 1000) s)
          FROM d
        UNION ALL
        SELECT 2::int8, d.followee, x.id FROM d
          CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.author_id = d.followee ORDER BY a.id DESC LIMIT d.want) x
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

    struct Waiting: Sendable {
        let read: Read
        let viewer: Int64
        let since: ContinuousClock.Instant
        let replyTo: ReplyTo
    }

    private struct State {
        var queue: [Waiting] = []
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

    func waiting(_ read: Read, viewer: Int64, replyTo: ReplyTo) -> Waiting {
        Waiting(read: read, viewer: viewer, since: clock.now, replyTo: replyTo)
    }

    /// Queues reads for the next batch, all under one acquisition of the lock; their results go to their `replyTo`.
    /// Takes the array's contents and leaves it empty, keeping its capacity.
    func submit(_ reads: inout [Waiting]) {
        let (queued, wake) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
            if s.stopped { return (false, nil) }
            if s.queue.isEmpty { swap(&s.queue, &reads) } else { s.queue.append(contentsOf: reads) }
            defer { s.waitingForWork = nil }
            return (true, s.waitingForWork)
        }
        if !queued { Self.deliver(reads.map { ($0.replyTo, .failure(ApiError(.serviceUnavailable, "shutting down"))) }) }
        reads.removeAll(keepingCapacity: true)
        wake?.resume()
    }

    /// Hands results to their connections: one task per event loop, not one per read.
    private static func deliver(_ replies: [(ReplyTo, Result<ReadResult, any Error>)]) {
        var loops: [(loop: any EventLoop, replies: [(ReplyTo, Result<ReadResult, any Error>)])] = []
        for reply in replies {
            let loop = reply.0.connection.eventLoop
            if let i = loops.firstIndex(where: { $0.loop === loop }) {
                loops[i].replies.append(reply)
            } else {
                loops.append((loop, [reply]))
            }
        }
        for (loop, replies) in loops {
            loop.execute {
                for (to, result) in replies { to.connection.value.deliver(result, request: to.request) }
            }
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
        Self.deliver(queued.map { ($0.replyTo, .failure(ApiError(.serviceUnavailable, "shutting down"))) })
        for turn in turns { turn.resume() }
        work?.resume()
    }

    /// Answers batches, one at a time. A batch's statements run on pooled connections, several at once.
    private func lane() async {
        while let batch = await nextBatch() {
            await answer(batch)
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
            // The event loops queue reads under this lock, so it is held for as little as possible: the whole queue is
            // swapped out for an empty one, reserved here, before taking the lock.
            var batch: [Waiting] = []
            batch.reserveCapacity(min(settings.maxBatch, max(settings.minBatch, 2 * Int(state.withLock { $0.typicalBatch }))))
            let (next, stopped) = state.withLock { s -> (CheckedContinuation<Void, Never>?, Bool) in
                let count = min(s.queue.count, settings.maxBatch)
                if count == s.queue.count {
                    swap(&batch, &s.queue)
                } else {
                    batch.append(contentsOf: s.queue.prefix(count))
                    s.queue.removeFirst(count)
                }
                if count > 0 { s.typicalBatch = s.typicalBatch == 0 ? Double(count) : 0.9 * s.typicalBatch + 0.1 * Double(count) }
                let next = s.waitingForTurn.isEmpty ? nil : s.waitingForTurn.removeFirst()
                s.collecting = next != nil
                return (next, s.stopped)
            }
            next?.resume()
            if !batch.isEmpty { return batch }
            if stopped { return nil }
        }
    }

    /// Answers a batch; on failure every read in it gets the error.
    private func answer(_ batch: [Waiting]) async {
        do {
            var plan = BatchPlan(batch)
            try await plan.execute(on: db)
            Self.deliver(batch.indices.map { i in (batch[i].replyTo, .success(plan.result(i, viewer: batch[i].viewer))) })
        } catch {
            App.logger.error("read batch failed", metadata: ["error": "\(error)"])
            Self.deliver(batch.map { ($0.replyTo, .failure(error)) })
        }
    }
}

// ---------- one batch ----------

/// Distinct keys in first-seen order. A key's ordinal (1-based) is what the batched statements tag its rows with.
private struct Ordinals<Key: Hashable & Sendable>: Sendable {
    private(set) var keys: [Key] = []
    private var index: [Key: Int] = [:]

    mutating func ordinal(_ key: Key) -> Int {
        if let i = index[key] { return i }
        keys.append(key)
        index[key] = keys.count
        return keys.count
    }
}

private struct PageKey<Filter: Hashable & Sendable>: Hashable, Sendable {
    let filter: Filter
    let limit: Int64
    let offset: Int64
}

private struct ArticleRef: Sendable {
    let id: Int64
    let author: Int64
}

/// The distinct pages of one list kind in a batch, and what Postgres returned for them.
private struct PageFamily<Filter: Hashable & Sendable>: Sendable {
    var counts = Ordinals<Filter>()
    var pages = Ordinals<PageKey<Filter>>()
    /// Indexed by ordinal (1-based; the global list's one count is at 0), sized by `prepare` once the keys are known,
    /// so a batch's results take no dictionary of their own.
    var totals: [Int64] = []
    var rows: [[ArticleRef]] = []

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

private struct Pair: Hashable, Sendable {
    let viewer: Int64
    let target: Int64
}

private struct CommentRef: Sendable {
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
    /// Articles some page of the batch shows (single-article reads aside, which show the body too).
    private var listed = Set<Int64>()
    private var favorites = Set<Pair>()
    private var follows = Set<Pair>()

    // The batch's JSON (`render`) and where each part of it is.
    private var json = ByteBuffer()
    private var listSplices: [Int64: ArticleSplice] = [:]
    private var fullSplices: [Int64: ArticleSplice] = [:]
    private var threadSplices: [[(splice: CommentSplice, author: Int64)]?] = []
    private var tagsBody: Range<Int32> = 0..<0

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

    /// What one statement of the batch returned, from the child task that ran it.
    private enum Answer: Sendable {
        case all(PageFamily<Bool>)
        case tag(PageFamily<String>)
        case author(PageFamily<String>)
        case favorited(PageFamily<String>)
        case feed(PageFamily<Int64>)
        case articles([ArticleRef?])
        case threads([[CommentRef]?])
        case profiles([(id: Int64, row: ProfileRow)?])
        case users([UserRow?])
        case tags([PGText], [Int32: Int])
        case details([Int64: ArticleRow], [Int64: [Int32]])
        case flags(favorites: Set<Pair>, follows: Set<Pair>)
    }

    /// Two rounds of statements, each statement on a pooled connection of its own, so a batch takes about as long as
    /// its slowest statement per round instead of all of them in turn on one connection: what each read is about, then
    /// every article shown (once) and the viewer flags.
    mutating func execute(on db: PostgresClient) async throws {
        let showsArticles = !all.isEmpty || !byTag.isEmpty || !byAuthor.isEmpty || !byFavorite.isEmpty || !feed.isEmpty
            || !slugs.keys.isEmpty
        var rank: [Int32: Int] = [:]
        try await withThrowingTaskGroup(of: Answer.self) { group in
            if !all.isEmpty {
                var binds = PostgresBindings(capacity: 2)
                binds.append(all.pages.keys.map(\.limit))
                binds.append(all.pages.keys.map(\.offset))
                let family = all
                group.addTask { .all(try await Self.pages(PagesAllSQL.self, family, binds, db)) }
            }
            if !byTag.isEmpty {
                let (family, binds) = (byTag, try Self.filterBinds(byTag))
                group.addTask { .tag(try await Self.pages(PagesByTagSQL.self, family, binds, db)) }
            }
            if !byAuthor.isEmpty {
                let (family, binds) = (byAuthor, try Self.filterBinds(byAuthor))
                group.addTask { .author(try await Self.pages(PagesByAuthorSQL.self, family, binds, db)) }
            }
            if !byFavorite.isEmpty {
                let (family, binds) = (byFavorite, try Self.filterBinds(byFavorite))
                group.addTask { .favorited(try await Self.pages(PagesByFavoriteSQL.self, family, binds, db)) }
            }
            if !feed.isEmpty {
                let family = feed
                group.addTask { .feed(try await Self.feedPages(family, db)) }
            }
            if !slugs.keys.isEmpty {
                let (keys, refs) = (slugs.keys, articleRefs)
                group.addTask { .articles(try await Self.articleRefs(keys, refs, db)) }
            }
            if !commentSlugs.keys.isEmpty {
                let (keys, threads) = (commentSlugs.keys, threads)
                group.addTask { .threads(try await Self.threads(keys, threads, db)) }
            }
            if !usernames.keys.isEmpty {
                let (keys, profiles) = (usernames.keys, profiles)
                group.addTask { .profiles(try await Self.profiles(keys, profiles, db)) }
            }
            if !userIDs.keys.isEmpty {
                let (keys, users) = (userIDs.keys, users)
                group.addTask { .users(try await Self.users(keys, users, db)) }
            }
            if wantsTags || showsArticles {
                group.addTask { let (names, rank) = try await Self.tags(db); return .tags(names, rank) }
            }
            for try await answer in group {
                switch answer {
                case .all(let family): all = family
                case .tag(let family): byTag = family
                case .author(let family): byAuthor = family
                case .favorited(let family): byFavorite = family
                case .feed(let family): feed = family
                case .articles(let refs): articleRefs = refs
                case .threads(let found): threads = found
                case .profiles(let found): profiles = found
                case .users(let found): users = found
                case .tags(let names, let ranks): (tagNames, rank) = (names, ranks)
                case .details, .flags: break
                }
            }
        }

        var ids = Set<Int64>()
        ids.reserveCapacity(slots.count * 4)
        var favoritePairs = Set<Pair>()
        var followPairs = Set<Pair>()
        /// A feed's articles are by authors its viewer follows: no lookup needed.
        var followed = Set<Pair>()
        for (i, slot) in slots.enumerated() {
            let viewer = viewers[i]
            func show(_ refs: [ArticleRef], listed isListed: Bool = true, followed isFollowed: Bool = false) {
                for ref in refs {
                    ids.insert(ref.id)
                    if isListed { listed.insert(ref.id) }
                    if viewer != 0 {
                        favoritePairs.insert(Pair(viewer: viewer, target: ref.id))
                        if isFollowed {
                            followed.insert(Pair(viewer: viewer, target: ref.author))
                        } else {
                            followPairs.insert(Pair(viewer: viewer, target: ref.author))
                        }
                    }
                }
            }
            switch slot {
            case .all(let page): show(all.rows[page])
            case .tag(_, let page): show(byTag.rows[page])
            case .author(_, let page): show(byAuthor.rows[page])
            case .favorited(_, let page): show(byFavorite.rows[page])
            case .feed(_, let page): show(feed.rows[page], followed: true)
            case .article(let k): if let ref = articleRefs[k] { show([ref], listed: false) }
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
        try await withThrowingTaskGroup(of: Answer.self) { group in
            if !ids.isEmpty {
                let (shown, bodies) = (Array(ids), articleRefs.compactMap { $0?.id })
                group.addTask { let (rows, tags) = try await Self.details(shown, bodies: bodies, db); return .details(rows, tags) }
            }
            if !favoritePairs.isEmpty || !followPairs.isEmpty {
                let (favoritePairs, followPairs) = (favoritePairs, followPairs)
                group.addTask {
                    let (favorites, follows) = try await Self.flags(favoritePairs, followPairs, db)
                    return .flags(favorites: favorites, follows: follows)
                }
            }
            for try await answer in group {
                switch answer {
                case .details(let rows, let tags): (details, tagIDs) = (rows, tags)
                case .flags(let favorited, let following): (favorites, follows) = (favorited, following)
                default: break
                }
            }
        }

        follows.formUnion(followed)

        // The tags table was read alongside the first round, so an article created since may name a tag it doesn't
        // have yet; then it is read again. Tags are never deleted, so the second read has every tag the details name.
        if tagIDs.values.contains(where: { $0.contains { rank[$0] == nil } }) {
            (tagNames, rank) = try await Self.tags(db)
        }
        for (id, tags) in tagIDs {
            details[id]?.tagList = tags.compactMap { rank[$0] }.sorted().map { tagNames[$0] }
        }
        render()
    }

    // ---------- the statements, each on a pooled connection ----------

    private static func rows<Q: BatchSQL>(_ sql: Q.Type, _ binds: PostgresBindings, _ db: PostgresClient) async throws
        -> AsyncThrowingMapSequence<PostgresRowSequence, PostgresRow> {
        try await db.execute(BatchStatement<Q>(binds: binds), logger: App.queryLogger)
    }

    private static func filterBinds<F>(_ family: PageFamily<F>) throws -> PostgresBindings where F: PostgresArrayEncodable {
        var binds = PostgresBindings(capacity: 4)
        try binds.append(family.counts.keys)
        try binds.append(family.pages.keys.map(\.filter))
        binds.append(family.pages.keys.map(\.limit))
        binds.append(family.pages.keys.map(\.offset))
        return binds
    }

    private static func pages<Q: BatchSQL, F>(_ sql: Q.Type, _ family: PageFamily<F>, _ binds: PostgresBindings,
                                              _ db: PostgresClient) async throws -> PageFamily<F> {
        var family = family
        for try await row in try await rows(sql, binds, db) { try family.take(row) }
        return family
    }

    /// The batch's feeds from FeedSQL: each viewer's total, and each page merged from its viewer's followees' newest
    /// articles (each list newest first; a page takes the next newest head `offset + limit` times).
    private static func feedPages(_ family: PageFamily<Int64>, _ db: PostgresClient) async throws -> PageFamily<Int64> {
        var family = family
        let viewers = family.counts.keys
        var slot: [Int64: Int] = [:]
        slot.reserveCapacity(viewers.count)
        for (i, viewer) in viewers.enumerated() { slot[viewer] = i }
        var want = [Int64](repeating: 0, count: viewers.count)
        for key in family.pages.keys {
            let i = slot[key.filter]!
            want[i] = max(want[i], key.limit + key.offset)
        }
        var binds = PostgresBindings(capacity: 2)
        binds.append(viewers)
        binds.append(want)

        var followees = [[Int64]](repeating: [], count: viewers.count)
        var counts: [Int64: Int64] = [:]
        var newest: [Int64: [Int64]] = [:]
        for try await row in try await rows(FeedSQL.self, binds, db) {
            var cells = RowCursor(row)
            let kind = try cells.int()
            let a = try cells.int()
            let b = try cells.int()
            switch kind {
            case 0: followees[slot[a]!].append(b)
            case 1: counts[a] = b
            case 2: newest[a, default: []].append(b)
            default: throw RowError.typeMismatch("feed row kind", .int8)
            }
        }
        for followee in newest.keys { newest[followee]!.sort(by: >) }

        for i in viewers.indices {
            var total: Int64 = 0
            for followee in followees[i] { total += counts[followee] ?? 0 }
            family.totals[i + 1] = min(total, 1000)
        }
        for (k, key) in family.pages.keys.enumerated() {
            let sources = followees[slot[key.filter]!]
            var heads = [Int](repeating: 0, count: sources.count)
            var page: [ArticleRef] = []
            page.reserveCapacity(Int(key.limit))
            var taken: Int64 = 0
            while taken < key.offset + key.limit {
                var best = -1
                var bestID = Int64.min
                for s in sources.indices {
                    guard let list = newest[sources[s]], heads[s] < list.count, list[heads[s]] > bestID else { continue }
                    best = s
                    bestID = list[heads[s]]
                }
                guard best >= 0 else { break }
                heads[best] += 1
                if taken >= key.offset { page.append(ArticleRef(id: bestID, author: sources[best])) }
                taken += 1
            }
            family.rows[k + 1] = page
        }
        return family
    }

    private static func articleRefs(_ slugs: [String], _ refs: [ArticleRef?], _ db: PostgresClient) async throws -> [ArticleRef?] {
        var refs = refs
        var binds = PostgresBindings(capacity: 1)
        binds.append(slugs)
        for try await row in try await rows(ArticlesBySlugSQL.self, binds, db) {
            var cells = RowCursor(row)
            let k = try cells.int()
            refs[Int(k)] = ArticleRef(id: try cells.int(), author: try cells.int())
        }
        return refs
    }

    private static func threads(_ slugs: [String], _ threads: [[CommentRef]?], _ db: PostgresClient) async throws -> [[CommentRef]?] {
        var threads = threads
        var binds = PostgresBindings(capacity: 1)
        binds.append(slugs)
        for try await row in try await rows(CommentsBySlugSQL.self, binds, db) {
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
        return threads
    }

    private static func profiles(_ usernames: [String], _ profiles: [(id: Int64, row: ProfileRow)?],
                                 _ db: PostgresClient) async throws -> [(id: Int64, row: ProfileRow)?] {
        var profiles = profiles
        var binds = PostgresBindings(capacity: 1)
        binds.append(usernames)
        for try await row in try await rows(ProfilesByNameSQL.self, binds, db) {
            var cells = RowCursor(row)
            let k = Int(try cells.int())
            let id = try cells.int()
            let username = try cells.text()
            let bio = try cells.textOrNull()
            let image = try cells.textOrNull()
            profiles[k] = (id, ProfileRow(username: username, bio: bio, image: image, following: false))
        }
        return profiles
    }

    private static func users(_ ids: [Int64], _ users: [UserRow?], _ db: PostgresClient) async throws -> [UserRow?] {
        var users = users
        var binds = PostgresBindings(capacity: 1)
        binds.append(ids)
        for try await row in try await rows(UsersByIDSQL.self, binds, db) {
            var cells = RowCursor(row)
            let k = Int(try cells.int())
            users[k] = try cells.user().user
        }
        return users
    }

    /// Tag names in the database's name order, and each tag id's place in that order.
    private static func tags(_ db: PostgresClient) async throws -> ([PGText], [Int32: Int]) {
        var names: [PGText] = []
        var rank: [Int32: Int] = [:]
        rank.reserveCapacity(256)
        for try await row in try await rows(TagsSQL.self, PostgresBindings(), db) {
            var cells = RowCursor(row)
            rank[try cells.int4()] = names.count
            names.append(try cells.text())
        }
        return (names, rank)
    }

    private static func details(_ ids: [Int64], bodies: [Int64], _ db: PostgresClient) async throws
        -> ([Int64: ArticleRow], [Int64: [Int32]]) {
        var details: [Int64: ArticleRow] = [:]
        var tagIDs: [Int64: [Int32]] = [:]
        details.reserveCapacity(ids.count)
        tagIDs.reserveCapacity(ids.count)
        var binds = PostgresBindings(capacity: 2)
        binds.append(ids)
        binds.append(bodies)
        for try await row in try await rows(ArticleDetailsSQL.self, binds, db) {
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
        return (details, tagIDs)
    }

    private static func flags(_ favoritePairs: Set<Pair>, _ followPairs: Set<Pair>, _ db: PostgresClient) async throws
        -> (Set<Pair>, Set<Pair>) {
        var favorites = Set<Pair>()
        var follows = Set<Pair>()
        var binds = PostgresBindings(capacity: 4)
        binds.append(favoritePairs.map(\.viewer))
        binds.append(favoritePairs.map(\.target))
        binds.append(followPairs.map(\.viewer))
        binds.append(followPairs.map(\.target))
        for try await row in try await rows(ViewerFlagsSQL.self, binds, db) {
            var cells = RowCursor(row)
            let kind = try cells.int()
            let pair = Pair(viewer: try cells.int(), target: try cells.int())
            switch kind {
            case 0: favorites.insert(pair)
            case 1: follows.insert(pair)
            default: throw RowError.typeMismatch("flag kind", .int8)
            }
        }
        return (favorites, follows)
    }

    /// Writes everything the batch's results show into one buffer, each article and comment once (with their
    /// viewer-dependent values left open) however many results show them: the results copy their parts on their
    /// connections' event loops.
    private mutating func render() {
        var out = JSONWriter(capacity: (listed.count + slugs.keys.count) * 640 + (wantsTags ? 64 + tagNames.count * 24 : 0))
        if wantsTags {
            let start = out.position
            out.raw("{\"tags\":[")
            for i in tagNames.indices {
                if i > 0 { out.raw(",") }
                out.string(tagNames[i])
            }
            out.raw("]}")
            tagsBody = Int32(start)..<Int32(out.position)
        }
        listSplices.reserveCapacity(listed.count)
        for id in listed {
            if let row = details[id] { listSplices[id] = out.articleSplice(row, full: false) }
        }
        for ref in articleRefs {
            guard let ref, fullSplices[ref.id] == nil, let row = details[ref.id] else { continue }
            fullSplices[ref.id] = out.articleSplice(row, full: true)
        }
        if !threads.isEmpty {
            threadSplices = Array(repeating: nil, count: threads.count)
            for k in threads.indices {
                guard let thread = threads[k] else { continue }
                let newestFirst = thread.sorted {
                    $0.row.createdAt.micros != $1.row.createdAt.micros
                        ? $0.row.createdAt.micros > $1.row.createdAt.micros : $0.row.id > $1.row.id
                }
                var splices: [(splice: CommentSplice, author: Int64)] = []
                splices.reserveCapacity(newestFirst.count)
                for comment in newestFirst { splices.append((out.commentSplice(comment.row), comment.author)) }
                threadSplices[k] = splices
            }
        }
        json = out.finish()
    }

    // ---------- results ----------

    func result(_ i: Int, viewer: Int64) -> ReadResult {
        switch slots[i] {
        case .all(let page): return .page(total: all.totals[0], articles: views(all.rows[page], viewer: viewer), json: json)
        case .tag(let count, let page):
            return .page(total: byTag.totals[count], articles: views(byTag.rows[page], viewer: viewer), json: json)
        case .author(let count, let page):
            return .page(total: byAuthor.totals[count], articles: views(byAuthor.rows[page], viewer: viewer), json: json)
        case .favorited(let count, let page):
            return .page(total: byFavorite.totals[count], articles: views(byFavorite.rows[page], viewer: viewer), json: json)
        case .feed(let count, let page):
            return .page(total: feed.totals[count], articles: views(feed.rows[page], viewer: viewer), json: json)
        case .article(let k):
            guard let ref = articleRefs[k], let splice = fullSplices[ref.id] else { return .article(nil, json: json) }
            return .article(view(ref, splice, viewer: viewer), json: json)
        case .comments(let k):
            guard let thread = threadSplices[k] else { return .comments(nil, json: json) }
            return .comments(thread.map { comment in
                CommentView(splice: comment.splice, following: follows.contains(Pair(viewer: viewer, target: comment.author)))
            }, json: json)
        case .profile(let k):
            guard let profile = profiles[k] else { return .profile(nil) }
            var row = profile.row
            row.following = follows.contains(Pair(viewer: viewer, target: profile.id))
            return .profile(row)
        case .user(let k): return .user(users[k])
        case .tags: return .tags(tagsBody, json: json)
        }
    }

    private func view(_ ref: ArticleRef, _ splice: ArticleSplice, viewer: Int64) -> ArticleView {
        ArticleView(splice: splice,
                    favorited: favorites.contains(Pair(viewer: viewer, target: ref.id)),
                    following: follows.contains(Pair(viewer: viewer, target: ref.author)))
    }

    /// A page's articles, newest first, with this viewer's flags.
    private func views(_ refs: [ArticleRef], viewer: Int64) -> [ArticleView] {
        refs.sorted { $0.id > $1.id }.compactMap { ref in
            listSplices[ref.id].map { view(ref, $0, viewer: viewer) }
        }
    }
}

/// One event loop's reads, gathered during its current tick and handed to the batcher together once the tick's
/// I/O is done: the event loops take the batcher's lock once per tick instead of once per request. Lives on its
/// loop (NIOLoopBound), like the connections that use it.
final class ReadOutbox {
    private let batcher: ReadBatcher
    private let loop: any EventLoop
    private var pending: [ReadBatcher.Waiting] = []
    private var flushScheduled = false

    init(batcher: ReadBatcher, loop: any EventLoop) {
        self.batcher = batcher
        self.loop = loop
    }

    func submit(_ read: Read, viewer: Int64, replyTo: ReplyTo) {
        pending.append(batcher.waiting(read, viewer: viewer, replyTo: replyTo))
        guard !flushScheduled else { return }
        flushScheduled = true
        loop.assumeIsolated().execute {
            self.flushScheduled = false
            self.batcher.submit(&self.pending)
        }
    }
}
