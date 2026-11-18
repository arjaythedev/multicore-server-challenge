// Cross-request read batching. A read waits a few milliseconds in one queue; then a lane answers every read waiting,
// of every endpoint, with one statement per kind of read present, each over arrays of distinct keys
// (`unnest(...) WITH ORDINALITY`): identical reads share one row, and every article in the batch is enriched once
// (tags, favorite count, author), however many reads show it. Rule 5 holds: only reads already queued when a batch is
// taken share it, and nothing outlives the batch. A lane is a task on one event loop with a few Postgres connections
// of its own on that loop (Postgres.swift): a batch's statements are spread over them, each connection's share sent
// in one write, all of them before any answer is awaited, so the backends work at once and a batch costs two round
// trips. Every row of the batch is copied into one buffer and read in place; its articles, comment threads, profiles,
// users and tags body are written to JSON once, and each read's task gets its parts of that.
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
    case login(email: String)
    case tags
}

/// A read's answer: parts of its batch's JSON (`json`, shared by every result of the batch), with its viewer's flags.
enum ReadResult: Sendable {
    case page(total: Int64, articles: [ArticleView], json: JSONBytes)
    case article(ArticleView?, json: JSONBytes)
    case comments([CommentView]?, json: JSONBytes)
    case profile(ProfileView?, json: JSONBytes)
    case user(UserSplice?, json: JSONBytes)
    case login(LoginView?, json: JSONBytes)
    case tags(Range<Int32>, json: JSONBytes)
}

// ---------- SQL ----------
// Page statements return the counts (k <= 0: the count of key -k) and the page rows (k > 0: an article id and its
// author) of every distinct page in the batch. Counts and pages are exactly the reference SQL's, keyed by array.

/// The batch statements are prepared once per connection.
typealias BatchSQL = PGPrepared

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

/// Feeds: each viewer's count of its followees' articles, capped at 1,000 (k <= 0: -k's count), and each page, merged
/// here from the viewer's followees' newest articles (k > 0: a page row), exactly the reference SQL's. Only the pages
/// leave Postgres: merging followees' newest articles on our side instead had Postgres send every followee's (about
/// 7,000 rows per batch on the full seed, nearly nine in ten of all the rows a batch read) for our side to parse and
/// merge.
///
/// $1/$2 are the viewers and each one's deepest page (limit + offset), $3-$5 the pages (the viewer's ordinal, limit,
/// offset). As rust-epoll-theCatWisel's feed (#154), the authors several of the batch's viewers follow (its hubs, up
/// to 32) are looked at once for the whole batch: whether each has 1,000 articles, so a viewer who follows one counts
/// 1,000 without counting (most viewers on the full seed do), and its floor, the article as deep as the deepest page
/// of the viewers who follow it. That author alone has that many articles at or above it, so no page of theirs reaches
/// below it, and a page reads each followee's newest articles only down to the highest floor among its hubs. Any
/// other viewer's count stops at the 1,000th article over all their followees. On the full seed, batches of 16 feeds
/// took half the Postgres time and a third fewer buffer pages this way than counting every viewer and reading each
/// followee down to the page's depth, with the same rows.
enum FeedSQL: BatchSQL {
    static let name = "b_feed"
    static let sql = """
        WITH v AS MATERIALIZED (
               SELECT r.k, r.depth, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer) AS followees
                 FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(viewer, depth, k)),
             hubs AS MATERIALIZED (
               SELECT h.author,
                      (SELECT a.id FROM articles a WHERE a.author_id = h.author
                        ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id,
                      EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.author ORDER BY a.id LIMIT 1 OFFSET 999) AS big
                 FROM (SELECT f.author, max(v.depth) AS depth FROM v, unnest(v.followees) f(author)
                        GROUP BY f.author HAVING count(*) >= 2 ORDER BY count(*) DESC, f.author LIMIT 32) h)
        SELECT -v.k, CASE WHEN v.followees && ARRAY(SELECT h.author FROM hubs h WHERE h.big) THEN 1000
                          ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(v.followees)
                                                       LIMIT 1000) s) END, NULL::int8
          FROM v
        UNION ALL
        SELECT p.k, x.id, x.author_id
          FROM unnest($3::int8[], $4::int8[], $5::int8[]) WITH ORDINALITY p(viewer, lim, off, k)
          JOIN v ON v.k = p.viewer
          CROSS JOIN LATERAL (SELECT coalesce(max(h.floor_id), 0) AS id FROM hubs h WHERE h.author = ANY(v.followees)) fl
          CROSS JOIN LATERAL (SELECT n.id, n.author_id FROM unnest(v.followees) fid
                               CROSS JOIN LATERAL (SELECT a.id, a.author_id FROM articles a
                                                    WHERE a.author_id = fid AND a.id >= fl.id
                                                    ORDER BY a.id DESC LIMIT p.lim + p.off) n
                              ORDER BY n.id DESC LIMIT p.lim OFFSET p.off) x
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
/// for no such article. Each slug comes with its ordinal (`$2`), so a long list can be split over several connections.
/// Only the authors' ids: the batch's comment authors are read once each, in the second round (CommentAuthorsSQL).
enum CommentsBySlugSQL: BatchSQL {
    static let name = "b_comments_slug"
    static let sql = """
        SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id
          FROM unnest($1::text[], $2::int8[]) r(slug, k) JOIN articles a ON a.slug = r.slug
          LEFT JOIN LATERAL (SELECT cm.id, cm.body, cm.created_at, cm.updated_at, cm.author_id FROM comments cm
                              WHERE cm.article_id = a.id ORDER BY cm.created_at DESC, cm.id DESC LIMIT 100) c ON true
        """
}

/// The batch's distinct comment authors, in one sorted index scan (`= ANY`) instead of a lookup per comment: on the
/// full seed a comment row cost 4.4 buffer pages with its author joined in, against about 1.7 without.
enum CommentAuthorsSQL: BatchSQL {
    static let name = "b_comment_authors"
    static let sql = "SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY($1::int8[])"
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
/// Each table is read once for the whole set (`= ANY` over the ids, one grouped favorites count, each author once)
/// instead of an index descent per article per table: the articles a batch shows are mostly recent, so they sit next
/// to each other in the indexes. On the full seed that touched a quarter fewer buffer pages for 194 articles, and a
/// fifth as many for 4,888, with the same rows.
enum ArticleDetailsSQL: BatchSQL {
    static let name = "b_article_details"
    static let sql = """
        WITH a AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, CASE WHEN a.id = ANY($2::int8[]) THEN a.body END AS body,
                                       a.created_at, a.updated_at, a.author_id
                                  FROM articles a WHERE a.id = ANY($1::int8[])),
             t AS (SELECT x.article_id, array_agg(x.tag_id) AS tags FROM article_tags x WHERE x.article_id = ANY($1::int8[])
                    GROUP BY x.article_id),
             f AS (SELECT x.article_id, count(*) AS n FROM favorites x WHERE x.article_id = ANY($1::int8[]) GROUP BY x.article_id),
             u AS (SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY(ARRAY(SELECT DISTINCT author_id FROM a)))
        SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, coalesce(t.tags, '{}'::int4[]),
               coalesce(f.n, 0), u.username, u.bio, u.image
          FROM a JOIN u ON u.id = a.author_id LEFT JOIN t ON t.article_id = a.id LEFT JOIN f ON f.article_id = a.id
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

/// Logins: email -> the user and the stored hash (bcrypt then runs in the login's own task).
enum LoginsByEmailSQL: BatchSQL {
    static let name = "b_logins"
    static let sql = """
        SELECT r.k, u.id, u.username, u.email, u.bio, u.image, u.password_hash
          FROM unnest($1::text[]) WITH ORDINALITY r(email, k) JOIN users u ON u.email = r.email
        """
}

// ---------- the queue and its lanes ----------

final class ReadBatcher: Service {
    struct Settings {
        /// Lanes, each answering one batch at a time; lane i runs on event loop i (modulo their number).
        var lanes: Int
        /// Postgres connections each lane holds, on its event loop.
        var connections: Int
        /// How long the oldest read waits for others before its batch is taken, so a batch grows with the load. On the
        /// full seed at 30k requests a second, 30 ms (batches of about 450 reads, as rust-epoll-theCatWisel's) touched
        /// 14% fewer buffer pages per read than 10 ms, as few as that entry; it adds to every read's latency.
        var window: Duration
        /// The most reads one batch takes; a queue this long is taken at once.
        var maxBatch: Int
    }

    /// Where a read's result goes: the task awaiting it (resumed from its loop, if it runs on one), or (READ_TASKS=0)
    /// its connection, on the connection's loop.
    enum Reply: Sendable {
        case task(CheckedContinuation<ReadResult, any Error>, on: Loop?)
        case connection(ReplyTo)
    }

    struct Waiting: Sendable {
        let read: Read
        let viewer: Int64
        let since: ContinuousClock.Instant
        let reply: Reply
    }

    private struct State {
        var queue: [Waiting] = []
        /// One lane at a time collects the next batch; the others wait for their turn here.
        var collecting = false
        var waitingForTurn: [CheckedContinuation<Void, Never>] = []
        /// The collecting lane, while the queue is empty.
        var waitingForWork: CheckedContinuation<Void, Never>?
        /// Moving average of recent batch sizes, to size the next batch's array up front.
        var typicalBatch = 0.0
        var stopped = false
    }

    private let config: PGConfig
    private let settings: Settings
    private let state = Mutex(State())
    private let clock = ContinuousClock()

    init(config: PGConfig, settings: Settings) {
        self.config = config
        self.settings = settings
    }

    func waiting(_ read: Read, viewer: Int64, reply: Reply) -> Waiting {
        Waiting(read: read, viewer: viewer, since: clock.now, reply: reply)
    }

    /// Queues reads for the next batch, all under one acquisition of the lock; their results go to their `reply`.
    /// Takes the array's contents and leaves it empty, keeping its capacity.
    func submit(_ reads: inout [Waiting]) {
        let (queued, wake) = state.withLock { s -> (Bool, CheckedContinuation<Void, Never>?) in
            if s.stopped { return (false, nil) }
            if s.queue.isEmpty { swap(&s.queue, &reads) } else { s.queue.append(contentsOf: reads) }
            defer { s.waitingForWork = nil }
            return (true, s.waitingForWork)
        }
        if !queued { Self.deliver(reads.map { ($0.reply, .failure(ApiError(.serviceUnavailable, "shutting down"))) }) }
        reads.removeAll(keepingCapacity: true)
        wake?.resume()
    }

    /// Queues one read from a task that isn't a connection's (a login's) and waits for its result.
    func read(_ read: Read, viewer: Int64) async throws -> ReadResult {
        try await withCheckedThrowingContinuation { continuation in
            var one = [waiting(read, viewer: viewer, reply: .task(continuation, on: nil))]
            submit(&one)
        }
    }

    /// Hands the results over with one job per loop: each loop resumes its own tasks (so each resumption is queued on
    /// that loop without a lock) or (READ_TASKS=0) delivers to its own connections. A task on no loop (a login's) is
    /// resumed from here.
    private static func deliver(_ replies: [(Reply, Result<ReadResult, any Error>)]) {
        var loops = [[(Reply, Result<ReadResult, any Error>)]](repeating: [], count: Loop.all.count)
        for (reply, result) in replies {
            switch reply {
            case .task(let continuation, let loop):
                guard let loop else {
                    continuation.resume(with: result)
                    continue
                }
                loops[loop.index].append((reply, result))
            case .connection(let to):
                loops[to.connection.loop.index].append((reply, result))
            }
        }
        for (i, replies) in loops.enumerated() where !replies.isEmpty {
            Loop.all[i].execute {
                for (reply, result) in replies {
                    switch reply {
                    case .task(let continuation, _): continuation.resume(with: result)
                    case .connection(let to): to.connection.value.deliver(result, request: to.request)
                    }
                }
            }
        }
    }

    func run() async throws {
        await withDiscardingTaskGroup { group in
            for i in 0..<settings.lanes {
                let loop = Loop.all[i % Loop.all.count]
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
        let (queued, turns, work) = state.withLock { s in
            s.stopped = true
            defer { s.queue = []; s.waitingForTurn = []; s.waitingForWork = nil }
            return (s.queue, s.waitingForTurn, s.waitingForWork)
        }
        Self.deliver(queued.map { ($0.reply, .failure(ApiError(.serviceUnavailable, "shutting down"))) })
        for turn in turns { turn.resume() }
        work?.resume()
    }

    /// Answers batches, one at a time, on its connections. Runs on `loop`, where its connections live, so a reply
    /// from Postgres resumes it on the thread that read it. A closed connection is replaced before the next batch.
    private func lane(on loop: Loop) async {
        var connections: [PGConnection] = []
        while !isStopped {
            connections.removeAll { $0.isClosed }
            while connections.count < settings.connections, !isStopped {
                do {
                    connections.append(try await PGConnection.connect(config, on: loop))
                } catch {
                    App.logger.error("read lane could not connect", metadata: ["error": "\(error)"])
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            guard let batch = await nextBatch() else { break }
            await answer(batch, on: connections)
        }
        for connection in connections { connection.close() }
    }

    /// Waits for this lane's turn to collect, then until the queue's oldest read has waited `window` or the queue holds
    /// `maxBatch`, and takes the batch. nil once stopped.
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
                    guard !s.stopped, let oldest = s.queue.first, s.queue.count < settings.maxBatch else { return nil }
                    return oldest.since + settings.window
                }
                guard let deadline, deadline > clock.now else { break }
                try? await Task.sleep(until: deadline, clock: clock)
            }
            // The event loops queue reads under this lock, so it is held for as little as possible: the whole queue is
            // swapped out for an empty one, reserved here, before taking the lock.
            var batch: [Waiting] = []
            batch.reserveCapacity(min(settings.maxBatch, max(64, 2 * Int(state.withLock { $0.typicalBatch }))))
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
    private func answer(_ batch: [Waiting], on connections: [PGConnection]) async {
        do {
            guard !connections.isEmpty else { throw PGConnectionError.closed }
            var plan = BatchPlan(batch)
            try await plan.execute(on: connections)
            Self.deliver(batch.indices.map { i in (batch[i].reply, .success(plan.result(i, viewer: batch[i].viewer))) })
        } catch {
            App.logger.error("read batch failed", metadata: ["error": "\(error)"])
            Self.deliver(batch.map { ($0.reply, .failure(error)) })
        }
    }
}

// ---------- one round ----------

/// One round of a batch's statements: spread over the lane's connections, each connection's share pipelined in one
/// request, every request sent before any answer is awaited (so the backends work at once), and every row written
/// straight into the batch's buffer as it arrives.
private struct Round {
    private let connections: [PGConnection]
    private var requests: [PGRequest]
    /// Each statement's parts: the connection each went on, and its index in that connection's request.
    private var placement: [[(connection: Int, index: Int)]] = []
    private var nextConnection = 0

    init(_ connections: [PGConnection]) {
        self.connections = connections
        requests = connections.map { $0.request() }
    }

    /// Adds a statement, on the next connection in turn; returns its place in `run`'s answer.
    mutating func add(_ build: (inout PGRequest) -> Void) -> Int {
        add(parts: 1) { request, _ in build(&request) }
    }

    /// Adds a statement as `parts` executions, each on the next connection in turn, so a large one runs on several
    /// backends at once instead of making the whole batch wait for one; `build(&request, part)` adds part `part`.
    /// Returns its place in `run`'s answer, where its rows are all of its parts', in order.
    mutating func add(parts: Int, _ build: (inout PGRequest, Int) -> Void) -> Int {
        var pieces: [(connection: Int, index: Int)] = []
        for part in 0..<max(1, parts) {
            let c = nextConnection % requests.count
            nextConnection += 1
            pieces.append((c, requests[c].count))
            build(&requests[c], part)
        }
        placement.append(pieces)
        return placement.count - 1
    }

    /// How many parts `count` keys make at about `size` keys a part, one per connection at most.
    func parts(_ count: Int, perPart size: Int) -> Int {
        min(requests.count, max(1, (count + size - 1) / size))
    }

    /// Runs the round. Its rows are appended to `arena`; returns each statement's rows, as ranges of `arena`.
    func run(into arena: inout Bytes) async throws -> [PGRowRanges] {
        guard !placement.isEmpty else { return [] }
        // The arena is moved into the sink for the round and back out after it, so it has one owner throughout.
        var moved = Bytes()
        swap(&moved, &arena)
        let sink = PGRowSink(moved)
        defer { swap(&arena, &sink.rows) }
        var replies: [PGReply] = []
        replies.reserveCapacity(requests.count)
        for c in requests.indices { replies.append(connections[c].send(requests[c], into: sink)) }
        var results: [PGResults] = []
        for reply in replies { results.append(try await reply.value()) }
        return try placement.map { pieces in
            if pieces.count == 1 { return try results[pieces[0].connection].rows(pieces[0].index) }
            var starts: [Int32] = []
            var ends: [Int32] = []
            for piece in pieces {
                let rows = try results[piece.connection].rows(piece.index)
                starts += rows.starts
                ends += rows.ends
            }
            return PGRowRanges(starts: starts, ends: ends, base: 0)
        }
    }
}

/// Part `part` of `count` keys split into `parts` nearly equal runs.
private func slice(_ count: Int, _ part: Int, of parts: Int) -> Range<Int> {
    (count * part / parts)..<(count * (part + 1) / parts)
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

    /// The ordinal of a key already seen.
    func ordinal(of key: Key) -> Int? { index[key] }
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
    mutating func take(_ statement: PGRowRanges, _ arena: borrowing Bytes) throws(PGCursorError) {
        for row in statement {
            var cells = row
            let k = Int(try cells.int(arena))
            let value = try cells.int(arena)
            if k <= 0 {
                totals[-k] = value
            } else {
                if rows[k].isEmpty { rows[k].reserveCapacity(Int(pages.keys[k - 1].limit)) }
                rows[k].append(ArticleRef(id: value, author: try cells.int(arena)))
            }
        }
    }
}

private struct CommentRef: Sendable {
    /// Its author's profile is filled in from the second round (CommentAuthorsSQL).
    var row: CommentRow
    let author: Int64
}

private struct BatchPlan: ~Copyable {
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
        case login(Int)
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
    private var logins = Ordinals<String>()
    private var wantsTags = false

    /// Every row of the batch, copied from each connection's answer; the rows below point into it.
    private var arena = Bytes(capacity: 64 * 1024)

    // Indexed by the ordinal of their key (1-based), sized at the end of init.
    private var articleRefs: [ArticleRef?] = []
    private var threads: [[CommentRef]?] = []
    private var profiles: [(id: Int64, row: ProfileRow)?] = []
    private var users: [UserRow?] = []
    private var loginRows: [(id: Int64, hash: String, user: UserRow)?] = []
    private var tagNames: [PGTextRef] = []
    private var details = IntTable<Int64, ArticleRow>()
    /// Articles some page of the batch shows (single-article reads aside, which show the body too).
    private var listed = IntSet<Int64>()
    private var favorites = IntSet<Pair>()
    private var follows = IntSet<Pair>()

    // The batch's JSON (`render`) and where each part of it is.
    private var json = JSONBytes.empty
    private var listSplices = IntTable<Int64, ArticleSplice>()
    private var fullSplices = IntTable<Int64, ArticleSplice>()
    private var threadSplices: [[(splice: CommentSplice, author: Int64)]?] = []
    private var profileSplices: [(id: Int64, splice: ProfileSplice)?] = []
    private var userSplices: [UserSplice?] = []
    private var loginViews: [LoginView?] = []
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
            case .login(let email):
                slots.append(.login(logins.ordinal(email)))
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
        if !logins.keys.isEmpty { loginRows = Array(repeating: nil, count: logins.keys.count + 1) }
    }

    private let viewers: [Int64]
    /// A comment's author until the second round has read it.
    private static let noProfile = ProfileRow(username: PGTextRef(start: 0, count: 0), bio: nil, image: nil, following: false)

    // ---------- execution ----------

    /// Two rounds of statements, spread over the lane's connections: what each read is about, then every article
    /// shown (once) and the viewer flags.
    mutating func execute(on connections: [PGConnection]) async throws {
        let showsArticles = !all.isEmpty || !byTag.isEmpty || !byAuthor.isEmpty || !byFavorite.isEmpty || !feed.isEmpty
            || !slugs.keys.isEmpty
        var first = Round(connections)
        var at: [String: Int] = [:]
        if !all.isEmpty {
            let pages = all.pages.keys
            at["all"] = first.add { $0.execute(PagesAllSQL.self) { b in b.int8Array(pages.map(\.limit)); b.int8Array(pages.map(\.offset)) } }
        }
        for (key, family, sql) in [("tag", byTag, PagesByTagSQL.self as any BatchSQL.Type), ("author", byAuthor, PagesByAuthorSQL.self),
                                   ("favorited", byFavorite, PagesByFavoriteSQL.self)] where !family.isEmpty {
            let counts = family.counts.keys
            let pages = family.pages.keys
            at[key] = first.add { request in
                request.execute(sql) { b in
                    b.textArray(counts)
                    b.textArray(pages.map(\.filter))
                    b.int8Array(pages.map(\.limit))
                    b.int8Array(pages.map(\.offset))
                }
            }
        }
        if !feed.isEmpty {
            let (viewers, pages) = (feed.counts.keys, feed.pages.keys)
            // Each page's viewer (by ordinal), and each viewer's deepest page.
            var depths = [Int64](repeating: 1, count: viewers.count)
            let owners = pages.map { page in
                let k = feed.counts.ordinal(of: page.filter)!
                depths[k - 1] = max(depths[k - 1], page.limit + page.offset)
                return Int64(k)
            }
            at["feed"] = first.add { request in
                request.execute(FeedSQL.self) { b in
                    b.int8Array(viewers)
                    b.int8Array(depths)
                    b.int8Array(owners)
                    b.int8Array(pages.map(\.limit))
                    b.int8Array(pages.map(\.offset))
                }
            }
        }
        if !slugs.keys.isEmpty {
            let keys = slugs.keys
            at["slugs"] = first.add { $0.execute(ArticlesBySlugSQL.self) { b in b.textArray(keys) } }
        }
        if !commentSlugs.keys.isEmpty {
            let keys = commentSlugs.keys
            let parts = first.parts(keys.count, perPart: 24)
            at["comments"] = first.add(parts: parts) { request, part in
                let range = slice(keys.count, part, of: parts)
                request.execute(CommentsBySlugSQL.self) { b in
                    b.textArray(Array(keys[range]))
                    b.int8Array(range.map { Int64($0 + 1) })
                }
            }
        }
        if !usernames.keys.isEmpty {
            let keys = usernames.keys
            at["profiles"] = first.add { $0.execute(ProfilesByNameSQL.self) { b in b.textArray(keys) } }
        }
        if !userIDs.keys.isEmpty {
            let keys = userIDs.keys
            at["users"] = first.add { $0.execute(UsersByIDSQL.self) { b in b.int8Array(keys) } }
        }
        if !logins.keys.isEmpty {
            let keys = logins.keys
            at["logins"] = first.add { $0.execute(LoginsByEmailSQL.self) { b in b.textArray(keys) } }
        }
        if wantsTags || showsArticles {
            at["tags"] = first.add { $0.execute(TagsSQL.self) { _ in } }
        }
        let firstRows = try await first.run(into: &arena)
        var rank = IntTable<Int32, Int>()
        if let i = at["all"] { try all.take(firstRows[i], arena) }
        if let i = at["tag"] { try byTag.take(firstRows[i], arena) }
        if let i = at["author"] { try byAuthor.take(firstRows[i], arena) }
        if let i = at["favorited"] { try byFavorite.take(firstRows[i], arena) }
        if let i = at["feed"] { try feed.take(firstRows[i], arena) }
        if let i = at["slugs"] {
            for row in firstRows[i] {
                var cells = row
                let k = Int(try cells.int(arena))
                articleRefs[k] = ArticleRef(id: try cells.int(arena), author: try cells.int(arena))
            }
        }
        var commentAuthors = IntSet<Int64>()
        if let i = at["comments"] {
            for row in firstRows[i] {
                var cells = row
                let k = Int(try cells.int(arena))
                if threads[k] == nil { threads[k] = [] } // found; stays empty for an article without comments
                guard let id = try cells.intOrNull(arena) else { continue }
                let body = try cells.text(arena)
                let createdAt = try cells.timestamp(arena)
                let updatedAt = try cells.timestamp(arena)
                let author = try cells.int(arena)
                commentAuthors.insert(author)
                let row = CommentRow(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt, author: Self.noProfile)
                threads[k]?.append(CommentRef(row: row, author: author))
            }
        }
        if let i = at["profiles"] {
            for row in firstRows[i] {
                var cells = row
                let k = Int(try cells.int(arena))
                let id = try cells.int(arena)
                profiles[k] = (id, try cells.profile(arena))
            }
        }
        if let i = at["users"] {
            for row in firstRows[i] {
                var cells = row
                let k = Int(try cells.int(arena))
                users[k] = try cells.user(arena).user
            }
        }
        if let i = at["logins"] {
            for row in firstRows[i] {
                var cells = row
                let k = Int(try cells.int(arena))
                let (id, user) = try cells.user(arena)
                let hash = try cells.text(arena)
                loginRows[k] = (id, string(hash), user)
            }
        }
        if let i = at["tags"] { (tagNames, rank) = try Self.tags(firstRows[i], arena) }

        var ids = IntSet<Int64>(capacity: slots.count * 4)
        var favoritePairs = IntSet<Pair>(capacity: slots.count * 4)
        var followPairs = IntSet<Pair>(capacity: slots.count * 4)
        /// A feed's articles are by authors its viewer follows: no lookup needed.
        var followed = IntSet<Pair>()
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
            case .user, .login, .tags:
                break
            }
        }

        var second = Round(connections)
        var detailsAt: Int?
        var flagsAt: Int?
        if !ids.isEmpty {
            let (shown, bodies) = (ids.keys, articleRefs.compactMap { $0?.id })
            let parts = second.parts(shown.count, perPart: 96)
            detailsAt = second.add(parts: parts) { request, part in
                let range = slice(shown.count, part, of: parts)
                request.execute(ArticleDetailsSQL.self) { b in b.int8Array(Array(shown[range])); b.int8Array(bodies) }
            }
        }
        if !favoritePairs.isEmpty || !followPairs.isEmpty {
            let (fv, ft) = (favoritePairs.keys.map(\.viewer), favoritePairs.keys.map(\.target))
            let (ov, ot) = (followPairs.keys.map(\.viewer), followPairs.keys.map(\.target))
            let parts = second.parts(max(fv.count, ov.count), perPart: 512)
            flagsAt = second.add(parts: parts) { request, part in
                let (f, o) = (slice(fv.count, part, of: parts), slice(ov.count, part, of: parts))
                request.execute(ViewerFlagsSQL.self) { b in
                    b.int8Array(Array(fv[f])); b.int8Array(Array(ft[f])); b.int8Array(Array(ov[o])); b.int8Array(Array(ot[o]))
                }
            }
        }
        var authorsAt: Int?
        if !commentAuthors.isEmpty {
            let authors = commentAuthors.keys
            authorsAt = second.add { $0.execute(CommentAuthorsSQL.self) { b in b.int8Array(authors) } }
        }
        let secondRows = try await second.run(into: &arena)
        if let i = authorsAt {
            var profiles = IntTable<Int64, ProfileRow>(capacity: secondRows[i].count)
            for row in secondRows[i] {
                var cells = row
                let id = try cells.int(arena)
                profiles.set(id, try cells.profile(arena))
            }
            for k in threads.indices where threads[k] != nil {
                // A comment whose author is gone (deleted since the first round) goes with them.
                threads[k] = threads[k]!.compactMap { comment in
                    guard let profile = profiles[comment.author] else { return nil }
                    var comment = comment
                    comment.row.author = profile
                    return comment
                }
            }
        }
        var tagIDs: [(id: Int64, tags: [Int32])] = []
        if let i = detailsAt {
            tagIDs.reserveCapacity(secondRows[i].count)
            details = IntTable(capacity: secondRows[i].count)
            for row in secondRows[i] {
                var cells = row
                let id = try cells.int(arena)
                let slug = try cells.text(arena)
                let title = try cells.text(arena)
                let description = try cells.text(arena)
                let body = try cells.textOrNull(arena)
                let createdAt = try cells.timestamp(arena)
                let updatedAt = try cells.timestamp(arena)
                tagIDs.append((id, try cells.int4Array(arena)))
                let favoritesCount = try cells.int(arena)
                details.set(id, ArticleRow(slug: slug, title: title, description: description, body: body, tagList: [],
                                           createdAt: createdAt, updatedAt: updatedAt, favorited: false,
                                           favoritesCount: favoritesCount, author: try cells.profile(arena)))
            }
        }
        if let i = flagsAt {
            for row in secondRows[i] {
                var cells = row
                let kind = try cells.int(arena)
                let pair = Pair(viewer: try cells.int(arena), target: try cells.int(arena))
                switch kind {
                case 0: favorites.insert(pair)
                case 1: follows.insert(pair)
                default: throw PGCursorError.typeMismatch
                }
            }
        }
        for pair in followed.keys { follows.insert(pair) }

        // The tags table was read in the first round, so an article created since may name a tag it doesn't have yet;
        // then it is read again. Tags are never deleted, so the second read has every tag the details name.
        if tagIDs.contains(where: { $0.tags.contains { !rank.contains($0) } }) {
            var again = Round(connections)
            let t = again.add { $0.execute(TagsSQL.self) { _ in } }
            (tagNames, rank) = try Self.tags(try await again.run(into: &arena)[t], arena)
        }
        for (id, tags) in tagIDs {
            let names = tags.compactMap { rank[$0] }.sorted().map { tagNames[$0] }
            details.update(id) { $0.tagList = names }
        }
        render()
    }

    private func string(_ t: PGTextRef) -> String {
        arena.string(at: Int(t.start), count: Int(t.count))
    }

    /// Tag names in the database's name order, and each tag id's place in that order.
    private static func tags(_ rows: PGRowRanges, _ arena: borrowing Bytes) throws(PGCursorError) -> ([PGTextRef], IntTable<Int32, Int>) {
        var names: [PGTextRef] = []
        names.reserveCapacity(rows.count)
        var rank = IntTable<Int32, Int>(capacity: rows.count)
        for row in rows {
            var cells = row
            let id = try cells.int4(arena)
            rank.set(id, names.count)
            names.append(try cells.text(arena))
        }
        return (names, rank)
    }

    /// Writes everything the batch's results show into one buffer, each article, comment thread, profile and user once
    /// (with the viewer-dependent values left open) however many results show them: the results copy their parts.
    private mutating func render() {
        var out = JSONWriter(capacity: (listed.count + slugs.keys.count) * 640 + (wantsTags ? 64 + tagNames.count * 24 : 0)
                             + (usernames.keys.count + userIDs.keys.count + logins.keys.count) * 256)
        if wantsTags {
            let start = out.position
            out.raw("{\"tags\":[")
            for i in tagNames.indices {
                if i > 0 { out.raw(",") }
                out.string(tagNames[i], arena)
            }
            out.raw("]}")
            tagsBody = Int32(start)..<Int32(out.position)
        }
        listSplices = IntTable(capacity: listed.count)
        for id in listed.keys {
            if let row = details[id] { listSplices.set(id, out.articleSplice(row, full: false, arena)) }
        }
        for ref in articleRefs {
            guard let ref, !fullSplices.contains(ref.id), let row = details[ref.id] else { continue }
            fullSplices.set(ref.id, out.articleSplice(row, full: true, arena))
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
                for comment in newestFirst { splices.append((out.commentSplice(comment.row, arena), comment.author)) }
                threadSplices[k] = splices
            }
        }
        profileSplices.reserveCapacity(profiles.count)
        for p in profiles {
            if let p { profileSplices.append((p.id, out.profileSplice(p.row, arena))) } else { profileSplices.append(nil) }
        }
        userSplices.reserveCapacity(users.count)
        for u in users {
            if let u { userSplices.append(out.userSplice(u, arena)) } else { userSplices.append(nil) }
        }
        loginViews.reserveCapacity(loginRows.count)
        for l in loginRows {
            if let l { loginViews.append(LoginView(id: l.id, hash: l.hash, user: out.userSplice(l.user, arena))) } else { loginViews.append(nil) }
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
            guard let profile = profileSplices[k] else { return .profile(nil, json: json) }
            return .profile(ProfileView(splice: profile.splice, following: follows.contains(Pair(viewer: viewer, target: profile.id))),
                            json: json)
        case .user(let k): return .user(userSplices[k], json: json)
        case .login(let k): return .login(loginViews[k], json: json)
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
/// loop, like the connections that use it.
final class ReadOutbox {
    private let batcher: ReadBatcher
    private let loop: Loop
    private var pending: [ReadBatcher.Waiting] = []
    private var flushScheduled = false

    init(batcher: ReadBatcher, loop: Loop) {
        self.batcher = batcher
        self.loop = loop
    }

    func submit(_ read: Read, viewer: Int64, reply: ReadBatcher.Reply) {
        pending.append(batcher.waiting(read, viewer: viewer, reply: reply))
        guard !flushScheduled else { return }
        flushScheduled = true
        loop.later {
            self.flushScheduled = false
            self.batcher.submit(&self.pending)
        }
    }
}
