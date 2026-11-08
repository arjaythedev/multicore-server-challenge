// The read planner. Requests wait in a lane for a short window, then one connection answers all of
// them with one statement per kind of read, each taking an array of distinct keys. Nothing outlives
// the batch: rows are rendered once per batch, and every response is assembled from those pieces.

#if os(Linux)
import CShim

enum ReqKind: UInt8 {
    case tags, user, login, profile
    case comments
    case article, articleByID, global, tag, author, favorited, feed
}

enum Step: UInt8 {
    case tags, uid, uemail, prof, cmts, aslug, aid, global, gwin, tag, author, favlist, feed
    case artmeta, artx, artau, flags
}

/// A read waiting in a lane. Text lives in the lane's buffer, which travels with the batch.
struct Req {
    var kind: ReqKind
    var close: Bool
    var generation: UInt16
    var reactor: Int32 = 0
    var ring: Int32
    var slot: UInt32
    var status: Int32 = 200
    var viewer: Int64 = 0
    var id: Int64 = 0
    var limit: Int32 = 0
    var offset: Int64 = 0
    var textStart: Int32 = 0
    var textCount: Int32 = 0
    /// The presented token, or the password of a login.
    var secretStart: Int32 = 0
    var secretCount: Int32 = 0
    /// The planner's scratch: key or page, or a rendered row.
    var key: Int32 = -1
    var length: Int32 = 0
}

/// Requests gathering for the next batch. A reactor fills its own private lane during a pass, then
/// moves it into the shared one under the lock, and a planner takes the shared one as a whole.
final class Lane {
    var reqs: UnsafeMutablePointer<Req>
    var capacity = 1024
    var count = 0
    var text = OutBuffer(capacity: 1 << 16)
    var oldest: Int64 = 0
    let lock = sv_mutex_new()

    init() { reqs = .allocate(capacity: capacity) }

    @inline(__always)
    func push(_ r: Req, now: Int64) {
        if count == 0 { oldest = now }
        if count == capacity { grow(count &+ 1) }
        reqs[count] = r
        count &+= 1
    }

    @inline(never)
    func grow(_ needed: Int) {
        var size = capacity
        while size < needed { size &*= 2 }
        let bigger = UnsafeMutablePointer<Req>.allocate(capacity: size)
        bigger.update(from: reqs, count: count)
        reqs.deallocate()
        reqs = bigger
        capacity = size
    }

    /// Moves everything in `other` here. The caller holds this lane's lock.
    func absorb(_ other: Lane) {
        if count == 0 { oldest = other.oldest }
        if count &+ other.count > capacity { grow(count &+ other.count) }
        let shift = Int32(truncatingIfNeeded: text.count)
        for i in 0..<other.count {
            var r = other.reqs[i]
            r.textStart &+= shift
            r.secretStart &+= shift
            reqs[count &+ i] = r
        }
        count &+= other.count
        text.append(other.text.view)
        other.count = 0
        other.text.truncate(0)
    }
}

/// Open-addressing map from nonzero Int64 keys to Int32.
final class IDMap {
    var keys: UnsafeMutablePointer<Int64>
    var values: UnsafeMutablePointer<Int32>
    var mask = 1023
    var count = 0

    init() {
        keys = .allocate(capacity: 1024)
        values = .allocate(capacity: 1024)
        keys.initialize(repeating: 0, count: 1024)
    }

    func reset() {
        if count > 0 { keys.initialize(repeating: 0, count: mask &+ 1) }
        count = 0
    }

    @inline(__always)
    func slot(_ k: Int64) -> Int {
        var i = Int(truncatingIfNeeded: UInt64(bitPattern: k) &* 0x9E37_79B9_7F4A_7C15 >> 20) & mask
        while keys[i] != 0 && keys[i] != k { i = (i &+ 1) & mask }
        return i
    }

    @inline(__always)
    func find(_ k: Int64) -> Int32 {
        let i = slot(k)
        return keys[i] == 0 ? -1 : values[i]
    }

    /// Returns the value already stored for `k`, or stores `v` and returns it.
    @inline(__always)
    func insert(_ k: Int64, _ v: Int32) -> Int32 {
        if (count &+ 1) &* 2 > mask { grow() }
        let i = slot(k)
        if keys[i] != 0 { return values[i] }
        keys[i] = k
        values[i] = v
        count &+= 1
        return v
    }

    @inline(never)
    func grow() {
        let oldKeys = keys
        let oldValues = values
        let oldSize = mask &+ 1
        mask = oldSize &* 2 &- 1
        keys = .allocate(capacity: mask &+ 1)
        values = .allocate(capacity: mask &+ 1)
        keys.initialize(repeating: 0, count: mask &+ 1)
        for i in 0..<oldSize where oldKeys[i] != 0 {
            let s = slot(oldKeys[i])
            keys[s] = oldKeys[i]
            values[s] = oldValues[i]
        }
        oldKeys.deallocate()
        oldValues.deallocate()
    }
}

/// A set of (viewer, id) pairs, both nonzero.
final class PairSet {
    var first: UnsafeMutablePointer<Int64>
    var second: UnsafeMutablePointer<Int64>
    var mask = 4095
    var count = 0

    init() {
        first = .allocate(capacity: 4096)
        second = .allocate(capacity: 4096)
        first.initialize(repeating: 0, count: 4096)
    }

    func reset() {
        if count > 0 { first.initialize(repeating: 0, count: mask &+ 1) }
        count = 0
    }

    @inline(__always)
    func slot(_ a: Int64, _ b: Int64) -> Int {
        let h = (UInt64(bitPattern: a) &* 0x9E37_79B9_7F4A_7C15) ^ (UInt64(bitPattern: b) &* 0xC2B2_AE3D_27D4_EB4F)
        var i = Int(truncatingIfNeeded: h >> 20) & mask
        while first[i] != 0 && !(first[i] == a && second[i] == b) { i = (i &+ 1) & mask }
        return i
    }

    @inline(__always)
    func contains(_ a: Int64, _ b: Int64) -> Bool { first[slot(a, b)] != 0 }

    /// True if the pair is new.
    @inline(__always)
    func insert(_ a: Int64, _ b: Int64) -> Bool {
        if (count &+ 1) &* 2 > mask { grow() }
        let i = slot(a, b)
        if first[i] != 0 { return false }
        first[i] = a
        second[i] = b
        count &+= 1
        return true
    }

    @inline(never)
    func grow() {
        let oldFirst = first
        let oldSecond = second
        let oldSize = mask &+ 1
        mask = oldSize &* 2 &- 1
        first = .allocate(capacity: mask &+ 1)
        second = .allocate(capacity: mask &+ 1)
        first.initialize(repeating: 0, count: mask &+ 1)
        for i in 0..<oldSize where oldFirst[i] != 0 {
            let s = slot(oldFirst[i], oldSecond[i])
            first[s] = oldFirst[i]
            second[s] = oldSecond[i]
        }
        oldFirst.deallocate()
        oldSecond.deallocate()
    }
}

/// Distinct byte strings, each with a small index. Keys point into a buffer owned by the batch.
final class TextMap {
    var offsets: UnsafeMutablePointer<Int32>
    var lengths: UnsafeMutablePointer<Int32>
    var values: UnsafeMutablePointer<Int32>
    var mask = 1023
    var count = 0

    init() {
        offsets = .allocate(capacity: 1024)
        lengths = .allocate(capacity: 1024)
        values = .allocate(capacity: 1024)
        offsets.initialize(repeating: -1, count: 1024)
    }

    func reset() {
        if count > 0 { offsets.initialize(repeating: -1, count: mask &+ 1) }
        count = 0
    }

    @inline(__always)
    func hash(_ v: ByteView) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<v.count {
            h = (h ^ UInt64(v[i])) &* 0x0000_0100_0000_01B3
        }
        return h ^ h >> 29
    }

    @inline(__always)
    func slot(_ v: ByteView, _ base: UnsafePointer<UInt8>) -> Int {
        var i = Int(truncatingIfNeeded: hash(v)) & mask
        while offsets[i] >= 0 {
            if Int(lengths[i]) == v.count && memeq(base + Int(offsets[i]), v.base ?? base, v.count) { return i }
            i = (i &+ 1) & mask
        }
        return i
    }

    @inline(__always)
    func find(_ v: ByteView, _ base: UnsafePointer<UInt8>) -> Int32 {
        let i = slot(v, base)
        return offsets[i] < 0 ? -1 : values[i]
    }

    /// `at` and `v` are the same bytes: `v` is `base + at`.
    func insert(_ v: ByteView, at: Int32, _ base: UnsafePointer<UInt8>, _ value: Int32) -> Int32 {
        if (count &+ 1) &* 2 > mask { grow(base) }
        let i = slot(v, base)
        if offsets[i] >= 0 { return values[i] }
        offsets[i] = at
        lengths[i] = Int32(truncatingIfNeeded: v.count)
        values[i] = value
        count &+= 1
        return value
    }

    @inline(never)
    func grow(_ base: UnsafePointer<UInt8>) {
        let oldOffsets = offsets
        let oldLengths = lengths
        let oldValues = values
        let oldSize = mask &+ 1
        mask = oldSize &* 2 &- 1
        offsets = .allocate(capacity: mask &+ 1)
        lengths = .allocate(capacity: mask &+ 1)
        values = .allocate(capacity: mask &+ 1)
        offsets.initialize(repeating: -1, count: mask &+ 1)
        for i in 0..<oldSize where oldOffsets[i] >= 0 {
            let v = ByteView(base: base + Int(oldOffsets[i]), count: Int(oldLengths[i]))
            let s = slot(v, base)
            offsets[s] = oldOffsets[i]
            lengths[s] = oldLengths[i]
            values[s] = oldValues[i]
        }
        oldOffsets.deallocate()
        oldLengths.deallocate()
        oldValues.deallocate()
    }
}

/// One row's columns, read in order.
struct Columns {
    var p: UnsafePointer<UInt8>

    init(_ message: UnsafePointer<UInt8>) { p = message + 2 }

    @inline(__always)
    mutating func next() -> ByteView? {
        let n = Int(readBE32(p))
        p += 4
        if n < 0 { return nil }
        let v = ByteView(base: p, count: n)
        p += n
        return v
    }

    @inline(__always)
    mutating func int8() -> Int64 {
        guard let v = next(), v.count == 8 else { return 0 }
        return readBE64(v.base.unsafelyUnwrapped)
    }

    @inline(__always)
    mutating func flag() -> Bool {
        guard let v = next(), v.count == 1 else { return false }
        return v[0] != 0
    }

    @inline(__always)
    mutating func text() -> ByteView { next() ?? .empty }
}

struct Span {
    var start: Int32 = 0
    var count: Int32 = 0
}

/// The article id a slug ends with, or 0. Every slug is `SLUGIFY(title)-<id>`, in the seed and after
/// every write, so a read can find the row by primary key and only compare the text. A slug without
/// that suffix belongs to no article.
func slugID(_ slug: ByteView) -> Int64 {
    var i = slug.count
    var value: Int64 = 0
    var scale: Int64 = 1
    while i > 0 {
        let d = slug[i &- 1] &- 48
        guard d < 10 else { break }
        guard scale <= 100_000_000_000_000_000 else { return 0 }
        value &+= Int64(d) &* scale
        scale &*= 10
        i &-= 1
    }
    return i > 0 && slug[i &- 1] == UInt8(ascii: "-") ? value : 0
}

struct ArticleRow {
    var id: Int64
    var authorID: Int64
    var favorites: Int64 = 0
    /// `"slug":..,"title":..,"description":..,"createdAt":..,"updatedAt":..,`
    var head = Span()
    /// `"body":..,`
    var body = Span()
    /// `"tagList":[..],"favoritesCount":N,"favorited":`
    var tail = Span()
    var tags = Span()
    var author: Int32 = -1
}

struct CommentRow {
    var authorID: Int64
    var fragment = Span()
    var next: Int32 = -1
}

struct KeyGroup {
    var head: Int32 = -1
    var last: Int32 = -1
    var exists = false
}

struct Page {
    var key: Int32
    var limit: Int32
    var offset: Int64
    var start: Int32 = 0
    var count: Int32 = 0
}

struct Key {
    var text = Span()
    var viewer: Int64 = 0
    var depth: Int64 = 0
    var total: Int64 = 0
}

/// One family of filtered lists: its distinct keys and distinct pages.
final class Plan {
    let step: Step
    var keys: [Key] = []
    var pages: [Page] = []
    let textMap = TextMap()
    let viewerMap = IDMap()
    let pageMap = IDMap()
    /// Where this plan's pages start in the batch's flat list.
    var base = 0

    init(step: Step) { self.step = step }

    func reset() {
        keys.removeAll(keepingCapacity: true)
        pages.removeAll(keepingCapacity: true)
        textMap.reset()
        viewerMap.reset()
        pageMap.reset()
    }

    /// The page of key `key` at `limit` and `offset`, added if new.
    @inline(__always)
    func page(key: Int32, limit: Int32, offset: Int64) -> Int32 {
        let mixed = (Int64(key) &+ 1) &* 0x1_0000_0001 ^ Int64(limit) << 48 ^ (offset &+ 1)
        let index = pageMap.insert(mixed, Int32(truncatingIfNeeded: pages.count))
        if Int(index) == pages.count { pages.append(Page(key: key, limit: limit, offset: offset)) }
        return index
    }
}

struct Hit {
    var page: Int32
    var article: Int32
}

/// What one read connection is working on. Reused from batch to batch.
final class Batch {
    /// Tags go into a response body in the fast lane, and into the article table in the lists lane.
    var listing: Bool
    var reqs: UnsafeMutablePointer<Req>
    var capacity = 1024
    var count = 0
    var text = OutBuffer(capacity: 1 << 16)
    var active = false
    var failed = false
    var phase = 0
    var steps: [Step] = []
    var stepIndex = 0

    /// Rendered fragments, addressed by offset because the buffer can move.
    var blob = OutBuffer(capacity: 1 << 20)
    var tagsBody = OutBuffer(capacity: 8192)
    var tagNames: [Span] = []
    let tagMap = IDMap()
    let rowMap = IDMap()

    var articles: UnsafeMutablePointer<ArticleRow>
    var articleCapacity = 4096
    var articleCount = 0
    let articleMap = IDMap()
    var authorFragments: [Span] = []
    var authorIDs: [Int64] = []
    let authorMap = IDMap()
    var tagIDs: [Int32] = []
    let slugs = TextMap()
    var slugArticles: [Int32] = []

    let tagPlan = Plan(step: .tag)
    let authorPlan = Plan(step: .author)
    let favoritedPlan = Plan(step: .favlist)
    let feedPlan = Plan(step: .feed)
    let globalPlan = Plan(step: .global)
    var windowEnd: Int64 = 0
    var useWindow = false
    var windowItems: [Int32] = []
    var globalTotal: Int64 = 0
    var hits: [Hit] = []
    var items: [Int32] = []
    var pageOffsets: [Int32] = []

    let favoriteSeen = PairSet()
    let followSeen = PairSet()
    let favorites = PairSet()
    let follows = PairSet()

    var comments: [CommentRow] = []
    var groups: [KeyGroup] = []
    let viewerKeys = PairSet()
    var keyedRequests: [Int] = []
    var lengths: [Int32: Int32] = [:]
    var plans: [Plan] { [globalPlan, tagPlan, authorPlan, favoritedPlan, feedPlan] }

    init(listing: Bool) {
        self.listing = listing
        reqs = .allocate(capacity: capacity)
        articles = .allocate(capacity: articleCapacity)
    }

    func take(_ l: Lane) {
        swap(&reqs, &l.reqs)
        swap(&capacity, &l.capacity)
        count = l.count
        l.count = 0
        swap(&text, &l.text)
        l.text.truncate(0)
        active = true
        failed = false
        phase = 0
        steps.removeAll(keepingCapacity: true)
        stepIndex = 0
        blob.truncate(0)
    }

    @inline(__always)
    func textView(_ s: Span) -> ByteView { ByteView(base: UnsafePointer(text.base + Int(s.start)), count: Int(s.count)) }

    @inline(__always)
    func textView(_ r: Req) -> ByteView {
        ByteView(base: UnsafePointer(text.base + Int(r.textStart)), count: Int(r.textCount))
    }

    @inline(__always)
    func secretView(_ r: Req) -> ByteView {
        ByteView(base: UnsafePointer(text.base + Int(r.secretStart)), count: Int(r.secretCount))
    }

    @inline(__always)
    func blobView(_ s: Span) -> ByteView { ByteView(base: UnsafePointer(blob.base + Int(s.start)), count: Int(s.count)) }

    /// Runs `render`, which appends to `blob`, and returns what it wrote.
    @inline(__always)
    func rendered(_ render: (inout OutBuffer) -> Void) -> Span {
        let start = blob.count
        render(&blob)
        return Span(start: Int32(truncatingIfNeeded: start), count: Int32(truncatingIfNeeded: blob.count &- start))
    }

    @inline(__always)
    func article(_ id: Int64, authorID: Int64) -> Int32 {
        let existing = articleMap.insert(id, Int32(truncatingIfNeeded: articleCount))
        if Int(existing) < articleCount { return existing }
        if articleCount == articleCapacity {
            let bigger = UnsafeMutablePointer<ArticleRow>.allocate(capacity: articleCapacity &* 2)
            bigger.update(from: articles, count: articleCount)
            articles.deallocate()
            articles = bigger
            articleCapacity &*= 2
        }
        articles[articleCount] = ArticleRow(id: id, authorID: authorID)
        articleCount &+= 1
        return existing
    }

    /// Writes an author once: `,"author":{"username":..,"bio":..,"image":..,"following":`.
    func addAuthor(_ id: Int64, _ username: ByteView, _ bio: ByteView?, _ image: ByteView?) {
        let index = authorMap.insert(id, Int32(truncatingIfNeeded: authorFragments.count))
        guard Int(index) == authorFragments.count else { return }
        authorFragments.append(rendered { out in
            out.append("\"username\":")
            out.appendJSONString(username)
            out.append(",\"bio\":")
            out.appendOptionalJSONString(bio)
            out.append(",\"image\":")
            out.appendOptionalJSONString(image)
            out.append(",\"following\":")
        })
    }
}

extension OutBuffer {
    @inline(__always)
    mutating func appendOptionalJSONString(_ v: ByteView?) {
        if let v { appendJSONString(v) } else { append("null") }
    }

    @inline(__always)
    mutating func appendBool(_ v: Bool) { append(v ? "true" : "false") }
}

/// How long each lane gathers before a batch starts, in nanoseconds: fast, comments, lists. Longer
/// windows share more rows and cost Postgres less, and the 500 ms p95 limit sets how long is too long.
let gatherWindow: [Int64] = [30_000_000, 80_000_000, 80_000_000, 80_000_000]

/// How many batches a lane usually runs at once: fast, comments, lists, feeds. A lane may run past its
/// cap when it holds the read that has waited longest, but never past `maxActiveReads` in all.
let laneCaps: [Int] = [2, 2, 3, 2]

/// Batches in flight across every lane. Each one keeps a Postgres backend busy, and the box has eight
/// cores for Postgres, the reactors and bcrypt together.
let maxActiveReads = 7

extension Planner {
    /// Hands idle connections to lanes that have waited long enough. Every read connection serves any
    /// lane, so a lane that falls behind borrows the connections the others aren't using: each free
    /// connection goes to the lane under its cap whose oldest read has waited longest, and if every
    /// ready lane is at its cap, to the oldest of them.
    func dispatch(_ now: Int64) {
        while true {
            var active = (0, 0, 0, 0)
            var total = 0
            var alive = false
            var idle: PgConnection? = nil
            for c in readers where c.alive {
                alive = true
                if c.batch.unsafelyUnwrapped.active {
                    total &+= 1
                    switch c.lane {
                    case 0: active.0 &+= 1
                    case 1: active.1 &+= 1
                    case 2: active.2 &+= 1
                    default: active.3 &+= 1
                    }
                } else if idle == nil {
                    idle = c
                }
            }
            var best = -1
            var bestOldest = Int64.max
            var bestOver = true
            for lane in ownedLanes {
                let l = shared.lanes[lane]
                guard l.count > 0 else { continue } // racy reads: the next tick sees what this one missed
                let oldest = l.oldest
                if now &- oldest < gatherWindow[lane] { continue }
                let running = lane == 0 ? active.0 : (lane == 1 ? active.1 : (lane == 2 ? active.2 : active.3))
                let over = running >= laneCaps[lane]
                if (bestOver && !over) || (over == bestOver && oldest < bestOldest) {
                    best = lane
                    bestOldest = oldest
                    bestOver = over
                }
            }
            guard best >= 0 else { return }
            let lane = shared.lanes[best]
            guard alive else {
                // No connection at all: fail what waits rather than let it time out.
                sv_lock(lane.lock)
                spareBatch.take(lane)
                sv_unlock(lane.lock)
                failBatch(spareBatch)
                continue
            }
            guard let c = idle, total < maxActiveReads else { return }
            let b = c.batch.unsafelyUnwrapped
            c.lane = best
            b.listing = best >= listsLane
            sv_lock(lane.lock)
            b.take(lane)
            sv_unlock(lane.lock)
            switch best {
            case fastLane: startFast(b, c)
            case commentsLane: startComments(b, c)
            default: startLists(b, c)
            }
        }
    }

    // MARK: Fast lane

    func startFast(_ b: Batch, _ c: PgConnection) {
        b.rowMap.reset()
        var tags = false
        var ids: [Int64] = []
        var emails: [Int] = []
        var profiles: [Int] = []
        for i in 0..<b.count {
            switch b.reqs[i].kind {
            case .tags: tags = true
            case .user:
                if b.rowMap.insert(b.reqs[i].viewer, 0) == 0, b.rowMap.count > ids.count { ids.append(b.reqs[i].viewer) }
            case .login: emails.append(i)
            default:
                b.reqs[i].key = Int32(truncatingIfNeeded: profiles.count)
                b.reqs[i].length = 0
                profiles.append(i)
            }
        }
        b.rowMap.reset()
        if tags {
            b.tagsBody.truncate(0)
            b.tagsBody.append("{\"tags\":[")
            c.out.appendBindExecute("tags", parameterCount: 0) { _ in }
            b.steps.append(.tags)
        }
        if !ids.isEmpty {
            c.out.appendBindExecute("uid", parameterCount: 1) { $0.appendInt8Array(ids) }
            b.steps.append(.uid)
        }
        if !emails.isEmpty {
            c.out.appendBindExecute("uemail", parameterCount: 1) { out in
                let at = out.beginArray(oid: oidText, count: emails.count)
                for i in emails { out.appendTextParameter(b.textView(b.reqs[i])) }
                out.endArray(at)
            }
            b.steps.append(.uemail)
        }
        if !profiles.isEmpty {
            c.out.appendBindExecute("prof", parameterCount: 2) { out in
                out.appendInt8Array(profiles.map { b.reqs[$0].viewer })
                let at = out.beginArray(oid: oidText, count: profiles.count)
                for i in profiles { out.appendTextParameter(b.textView(b.reqs[i])) }
                out.endArray(at)
            }
            b.steps.append(.prof)
            b.keyedRequests = profiles
        }
        c.out.appendSync()
    }

    // MARK: Comments lane

    func startComments(_ b: Batch, _ c: PgConnection) {
        b.slugs.reset()
        b.viewerKeys.reset()
        b.follows.reset()
        b.authorMap.reset()
        b.authorFragments.removeAll(keepingCapacity: true)
        b.comments.removeAll(keepingCapacity: true)
        b.slugArticles.removeAll(keepingCapacity: true)
        var viewers: [Int64] = []
        var keys: [Int64] = []
        let base = UnsafePointer(b.text.base)
        for i in 0..<b.count {
            let v = b.textView(b.reqs[i])
            let key = b.slugs.insert(v, at: b.reqs[i].textStart, base, Int32(truncatingIfNeeded: b.slugArticles.count))
            if Int(key) == b.slugArticles.count { b.slugArticles.append(b.reqs[i].textStart) }
            b.reqs[i].key = key
            let viewer = b.reqs[i].viewer
            if viewer > 0, b.viewerKeys.insert(viewer, Int64(key) &+ 1) {
                viewers.append(viewer)
                keys.append(Int64(key) &+ 1)
            }
        }
        // Group distinct slugs by key so the rows can find them.
        b.groups.removeAll(keepingCapacity: true)
        b.groups.append(contentsOf: repeatElement(KeyGroup(), count: b.slugArticles.count))
        var ordered = [Int](repeating: 0, count: b.slugArticles.count)
        for i in 0..<b.count { ordered[Int(b.reqs[i].key)] = i }
        c.out.appendBindExecute("cmts", parameterCount: 4) { out in
            let at = out.beginArray(oid: oidText, count: ordered.count)
            for i in ordered { out.appendTextParameter(b.textView(b.reqs[i])) }
            out.endArray(at)
            out.appendInt8Array(viewers)
            out.appendInt8Array(keys)
            out.appendInt8Array(ordered.map { slugID(b.textView(b.reqs[$0])) })
        }
        b.steps.append(.cmts)
        c.out.appendSync()
    }

    // MARK: Lists lane

    func startLists(_ b: Batch, _ c: PgConnection) {
        b.articleCount = 0
        b.articleMap.reset()
        b.authorMap.reset()
        b.authorFragments.removeAll(keepingCapacity: true)
        b.authorIDs.removeAll(keepingCapacity: true)
        b.tagIDs.removeAll(keepingCapacity: true)
        b.hits.removeAll(keepingCapacity: true)
        b.windowItems.removeAll(keepingCapacity: true)
        b.slugs.reset()
        b.slugArticles.removeAll(keepingCapacity: true)
        b.favorites.reset()
        b.follows.reset()
        b.favoriteSeen.reset()
        b.followSeen.reset()
        b.tagNames.removeAll(keepingCapacity: true)
        b.tagMap.reset()
        for plan in b.plans { plan.reset() }
        b.windowEnd = 0
        b.useWindow = true
        b.globalTotal = 0

        var slugRequests: [Int] = []
        var ids: [Int64] = []
        let base = UnsafePointer(b.text.base)
        for i in 0..<b.count {
            let r = b.reqs + i
            switch r.pointee.kind {
            case .article:
                let v = b.textView(r.pointee)
                let key = b.slugs.insert(v, at: r.pointee.textStart, base, Int32(truncatingIfNeeded: b.slugArticles.count))
                if Int(key) == b.slugArticles.count {
                    b.slugArticles.append(-1)
                    slugRequests.append(i)
                }
                r.pointee.key = key
            case .articleByID:
                ids.append(r.pointee.id)
            case .global:
                let end = Int64(r.pointee.limit) &+ r.pointee.offset
                if end > 200 { b.useWindow = false }
                if end > b.windowEnd { b.windowEnd = end }
                r.pointee.key = b.globalPlan.page(key: 0, limit: r.pointee.limit, offset: r.pointee.offset)
            case .tag, .author, .favorited:
                let plan = r.pointee.kind == .tag ? b.tagPlan : (r.pointee.kind == .author ? b.authorPlan : b.favoritedPlan)
                let v = b.textView(r.pointee)
                let key = plan.textMap.insert(v, at: r.pointee.textStart, base, Int32(truncatingIfNeeded: plan.keys.count))
                if Int(key) == plan.keys.count {
                    plan.keys.append(Key(text: Span(start: r.pointee.textStart, count: r.pointee.textCount)))
                }
                r.pointee.key = plan.page(key: key, limit: r.pointee.limit, offset: r.pointee.offset)
            default: // feed
                let plan = b.feedPlan
                let key = plan.viewerMap.insert(r.pointee.viewer, Int32(truncatingIfNeeded: plan.keys.count))
                if Int(key) == plan.keys.count { plan.keys.append(Key(viewer: r.pointee.viewer)) }
                let depth = Int64(r.pointee.limit) &+ r.pointee.offset
                if depth > plan.keys[Int(key)].depth { plan.keys[Int(key)].depth = depth }
                r.pointee.key = plan.page(key: key, limit: r.pointee.limit, offset: r.pointee.offset)
            }
        }
        var total = 0
        for plan in b.plans {
            plan.base = total
            total &+= plan.pages.count
        }

        if !slugRequests.isEmpty {
            c.out.appendBindExecute("aid", parameterCount: 1) {
                $0.appendInt8Array(slugRequests.map { slugID(b.textView(b.reqs[$0])) })
            }
            b.steps.append(.aslug)
        }
        if !ids.isEmpty {
            c.out.appendBindExecute("aid", parameterCount: 1) { $0.appendInt8Array(ids) }
            b.steps.append(.aid)
        }
        if !b.globalPlan.pages.isEmpty {
            if b.useWindow {
                c.out.appendBindExecute("gwin", parameterCount: 1) { $0.appendInt8Parameter(b.windowEnd) }
                b.steps.append(.gwin)
            } else {
                c.out.appendBindExecute("global", parameterCount: 2) { out in
                    out.appendInt8Array(b.globalPlan.pages.map { Int64($0.limit) })
                    out.appendInt8Array(b.globalPlan.pages.map { $0.offset })
                }
                b.steps.append(.global)
            }
        }
        for plan in [b.tagPlan, b.authorPlan, b.favoritedPlan] where !plan.keys.isEmpty {
            let name: StaticString = plan.step == .tag ? "tag" : (plan.step == .author ? "author" : "favlist")
            c.out.appendBindExecute(name, parameterCount: 4) { out in
                let at = out.beginArray(oid: oidText, count: plan.keys.count)
                for key in plan.keys { out.appendTextParameter(b.textView(key.text)) }
                out.endArray(at)
                out.appendInt8Array(plan.pages.map { Int64($0.key) &+ 1 })
                out.appendInt8Array(plan.pages.map { Int64($0.limit) })
                out.appendInt8Array(plan.pages.map { $0.offset })
            }
            b.steps.append(plan.step)
        }
        if !b.feedPlan.keys.isEmpty {
            let plan = b.feedPlan
            c.out.appendBindExecute("feed", parameterCount: 5) { out in
                out.appendInt8Array(plan.keys.map { $0.viewer })
                out.appendInt8Array(plan.keys.map { $0.depth })
                out.appendInt8Array(plan.pages.map { Int64($0.key) &+ 1 })
                out.appendInt8Array(plan.pages.map { Int64($0.limit) })
                out.appendInt8Array(plan.pages.map { $0.offset })
            }
            b.steps.append(.feed)
        }
        c.out.appendSync()
    }

    /// The second round trip: everything the listed articles still need, read once. False if there
    /// is nothing to read.
    func startEnrichment(_ b: Batch, _ c: PgConnection) -> Bool {
        b.phase = 1
        b.steps.removeAll(keepingCapacity: true)
        b.stepIndex = 0
        // Pages: turn the hits into one id-ordered list per page.
        var pages = 0
        for plan in b.plans { pages &+= plan.pages.count }
        b.pageOffsets.removeAll(keepingCapacity: true)
        b.pageOffsets.append(contentsOf: repeatElement(0, count: pages &+ 1))
        for h in b.hits { b.pageOffsets[Int(h.page) &+ 1] &+= 1 }
        for i in 0..<pages { b.pageOffsets[i &+ 1] &+= b.pageOffsets[i] }
        b.items.removeAll(keepingCapacity: true)
        b.items.append(contentsOf: repeatElement(0, count: b.hits.count))
        var cursor = b.pageOffsets
        for h in b.hits {
            b.items[Int(cursor[Int(h.page)])] = h.article
            cursor[Int(h.page)] &+= 1
        }
        let articles = b.articles
        for i in 0..<pages {
            var low = Int(b.pageOffsets[i]) &+ 1
            let high = Int(b.pageOffsets[i &+ 1])
            while low < high {
                let v = b.items[low]
                let id = articles[Int(v)].id
                var j = low
                while j > Int(b.pageOffsets[i]) && articles[Int(b.items[j &- 1])].id < id {
                    b.items[j] = b.items[j &- 1]
                    j &-= 1
                }
                b.items[j] = v
                low &+= 1
            }
        }
        if b.articleCount == 0 { return false }

        var metaIDs: [Int64] = []
        var allIDs: [Int64] = []
        allIDs.reserveCapacity(b.articleCount)
        var authorIDs: [Int64] = []
        for i in 0..<b.articleCount {
            let a = articles + i
            allIDs.append(a.pointee.id)
            if a.pointee.head.count == 0 { metaIDs.append(a.pointee.id) }
            let index = b.authorMap.insert(a.pointee.authorID, Int32(truncatingIfNeeded: authorIDs.count))
            if Int(index) == authorIDs.count { authorIDs.append(a.pointee.authorID) }
            a.pointee.author = index
        }
        b.authorMap.reset()
        allIDs.sort()
        authorIDs.sort()
        for (i, id) in authorIDs.enumerated() { _ = b.authorMap.insert(id, Int32(truncatingIfNeeded: i)) }
        b.authorIDs = authorIDs
        b.authorFragments.append(contentsOf: repeatElement(Span(), count: authorIDs.count))
        for i in 0..<b.articleCount { articles[i].author = b.authorMap.find(articles[i].authorID) }

        if !metaIDs.isEmpty {
            metaIDs.sort()
            c.out.appendBindExecute("artmeta", parameterCount: 1) { $0.appendInt8Array(metaIDs) }
            b.steps.append(.artmeta)
        }
        c.out.appendBindExecute("artx", parameterCount: 1) { $0.appendInt8Array(allIDs) }
        b.steps.append(.artx)
        c.out.appendBindExecute("artau", parameterCount: 1) { $0.appendInt8Array(authorIDs) }
        b.steps.append(.artau)
        c.out.appendBindExecute("tags", parameterCount: 0) { _ in }
        b.steps.append(.tags)
        planFlags(b, c)
        c.out.appendSync()
        return true
    }

    /// Reads only the favorites and follows the batch's viewers can actually see, grouped by viewer.
    func planFlags(_ b: Batch, _ c: PgConnection) {
        var favoriteHeads = IDChains()
        var followHeads = IDChains()
        let articles = b.articles
        @inline(__always) func note(_ viewer: Int64, _ article: Int32) {
            let a = articles + Int(article)
            if b.favoriteSeen.insert(viewer, a.pointee.id) { favoriteHeads.add(viewer, a.pointee.id) }
            if b.followSeen.insert(viewer, a.pointee.authorID) { followHeads.add(viewer, a.pointee.authorID) }
        }
        for i in 0..<b.count {
            let r = b.reqs + i
            let viewer = r.pointee.viewer
            guard viewer > 0 else { continue }
            switch r.pointee.kind {
            case .article:
                let article = b.slugArticles[Int(r.pointee.key)]
                if article >= 0 { note(viewer, article) }
            case .articleByID:
                let article = b.articleMap.find(r.pointee.id)
                if article >= 0 { note(viewer, article) }
            default:
                let (start, end) = pageRange(b, r.pointee)
                var k = start
                while k < end {
                    note(viewer, itemAt(b, r.pointee, k))
                    k &+= 1
                }
            }
        }
        guard !favoriteHeads.viewers.isEmpty else { return }
        let favorites = favoriteHeads.flatten()
        let follows = followHeads.flatten()
        c.out.appendBindExecute("flags", parameterCount: 8) { out in
            out.appendInt8Array(favorites.viewers)
            out.appendInt8Array(favorites.ids)
            out.appendInt4Array(favorites.starts)
            out.appendInt4Array(favorites.ends)
            out.appendInt8Array(follows.viewers)
            out.appendInt8Array(follows.ids)
            out.appendInt4Array(follows.starts)
            out.appendInt4Array(follows.ends)
        }
        b.steps.append(.flags)
    }

    /// The items a list request shows, as positions for `itemAt`.
    @inline(__always)
    func pageRange(_ b: Batch, _ r: Req) -> (Int, Int) {
        if r.kind == .global && b.useWindow {
            let start = min(Int(r.offset), b.windowItems.count)
            return (start, min(start &+ Int(r.limit), b.windowItems.count))
        }
        let index = planBase(b, r.kind) &+ Int(r.key)
        return (Int(b.pageOffsets[index]), Int(b.pageOffsets[index &+ 1]))
    }

    @inline(__always)
    func itemAt(_ b: Batch, _ r: Req, _ k: Int) -> Int32 {
        (r.kind == .global && b.useWindow) ? b.windowItems[k] : b.items[k]
    }

    @inline(__always)
    func planBase(_ b: Batch, _ kind: ReqKind) -> Int {
        switch kind {
        case .global: return b.globalPlan.base
        case .tag: return b.tagPlan.base
        case .author: return b.authorPlan.base
        case .favorited: return b.favoritedPlan.base
        default: return b.feedPlan.base
        }
    }

    // MARK: Rows

    func batchRow(_ b: Batch, _ message: UnsafePointer<UInt8>) {
        var row = Columns(message)
        switch b.steps[b.stepIndex] {
        case .tags:
            let id = row.next().map { Int64(readBE32($0.base.unsafelyUnwrapped)) } ?? 0
            let name = row.text()
            if !b.listing {
                if b.tagsBody.count > 9 { b.tagsBody.append(UInt8(ascii: ",")) }
                b.tagsBody.appendJSONString(name)
            } else {
                let span = b.rendered { $0.appendJSONString(name) }
                _ = b.tagMap.insert(id, Int32(truncatingIfNeeded: b.tagNames.count))
                b.tagNames.append(span)
            }
        case .uid:
            let id = row.int8()
            let username = row.text()
            let email = row.text()
            let bio = row.next()
            let image = row.next()
            let span = b.rendered { out in
                out.appendUserFields(email: email, username: username, bio: bio, image: image)
            }
            _ = b.rowMap.insert(id, span.start)
            b.lengths[span.start] = span.count
        case .uemail:
            let id = row.int8()
            let username = row.text()
            let email = row.text()
            let bio = row.next()
            let image = row.next()
            let hash = row.text()
            for i in 0..<b.count where b.reqs[i].kind == .login && b.reqs[i].key < 0 {
                guard b.textView(b.reqs[i]).equalsBytes(email) else { continue }
                b.reqs[i].key = 0
                startLogin(b.reqs[i], secret: b.secretView(b.reqs[i]), hash: hash, id: id, email: email,
                           username: username, bio: bio, image: image)
            }
        case .prof:
            let k = Int(row.int8())
            let username = row.text()
            let bio = row.next()
            let image = row.next()
            let following = row.flag()
            guard k >= 1, k <= b.keyedRequests.count else { break }
            let span = b.rendered { out in
                out.append("{\"profile\":{\"username\":")
                out.appendJSONString(username)
                out.append(",\"bio\":")
                out.appendOptionalJSONString(bio)
                out.append(",\"image\":")
                out.appendOptionalJSONString(image)
                out.append(",\"following\":")
                out.appendBool(following)
                out.append("}}")
            }
            let r = b.reqs + b.keyedRequests[k &- 1]
            r.pointee.key = span.start
            r.pointee.length = span.count
        case .cmts:
            commentRow(b, &row)
        case .aslug, .aid:
            let id = row.int8()
            let authorID = row.int8()
            let slug = row.text()
            let title = row.text()
            let description = row.text()
            let created = row.int8()
            let updated = row.int8()
            let text = row.text()
            let index = b.article(id, authorID: authorID)
            fillHead(b, index, slug, title, description, created, updated)
            b.articles[Int(index)].body = b.rendered { out in
                out.append("\"body\":")
                out.appendJSONString(text)
                out.append(UInt8(ascii: ","))
            }
            if b.steps[b.stepIndex] == .aslug {
                let key = b.slugs.find(slug, UnsafePointer(b.text.base))
                if key >= 0 { b.slugArticles[Int(key)] = index }
            }
        case .global, .gwin, .tag, .author, .favlist:
            let k = row.int8()
            let second = row.int8()
            let authorID = row.int8()
            listRow(b, k, second, authorID, &row)
        case .feed:
            let k = row.int8()
            let id = row.int8()
            let authorID = row.int8()
            if k < 0 {
                b.feedPlan.keys[Int(-k) &- 1].total = id
            } else {
                let index = b.article(id, authorID: authorID)
                b.hits.append(Hit(page: Int32(b.feedPlan.base &+ Int(k) &- 1), article: index))
            }
        case .artmeta:
            let id = row.int8()
            let slug = row.text()
            let title = row.text()
            let description = row.text()
            let created = row.int8()
            let updated = row.int8()
            let index = b.articleMap.find(id)
            if index >= 0 { fillHead(b, index, slug, title, description, created, updated) }
        case .artx:
            // Two kinds of row: a NULL tag carries the article's favorite count, any other is a tag.
            let id = row.int8()
            let index = b.articleMap.find(id)
            let tag = row.next()
            let count = row.int8()
            guard index >= 0 else { break }
            let a = b.articles + Int(index)
            if let tag {
                let run = a.pointee.tags
                let end = b.tagIDs.count
                if run.count == 0 {
                    a.pointee.tags.start = Int32(truncatingIfNeeded: end)
                } else if Int(run.start) &+ Int(run.count) != end {
                    // Rows of one article arrive in a row in index order. If a plan ever
                    // interleaves them, move the run to the end so it stays contiguous.
                    a.pointee.tags.start = Int32(truncatingIfNeeded: end)
                    for k in 0..<Int(run.count) { b.tagIDs.append(b.tagIDs[Int(run.start) &+ k]) }
                }
                b.tagIDs.append(readBE32(tag.base.unsafelyUnwrapped))
                a.pointee.tags.count &+= 1
            } else {
                a.pointee.favorites = count
            }
        case .artau:
            let id = row.int8()
            let username = row.text()
            let bio = row.next()
            let image = row.next()
            let index = b.authorMap.find(id)
            if index >= 0 {
                b.authorFragments[Int(index)] = b.rendered { out in
                    out.append(",\"author\":{\"username\":")
                    out.appendJSONString(username)
                    out.append(",\"bio\":")
                    out.appendOptionalJSONString(bio)
                    out.append(",\"image\":")
                    out.appendOptionalJSONString(image)
                    out.append(",\"following\":")
                }
            }
        case .flags:
            let kind = row.int8()
            let viewer = row.int8()
            let id = row.int8()
            if kind == 0 { _ = b.favorites.insert(viewer, id) } else { _ = b.follows.insert(viewer, id) }
        }
    }

    @inline(__always)
    func fillHead(_ b: Batch, _ index: Int32, _ slug: ByteView, _ title: ByteView, _ description: ByteView,
                  _ created: Int64, _ updated: Int64) {
        guard b.articles[Int(index)].head.count == 0 else { return }
        b.articles[Int(index)].head = b.rendered { out in
            out.reserve(slug.count &* 6 &+ title.count &* 6 &+ description.count &* 6 &+ 128)
            out.append("\"slug\":")
            out.appendJSONString(slug)
            out.append(",\"title\":")
            out.appendJSONString(title)
            out.append(",\"description\":")
            out.appendJSONString(description)
            out.append(",\"createdAt\":")
            out.appendTimestamp(created)
            out.append(",\"updatedAt\":")
            out.appendTimestamp(updated)
            out.append(UInt8(ascii: ","))
        }
    }

    @inline(__always)
    func listRow(_ b: Batch, _ k: Int64, _ second: Int64, _ authorID: Int64, _ row: inout Columns) {
        let step = b.steps[b.stepIndex]
        if k <= 0 {
            if step == .global || step == .gwin {
                b.globalTotal = second
            } else {
                let plan = step == .tag ? b.tagPlan : (step == .author ? b.authorPlan : b.favoritedPlan)
                plan.keys[Int(-k) &- 1].total = second
            }
            return
        }
        let slug = row.text()
        let title = row.text()
        let description = row.text()
        let created = row.int8()
        let updated = row.int8()
        let index = b.article(second, authorID: authorID)
        fillHead(b, index, slug, title, description, created, updated)
        switch step {
        case .gwin:
            b.windowItems.append(index)
        case .global:
            b.hits.append(Hit(page: Int32(b.globalPlan.base &+ Int(k) &- 1), article: index))
        default:
            let plan = step == .tag ? b.tagPlan : (step == .author ? b.authorPlan : b.favoritedPlan)
            b.hits.append(Hit(page: Int32(plan.base &+ Int(k) &- 1), article: index))
        }
    }

    @inline(__always)
    func commentRow(_ b: Batch, _ row: inout Columns) {
        let kind = row.int8()
        switch kind {
        case 0:
            let k = Int(row.int8()) &- 1
            b.groups[k].exists = true
            guard let idColumn = row.next() else { return } // an article without comments
            let authorID = row.int8()
            let created = row.int8()
            let updated = row.int8()
            let text = row.text()
            let fragment = b.rendered { out in
                out.reserve(text.count &* 6 &+ 128)
                out.append("{\"id\":")
                out.appendInt(readBE64(idColumn.base.unsafelyUnwrapped))
                out.append(",\"createdAt\":")
                out.appendTimestamp(created)
                out.append(",\"updatedAt\":")
                out.appendTimestamp(updated)
                out.append(",\"body\":")
                out.appendJSONString(text)
                out.append(",\"author\":{")
            }
            let index = Int32(truncatingIfNeeded: b.comments.count)
            b.comments.append(CommentRow(authorID: authorID, fragment: fragment))
            if b.groups[k].last >= 0 { b.comments[Int(b.groups[k].last)].next = index } else { b.groups[k].head = index }
            b.groups[k].last = index
        case 1:
            let id = row.int8()
            _ = row.next()
            _ = row.next()
            _ = row.next()
            _ = row.next()
            let username = row.text()
            let bio = row.next()
            let image = row.next()
            b.addAuthor(id, username, bio, image)
        default:
            let viewer = row.int8()
            let followee = row.int8()
            _ = b.follows.insert(viewer, followee)
        }
    }

    // MARK: Finishing

    /// Postgres finished a phase on this connection.
    func batchReady(_ b: Batch, _ c: PgConnection) {
        guard !b.failed else {
            failBatch(b)
            return
        }
        switch c.lane {
        case fastLane:
            finishFast(b)
        case commentsLane:
            finishComments(b)
        default: // lists and feeds
            if b.phase == 0 && startEnrichment(b, c) {
                flush(c)
                return
            }
            renderLists(b)
        }
        b.active = false
    }

    func failBatch(_ b: Batch) {
        _ = errors(500, "internal error")
        for i in 0..<b.count {
            if b.reqs[i].kind == .login && b.reqs[i].key >= 0 { continue } // a hash is on its way
            answer(b.reqs[i], 500, body.view)
        }
        b.active = false
    }

    func finishFast(_ b: Batch) {
        var tagsClosed = false
        for i in 0..<b.count {
            let r = b.reqs[i]
            switch r.kind {
            case .tags:
                if !tagsClosed {
                    b.tagsBody.append("]}")
                    tagsClosed = true
                }
                answer(r, 200, b.tagsBody.view)
            case .user:
                let start = b.rowMap.find(r.viewer)
                guard start >= 0 else {
                    _ = errors(401, "unauthorized")
                    answer(r, 401, body.view)
                    continue
                }
                body.truncate(0)
                body.append("{\"user\":{")
                body.append(b.blobView(Span(start: start, count: b.lengths[start] ?? 0)))
                body.append(",\"token\":\"")
                body.append(b.secretView(r))
                body.append("\"}}")
                answer(r, 200, body.view)
            case .login:
                if r.key < 0 {
                    _ = errors(401, "invalid credentials")
                    answer(r, 401, body.view)
                }
            default:
                if r.length > 0 {
                    answer(r, 200, b.blobView(Span(start: r.key, count: r.length)))
                } else {
                    _ = errors(404, "not found")
                    answer(r, 404, body.view)
                }
            }
        }
        b.lengths.removeAll(keepingCapacity: true)
        b.active = false
    }

    func finishComments(_ b: Batch) {
        for i in 0..<b.count {
            let r = b.reqs[i]
            let group = b.groups[Int(r.key)]
            guard group.exists else {
                _ = errors(404, "not found")
                answer(r, 404, body.view)
                continue
            }
            body.truncate(0)
            body.append("{\"comments\":[")
            var c = group.head
            var first = true
            while c >= 0 {
                if !first { body.append(UInt8(ascii: ",")) }
                first = false
                let comment = b.comments[Int(c)]
                body.append(b.blobView(comment.fragment))
                let author = b.authorMap.find(comment.authorID)
                if author >= 0 { body.append(b.blobView(b.authorFragments[Int(author)])) }
                body.appendBool(r.viewer > 0 && b.follows.contains(r.viewer, comment.authorID))
                body.append("}}")
                c = comment.next
            }
            body.append("]}")
            answer(r, 200, body.view)
        }
    }

    /// Assembles every response of a lists batch from the batch's rendered pieces.
    func renderLists(_ b: Batch) {
        var ranks: [(Int32, Int32)] = []
        for i in 0..<b.articleCount {
            let a = b.articles + i
            ranks.removeAll(keepingCapacity: true)
            let tags = a.pointee.tags
            for k in 0..<Int(tags.count) {
                let rank = b.tagMap.find(Int64(b.tagIDs[Int(tags.start) &+ k]))
                if rank >= 0 { ranks.append((rank, 0)) }
            }
            if ranks.count > 1 { ranks.sort { $0.0 < $1.0 } }
            let favoritesCount = a.pointee.favorites
            a.pointee.tail = b.rendered { out in
                out.append("\"tagList\":[")
                for (k, rank) in ranks.enumerated() {
                    if k > 0 { out.append(UInt8(ascii: ",")) }
                    let s = b.tagNames[Int(rank.0)]
                    out.reserve(Int(s.count))
                    out.append(UnsafePointer(out.base + Int(s.start)), Int(s.count))
                }
                out.append("],\"favoritesCount\":")
                out.appendInt(favoritesCount)
                out.append(",\"favorited\":")
            }
        }
        for i in 0..<b.count {
            let r = b.reqs[i]
            switch r.kind {
            case .article, .articleByID:
                let index = r.kind == .article ? b.slugArticles[Int(r.key)] : b.articleMap.find(r.id)
                guard index >= 0 else {
                    _ = errors(404, "not found")
                    answer(r, 404, body.view)
                    continue
                }
                body.truncate(0)
                body.append("{\"article\":")
                writeArticle(b, index, r.viewer, withBody: true)
                body.append(UInt8(ascii: "}"))
                answer(r, Int(r.status), body.view)
            default:
                body.truncate(0)
                body.append("{\"articles\":[")
                let (start, end) = pageRange(b, r)
                var k = start
                while k < end {
                    if k > start { body.append(UInt8(ascii: ",")) }
                    writeArticle(b, itemAt(b, r, k), r.viewer, withBody: false)
                    k &+= 1
                }
                body.append("],\"articlesCount\":")
                body.appendInt(listTotal(b, r))
                body.append(UInt8(ascii: "}"))
                answer(r, 200, body.view)
            }
        }
        b.active = false
    }

    func listTotal(_ b: Batch, _ r: Req) -> Int64 {
        switch r.kind {
        case .global: return b.globalTotal
        case .tag: return b.tagPlan.keys[Int(b.tagPlan.pages[Int(r.key)].key)].total
        case .author: return b.authorPlan.keys[Int(b.authorPlan.pages[Int(r.key)].key)].total
        case .favorited: return b.favoritedPlan.keys[Int(b.favoritedPlan.pages[Int(r.key)].key)].total
        default: return b.feedPlan.keys[Int(b.feedPlan.pages[Int(r.key)].key)].total
        }
    }

    @inline(__always)
    func writeArticle(_ b: Batch, _ index: Int32, _ viewer: Int64, withBody: Bool) {
        let a = b.articles + Int(index)
        body.append(UInt8(ascii: "{"))
        if withBody { body.append(b.blobView(a.pointee.body)) }
        body.append(b.blobView(a.pointee.head))
        body.append(b.blobView(a.pointee.tail))
        body.appendBool(viewer > 0 && b.favorites.contains(viewer, a.pointee.id))
        if a.pointee.author >= 0 { body.append(b.blobView(b.authorFragments[Int(a.pointee.author)])) }
        body.appendBool(viewer > 0 && b.follows.contains(viewer, a.pointee.authorID))
        body.append("}}")
    }
}

/// Pairs grouped by viewer, ready to become the four arrays of the flags statement.
struct IDChains {
    var viewers: [Int64] = []
    var perViewer: [[Int64]] = []
    var index = [Int64: Int]()

    @inline(__always)
    mutating func add(_ viewer: Int64, _ id: Int64) {
        if let i = index[viewer] {
            perViewer[i].append(id)
        } else {
            index[viewer] = viewers.count
            viewers.append(viewer)
            perViewer.append([id])
        }
    }

    func flatten() -> (viewers: [Int64], ids: [Int64], starts: [Int32], ends: [Int32]) {
        var ids: [Int64] = []
        var starts: [Int32] = []
        var ends: [Int32] = []
        for list in perViewer {
            starts.append(Int32(truncatingIfNeeded: ids.count &+ 1))
            ids.append(contentsOf: list)
            ends.append(Int32(truncatingIfNeeded: ids.count))
        }
        return (viewers, ids, starts, ends)
    }
}

extension ByteView {
    @inline(__always)
    func equalsBytes(_ other: ByteView) -> Bool {
        guard count == other.count else { return false }
        if count == 0 { return true }
        return memeq(base.unsafelyUnwrapped, other.base.unsafelyUnwrapped, count)
    }
}

extension OutBuffer {
    @inline(__always)
    mutating func appendUserFields(email: ByteView, username: ByteView, bio: ByteView?, image: ByteView?) {
        append("\"email\":")
        appendJSONString(email)
        append(",\"username\":")
        appendJSONString(username)
        append(",\"bio\":")
        appendOptionalJSONString(bio)
        append(",\"image\":")
        appendOptionalJSONString(image)
    }
}
#endif
