// engine.rs's ReadWorker: a read lane, an actor with one Postgres connection, answering a whole batch of reads of
// every kind in two pipelined round trips. Phase A resolves what each request is about with one statement per kind
// present, over the batch's distinct keys, in two parts sent in one flush: A1 (tags, the current user, logins) has
// its own Sync, so those replies go out, and logins reach the bcrypt workers, while Postgres still runs A2's lists.
// Phase B enriches the union of the articles phase A found (tags, favorite counts, authors, and metadata for those
// an index-only list found), once each, and the viewers' favorited/following flags; anonymous profiles are answered
// while it runs. Every article's JSON is written once per batch with its two viewer-dependent booleans left open,
// and responses that come out identical are built once and shared.

struct PairKey: Hashable {
    var a: Int64
    var b: Int64
}

struct PageKey: Hashable {
    var c: UInt32
    var lim: Int64
    var off: Int64
}

/// Distinct keys in first-seen order, each with its ordinal (`KeySet`).
struct KeySet<K: Hashable> {
    private var index: [K: UInt32] = [:]
    private(set) var items: [K] = []

    var count: Int { items.count }

    mutating func clear() {
        index.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
    }

    mutating func intern(_ key: K) -> UInt32 {
        if let i = index[key] { return i }
        let i = UInt32(items.count)
        index[key] = i
        items.append(key)
        return i
    }

    @inline(__always) func ordinal(of key: K) -> UInt32? { index[key] }
}

@inline(__always) private func sameBytes(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
    guard a.count == b.count else { return false }
    for i in a.indices where a[i] != b[i] { return false }
    return true
}

/// `KeySet<String>`, whose items go to Postgres as a text[]. It is also looked up by a row's column, a borrowed
/// `Span`, without copying it: the index is keyed by the bytes' FNV-1a hash, with a chain for keys sharing one.
struct BytesKeySet {
    private var firstWithHash: [UInt64: UInt32] = [:]
    private var nextWithHash: [UInt32] = []
    private(set) var items: [[UInt8]] = []

    var count: Int { items.count }

    mutating func clear() {
        firstWithHash.removeAll(keepingCapacity: true)
        nextWithHash.removeAll(keepingCapacity: true)
        items.removeAll(keepingCapacity: true)
    }

    @inline(__always) private static func hash(_ key: Span<UInt8>) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in key.indices { h = (h ^ UInt64(key[i])) &* 0x100_0000_01B3 }
        return h
    }

    func ordinal(of key: Span<UInt8>) -> UInt32? {
        var i = firstWithHash[Self.hash(key)] ?? .max
        while i != .max {
            let candidate = items[Int(i)]
            if sameBytes(candidate.span, key) { return i }
            i = nextWithHash[Int(i)]
        }
        return nil
    }

    mutating func intern(_ key: [UInt8]) -> UInt32 {
        if let i = ordinal(of: key.span) { return i }
        let h = Self.hash(key.span)
        let i = UInt32(items.count)
        nextWithHash.append(firstWithHash[h] ?? .max)
        firstWithHash[h] = i
        items.append(key)
        return i
    }
}

private enum PlanSlot {
    case tags
    case user(UInt32)
    case login(UInt32)
    case profile(UInt32)
    case bySlug(UInt32)
    case byId(UInt32, knownFav: Bool?)
    case comments(UInt32)
    case global(UInt32)
    case filtered(Int, UInt32, UInt32)
    case feed(UInt32, UInt32)

    /// Answered from phase A1 alone (tags, the current user, logins handed to the bcrypt workers).
    var answeredByPhaseA1: Bool {
        switch self {
        case .tags, .user, .login: true
        default: false
        }
    }
}

/// Where an article's slug, title, description and timestamps are: the phase A row that found it (the lookups and
/// most lists carry them), or phase B's `artmeta` for the ones found by an index-only list (the feed).
private enum MetaSource {
    case none
    case phaseA(RowSpan)
    case phaseB(RowSpan)

    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}

private struct ArticleRef {
    var aid: Int64
    var author: Int64
    var artOrd: UInt32
    var row: RowSpan
}

private struct CachedArticleSlices {
    var ready = false
    var headStart: UInt32 = 0
    var headEnd: UInt32 = 0
    var midEnd: UInt32 = 0
    var tailEnd: UInt32 = 0
}

private struct CachedCommentSlice {
    var authorID: Int64
    var start: UInt32
    var end: UInt32
}

struct Pair: Comparable {
    var v: Int64
    var t: Int64
    static func < (a: Pair, b: Pair) -> Bool { a.v != b.v ? a.v < b.v : a.t < b.t }
}

extension Array where Element == Pair {
    fileprivate func containsSorted(_ x: Pair) -> Bool {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo < count && self[lo] == x
    }

    fileprivate mutating func sortAndDedup() {
        sort()
        var w = 0
        for i in indices where w == 0 || self[i] != self[w - 1] {
            self[w] = self[i]
            w += 1
        }
        removeLast(count - w)
    }
}

@inline(__always) private func viewerBit(_ viewer: Int64) -> UInt64 {
    1 << ((UInt64(bitPattern: viewer) &* 0x9E37_79B9_7F4A_7C15) >> 58)
}

@inline(__always) private func lexLess(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
    let n = min(a.count, b.count)
    let c = a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in compareBytes(pa.baseAddress, pb.baseAddress, n) } }
    return c != 0 ? c < 0 : a.count < b.count
}

private func buildFlagRuns(_ pairs: inout [Pair], _ viewers: inout [Int64], _ targets: inout [Int64],
                           _ starts: inout [Int32], _ ends: inout [Int32]) {
    pairs.sortAndDedup()
    viewers.removeAll(keepingCapacity: true)
    targets.removeAll(keepingCapacity: true)
    starts.removeAll(keepingCapacity: true)
    ends.removeAll(keepingCapacity: true)
    guard let first = pairs.first else { return }
    var current = first.v
    var runStart: Int32 = 1
    for (i, p) in pairs.enumerated() {
        if p.v != current {
            viewers.append(current)
            starts.append(runStart)
            ends.append(Int32(i))
            current = p.v
            runStart = Int32(i) + 1
        }
        targets.append(p.t)
    }
    viewers.append(current)
    starts.append(runStart)
    ends.append(Int32(pairs.count))
}

func writeUserEnvelope(_ dst: inout ByteBuffer, email: Span<UInt8>, token: Span<UInt8>, username: Span<UInt8>,
                       bio: Span<UInt8>?, image: Span<UInt8>?) {
    dst.append("{\"user\":{\"email\":")
    writeStr(&dst, email)
    dst.append(",\"token\":")
    writeStr(&dst, token)
    dst.append(",\"username\":")
    writeStr(&dst, username)
    dst.append(",\"bio\":")
    writeNullableStr(&dst, bio)
    dst.append(",\"image\":")
    writeNullableStr(&dst, image)
    dst.append("}}")
}

func writeProfileJSON(_ dst: inout ByteBuffer, username: Span<UInt8>, bio: Span<UInt8>?, image: Span<UInt8>?, following: Bool) {
    dst.append("{\"username\":")
    writeStr(&dst, username)
    dst.append(",\"bio\":")
    writeNullableStr(&dst, bio)
    dst.append(",\"image\":")
    writeNullableStr(&dst, image)
    dst.append(",\"following\":")
    writeBool(&dst, following)
    dst.append(0x7D)
}

func errorReply(_ addr: ReplyAddr, _ status: UInt16, _ message: StaticString) -> OutgoingReply {
    OutgoingReply(addr: addr, status: status, body: makeErrorJSON(message).take())
}

/// Sends each reactor its share of `replies`: one message per reactor, a child task starting on its loop.
func deliverReplies(_ replies: [OutgoingReply], to reactors: [Reactor], _ group: inout DiscardingTaskGroup) {
    guard !replies.isEmpty else { return }
    if reactors.count == 1 || replies.allSatisfy({ $0.addr.worker == replies[0].addr.worker }) {
        let reactor = reactors[Int(replies[0].addr.worker)]
        group.addTask(executorPreference: reactor.loop) { await reactor.deliver(replies) }
        return
    }
    var buckets = [[OutgoingReply]](repeating: [], count: reactors.count)
    for r in replies { buckets[Int(r.addr.worker)].append(r) }
    for (i, bucket) in buckets.enumerated() where !bucket.isEmpty {
        let reactor = reactors[i]
        group.addTask(executorPreference: reactor.loop) { await reactor.deliver(bucket) }
    }
}

private let filterStatementNames = ["tag", "author", "favlist"]

actor ReadLane {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let db: DbEndpoint
    private let scheduler: Scheduler
    private let reactors: [Reactor]

    private var conn: PgConn?
    private var pa = PipelineBuf()
    private var pb = PipelineBuf()
    private var arena = ByteBuffer(capacity: 128 * 1024)
    private var tagLut: [Cell] = []
    private var kUid = KeySet<Int64>()
    private var kUemail = BytesKeySet()
    private var kProf = BytesKeySet()
    private var kSlug = BytesKeySet()
    private var kAid = KeySet<Int64>()
    private var kCmts = BytesKeySet()
    private var kGlobal = KeySet<PairKey>()
    private var kFilterCounts = [BytesKeySet(), BytesKeySet(), BytesKeySet()]
    private var kFilterPages = [KeySet<PageKey>(), KeySet<PageKey>(), KeySet<PageKey>()]
    private var kFeedCnt = KeySet<Int64>()
    private var kFeedPage = KeySet<PageKey>()
    private var plan: [PlanSlot] = []
    private var distinctArts = KeySet<Int64>()
    private var distinctAuthors = KeySet<Int64>()
    private var artAuthorOrds: [UInt32] = []
    private var artMeta: [MetaSource] = []
    private var metaRequestIDs: [Int64] = []
    /// The batch's requests not answered yet: the ones a failure must answer with a 500.
    private var errorAddrs: [ReplyAddr] = []
    private var authorSpans: [RowSpan?] = []
    private var favPairs: [Pair] = []
    private var follPairs: [Pair] = []
    private var favViewers: [Int64] = []
    private var favTargets: [Int64] = []
    private var favStarts: [Int32] = []
    private var favEnds: [Int32] = []
    private var follViewers: [Int64] = []
    private var follTargets: [Int64] = []
    private var follStarts: [Int32] = []
    private var follEnds: [Int32] = []
    private var favHits: [Pair] = []
    private var follHits: [Pair] = []
    private var favViewerMask: UInt64 = 0
    private var follViewerMask: UInt64 = 0
    private var cachedArts: [CachedArticleSlices] = []
    private var feedDepths: [Int64] = []
    private var tagSortBuf: [Cell] = []

    init(loop: EventLoop, db: DbEndpoint, scheduler: Scheduler, reactors: [Reactor]) {
        self.loop = loop
        self.db = db
        self.scheduler = scheduler
        self.reactors = reactors
    }

    private func ensureConn() throws(PgError) {
        if conn == nil {
            var c = try PgConn.connect(db)
            try c.prepareBatch(readCatalog())
            conn = consume c
        }
    }

    func run() async {
        await withDiscardingTaskGroup { group in
            var finished: ReadBatchDone?
            while true {
                let tasks = await scheduler.nextReads(finished: finished)
                let t0 = monotonicNanos()
                var replies: [OutgoingReply] = []
                replies.reserveCapacity(tasks.count)
                do {
                    try executeBatch(tasks, &replies, &group)
                } catch {
                    logLine("read batch error: \(error)")
                    conn = nil
                    replies = errorAddrs.map { errorReply($0, 500, "internal server error") }
                }
                finished = ReadBatchDone(count: tasks.count, elapsedUs: Int((monotonicNanos() - t0) / 1000))
                deliverReplies(replies, to: reactors, &group)
            }
        }
    }

    // ---------- the batch ----------

    private func internArt(_ aid: Int64, _ author: Int64, _ row: RowSpan, _ meta: MetaSource) -> ArticleRef {
        let before = distinctArts.count
        let ord = distinctArts.intern(aid)
        if Int(ord) == before {
            artAuthorOrds.append(distinctAuthors.intern(author))
            artMeta.append(meta)
        } else if !meta.isNone && artMeta[Int(ord)].isNone {
            artMeta[Int(ord)] = meta
        }
        return ArticleRef(aid: aid, author: author, artOrd: ord, row: row)
    }

    /// Rows of statement `res` grouped by their ordinal column (1-based), as indices into its rows.
    private func groupRowsByOrdinal(_ res: Int?, _ keys: Int) -> [[Int]] {
        guard let res else { return [] }
        var grouped = [[Int]](repeating: [], count: keys)
        let range = pa.resultRows(res)
        for ri in range {
            let ord = pa.i64(pa.rows[ri], 0)
            if ord >= 1 && ord <= Int64(keys) { grouped[Int(ord) - 1].append(ri - range.lowerBound) }
        }
        return grouped
    }

    /// Each key's row of statement `res`, matched by the id in `column` (`map_rows_by_i64_into`).
    private func mapRows(_ res: Int?, _ keys: KeySet<Int64>, column: Int) -> [RowSpan?] {
        var out = [RowSpan?](repeating: nil, count: keys.count)
        guard let res else { return out }
        for ri in pa.resultRows(res) {
            let r = pa.rows[ri]
            if let k = keys.ordinal(of: pa.i64(r, column)) { out[Int(k)] = r }
        }
        return out
    }

    /// Each key's row of statement `res`, matched by the text in `column` (`map_rows_by_str_into`).
    private func mapRows(_ res: Int?, _ keys: BytesKeySet, column: Int) -> [RowSpan?] {
        var out = [RowSpan?](repeating: nil, count: keys.count)
        guard let res else { return out }
        for ri in pa.resultRows(res) {
            let r = pa.rows[ri]
            let c = pa.cell(r, column)
            if !c.isNull, let k = keys.ordinal(of: pa.text(c)) { out[Int(k)] = r }
        }
        return out
    }

    /// A list statement's counts (rows with ordinal <= 0) and pages (ordinal >= 1), newest first; `hasMeta` says
    /// whether its rows carry the articles' metadata.
    private func unpackList(_ res: Int?, _ nCount: Int, _ nPage: Int, hasMeta: Bool) -> ([Int64], [[ArticleRef]]) {
        var counts = [Int64](repeating: 0, count: max(nCount, 1))
        var pages = [[ArticleRef]](repeating: [], count: nPage)
        guard let res else { return (counts, pages) }
        var raw = [[(Int64, Int64, RowSpan)]](repeating: [], count: nPage)
        for ri in pa.resultRows(res) {
            let r = pa.rows[ri]
            let ord = pa.i64(r, 0)
            if ord <= 0 {
                let c = Int(-ord) == 0 ? 0 : Int(-ord) - 1
                if c < counts.count { counts[c] = pa.i64(r, 1) }
            } else if ord <= Int64(nPage) {
                raw[Int(ord) - 1].append((pa.i64(r, 1), pa.i64(r, 2), r))
            }
        }
        for p in 0..<nPage {
            var rp = raw[p]
            if rp.count > 1 { rp.sort { $0.0 > $1.0 } }
            pages[p].reserveCapacity(rp.count)
            for (aid, author, span) in rp { pages[p].append(internArt(aid, author, span, hasMeta ? .phaseA(span) : .none)) }
        }
        return (counts, pages)
    }

    private func executeBatch(_ tasks: [ReadTask], _ replies: inout [OutgoingReply],
                              _ group: inout DiscardingTaskGroup) throws(PgError) {
        errorAddrs = tasks.map(\.addr)
        var needTagsEndpoint = false
        kUid.clear()
        kUemail.clear()
        kProf.clear()
        kSlug.clear()
        kAid.clear()
        kCmts.clear()
        kGlobal.clear()
        for i in 0..<3 {
            kFilterCounts[i].clear()
            kFilterPages[i].clear()
        }
        kFeedCnt.clear()
        kFeedPage.clear()
        plan.removeAll(keepingCapacity: true)

        for t in tasks {
            let slot: PlanSlot
            switch t.op {
            case .tags:
                needTagsEndpoint = true
                slot = .tags
            case .currentUser(let id, _): slot = .user(kUid.intern(id))
            case .login(let email, _): slot = .login(kUemail.intern(email))
            case .profile(let username): slot = .profile(kProf.intern(username))
            case .articleBySlug(let slug): slot = .bySlug(kSlug.intern(slug))
            case .articleById(let id, let knownFav): slot = .byId(kAid.intern(id), knownFav: knownFav)
            case .comments(let slug): slot = .comments(kCmts.intern(slug))
            case .global(let lim, let off): slot = .global(kGlobal.intern(PairKey(a: lim, b: off)))
            case .byTag(let key, let lim, let off), .byAuthor(let key, let lim, let off), .byFavorited(let key, let lim, let off):
                let kind: Int
                switch t.op {
                case .byTag: kind = 0
                case .byAuthor: kind = 1
                default: kind = 2
                }
                let c = kFilterCounts[kind].intern(key)
                let p = kFilterPages[kind].intern(PageKey(c: c, lim: lim, off: off))
                slot = .filtered(kind, c, p)
            case .feed(let lim, let off):
                let c = kFeedCnt.intern(t.viewer)
                let p = kFeedPage.intern(PageKey(c: c, lim: lim, off: off))
                slot = .feed(c, p)
            }
            plan.append(slot)
        }

        let touchesArticles = kSlug.count + kAid.count + kGlobal.count + kFilterPages[0].count + kFilterPages[1].count
            + kFilterPages[2].count + kFeedCnt.count > 0

        try ensureConn()
        var nA = 0
        func alloc(_ active: Bool) -> Int? {
            guard active else { return nil }
            defer { nA += 1 }
            return nA
        }
        let stTags = alloc(needTagsEndpoint || touchesArticles)
        let stUid = alloc(kUid.count > 0)
        let stUemail = alloc(kUemail.count > 0)
        let stProf = alloc(kProf.count > 0)
        let stSlug = alloc(kSlug.count > 0)
        let stAid = alloc(kAid.count > 0)
        let stCmts = alloc(kCmts.count > 0)
        let stGlobal = alloc(kGlobal.count > 0)
        let stFilters = (0..<3).map { alloc(kFilterPages[$0].count > 0) }
        let stFeed = alloc(kFeedCnt.count > 0)
        let nA1 = [stTags, stUid, stUemail].count { $0 != nil }
        let nA2 = nA - nA1

        if nA1 > 0 {
            if stTags != nil { conn!.tx.bindAndExec("tags", []) }
            if stUid != nil { conn!.tx.bindAndExec("uid", [.i64Array(kUid.items)]) }
            if stUemail != nil { conn!.tx.bindAndExec("uemail", [.textArray(kUemail.items)]) }
            conn!.tx.writeSync()
        }
        var globalWinMax: Int64 = 0
        var useGlobalWin = kGlobal.count > 0
        for k in kGlobal.items {
            let end = k.a.addingReportingOverflow(k.b)
            if end.overflow || end.partialValue > 200 {
                useGlobalWin = false
                break
            }
            globalWinMax = max(globalWinMax, end.partialValue)
        }
        if nA2 > 0 {
            if stProf != nil { conn!.tx.bindAndExec("prof", [.textArray(kProf.items)]) }
            if stSlug != nil { conn!.tx.bindAndExec("aslug", [.textArray(kSlug.items)]) }
            if stAid != nil { conn!.tx.bindAndExec("aid", [.i64Array(kAid.items)]) }
            if stCmts != nil { conn!.tx.bindAndExec("cmts", [.textArray(kCmts.items)]) }
            if stGlobal != nil {
                if useGlobalWin {
                    conn!.tx.bindAndExec("global_win", [.i64(max(globalWinMax, 1))])
                } else {
                    conn!.tx.bindAndExec("global", [.i64Array(kGlobal.items.map(\.a)), .i64Array(kGlobal.items.map(\.b))])
                }
            }
            for i in 0..<3 where stFilters[i] != nil {
                let pages = kFilterPages[i].items
                conn!.tx.bindAndExec(filterStatementNames[i], [
                    .textArray(kFilterCounts[i].items),
                    .i64Array(pages.map { Int64($0.c) + 1 }), .i64Array(pages.map(\.lim)), .i64Array(pages.map(\.off)),
                ])
            }
            if stFeed != nil {
                feedDepths = [Int64](repeating: 1, count: kFeedCnt.count)
                for k in kFeedPage.items {
                    let (sum, overflow) = k.lim.addingReportingOverflow(k.off)
                    let d = max(overflow ? .max : sum, 1)
                    if d > feedDepths[Int(k.c)] { feedDepths[Int(k.c)] = d }
                }
                let pages = kFeedPage.items
                conn!.tx.bindAndExec("feed", [
                    .i64Array(kFeedCnt.items), .i64Array(feedDepths),
                    .i64Array(pages.map { Int64($0.c) + 1 }), .i64Array(pages.map(\.lim)), .i64Array(pages.map(\.off)),
                ])
            }
            conn!.tx.writeSync()
        }
        if nA > 0 { try conn!.flush() }
        pa.clear()
        tagLut.removeAll(keepingCapacity: true)

        if nA1 > 0 {
            try conn!.readPipeline(appendingTo: &pa, expected: nA1)
            if let failed = pa.results.first(where: { $0.error != nil }) { throw .wire("phase A1 error: \(failed.error!)") }
            if needTagsEndpoint, let s = stTags {
                let range = pa.resultRows(s)
                var sorted = Array(pa.rows[range])
                sorted.sort { lexLess(pa.text(pa.cell($0, 1)), pa.text(pa.cell($1, 1))) }
                pa.rows.replaceSubrange(range, with: sorted)
            }
            if touchesArticles, let s = stTags {
                let range = pa.resultRows(s)
                tagLut = [Cell](repeating: .null, count: range.count + 64)
                for ri in range {
                    let r = pa.rows[ri]
                    let tid = Int(pa.i64(r, 0))
                    if tid >= tagLut.count { tagLut.append(contentsOf: repeatElement(.null, count: tid + 16 - tagLut.count)) }
                    if tid >= 0 { tagLut[tid] = pa.cell(r, 1) }
                }
            }
            answerPhaseA1(tasks, stTags: stTags, stUid: stUid, stUemail: stUemail, &group)
            errorAddrs = zip(tasks, plan).filter { !$0.1.answeredByPhaseA1 }.map(\.0.addr)
            if nA2 == 0 { return }
        }
        if nA2 > 0 {
            try conn!.readPipeline(appendingTo: &pa, expected: nA2)
            if let failed = pa.results[nA1...].first(where: { $0.error != nil }) { throw .wire("phase A2 error: \(failed.error!)") }
        }

        distinctArts.clear()
        distinctAuthors.clear()
        artAuthorOrds.removeAll(keepingCapacity: true)
        artMeta.removeAll(keepingCapacity: true)

        let profRows = mapRows(stProf, kProf, column: 1)
        let grpCmts = groupRowsByOrdinal(stCmts, kCmts.count)

        var slugRows = [ArticleRef?](repeating: nil, count: kSlug.count)
        if let s = stSlug {
            for ri in pa.resultRows(s) {
                let r = pa.rows[ri]
                let slug = pa.cell(r, 3)
                if !slug.isNull, let k = kSlug.ordinal(of: pa.text(slug)) {
                    slugRows[Int(k)] = internArt(pa.i64(r, 1), pa.i64(r, 2), r, .phaseA(r))
                }
            }
        }
        var idRows = [ArticleRef?](repeating: nil, count: kAid.count)
        if let s = stAid {
            for ri in pa.resultRows(s) {
                let r = pa.rows[ri]
                let aid = pa.i64(r, 1)
                if let k = kAid.ordinal(of: aid) { idRows[Int(k)] = internArt(aid, pa.i64(r, 2), r, .phaseA(r)) }
            }
        }

        let globalCounts: [Int64]
        let globalPages: [[ArticleRef]]
        if useGlobalWin {
            let (counts, winPages) = unpackList(stGlobal, 1, 1, hasMeta: true)
            let win = winPages.first ?? []
            globalCounts = counts
            globalPages = kGlobal.items.map { k in
                let start = min(Int(max(k.b, 0)), win.count)
                let end = min(start + Int(max(k.a, 0)), win.count)
                return Array(win[start..<end])
            }
        } else {
            (globalCounts, globalPages) = unpackList(stGlobal, 1, kGlobal.count, hasMeta: true)
        }
        let filterResults = (0..<3).map {
            unpackList(stFilters[$0], kFilterCounts[$0].count, kFilterPages[$0].count, hasMeta: true)
        }
        let (feedCounts, feedPages) = unpackList(stFeed, kFeedCnt.count, kFeedPage.count, hasMeta: false)
        // Comment authors join the article authors in phase B's `artau`.
        if let s = stCmts {
            for ri in pa.resultRows(s) {
                let r = pa.rows[ri]
                if !pa.cell(r, 1).isNull && !pa.cell(r, 5).isNull { _ = distinctAuthors.intern(pa.i64(r, 5)) }
            }
        }
        metaRequestIDs.removeAll(keepingCapacity: true)
        for (k, meta) in artMeta.enumerated() where meta.isNone { metaRequestIDs.append(distinctArts.items[k]) }

        favPairs.removeAll(keepingCapacity: true)
        follPairs.removeAll(keepingCapacity: true)
        for (task, slot) in zip(tasks, plan) {
            let v = task.viewer
            if v == 0 { continue }
            switch slot {
            case .bySlug(let k):
                if let art = slugRows[Int(k)] {
                    favPairs.append(Pair(v: v, t: art.aid))
                    follPairs.append(Pair(v: v, t: art.author))
                }
            case .byId(let k, let knownFav):
                if let art = idRows[Int(k)] {
                    if knownFav == nil { favPairs.append(Pair(v: v, t: art.aid)) }
                    follPairs.append(Pair(v: v, t: art.author))
                }
            case .global(let p):
                for art in globalPages[Int(p)] {
                    favPairs.append(Pair(v: v, t: art.aid))
                    follPairs.append(Pair(v: v, t: art.author))
                }
            case .filtered(let kind, _, let p):
                let rows = filterResults[kind].1[Int(p)]
                if kind == 1 {
                    if let first = rows.first { follPairs.append(Pair(v: v, t: first.author)) }
                    for art in rows { favPairs.append(Pair(v: v, t: art.aid)) }
                } else {
                    for art in rows {
                        favPairs.append(Pair(v: v, t: art.aid))
                        follPairs.append(Pair(v: v, t: art.author))
                    }
                }
            case .feed(_, let p):
                for art in feedPages[Int(p)] { favPairs.append(Pair(v: v, t: art.aid)) }
            case .comments(let k):
                if let s = stCmts {
                    let base = pa.resultRows(s).lowerBound
                    for ri in grpCmts[Int(k)] {
                        let r = pa.rows[base + ri]
                        if !pa.cell(r, 1).isNull && !pa.cell(r, 5).isNull { follPairs.append(Pair(v: v, t: pa.i64(r, 5))) }
                    }
                }
            case .profile(let k):
                if let r = profRows[Int(k)] { follPairs.append(Pair(v: v, t: pa.i64(r, 0))) }
            case .tags, .user, .login:
                break
            }
        }
        buildFlagRuns(&favPairs, &favViewers, &favTargets, &favStarts, &favEnds)
        buildFlagRuns(&follPairs, &follViewers, &follTargets, &follStarts, &follEnds)

        var nB = 0
        func allocB(_ active: Bool) -> Int? {
            guard active else { return nil }
            defer { nB += 1 }
            return nB
        }
        let bArtmeta = allocB(!metaRequestIDs.isEmpty)
        let bArtx = allocB(distinctArts.count > 0)
        let bArtau = allocB(distinctAuthors.count > 0)
        let bFlags = allocB(!favViewers.isEmpty || !follViewers.isEmpty)
        if nB > 0 {
            if bArtmeta != nil { conn!.tx.bindAndExec("artmeta", [.i64Array(metaRequestIDs)]) }
            if bArtx != nil { conn!.tx.bindAndExec("artx", [.i64Array(distinctArts.items)]) }
            if bArtau != nil { conn!.tx.bindAndExec("artau", [.i64Array(distinctAuthors.items)]) }
            if bFlags != nil {
                conn!.tx.bindAndExec("flags", [
                    .i64Array(favViewers), .i64Array(favTargets), .i32Array(favStarts), .i32Array(favEnds),
                    .i64Array(follViewers), .i64Array(follTargets), .i32Array(follStarts), .i32Array(follEnds),
                ])
            }
            conn!.tx.writeSync()
            try conn!.flush()
        } else {
            pb.clear()
        }

        authorSpans = [RowSpan?](repeating: nil, count: distinctAuthors.count)
        cachedArts = [CachedArticleSlices](repeating: CachedArticleSlices(), count: distinctArts.count)
        arena.removeAll()
        favHits.removeAll(keepingCapacity: true)
        follHits.removeAll(keepingCapacity: true)
        favViewerMask = 0
        follViewerMask = 0

        var renderedProfiles = [[UInt8]?](repeating: nil, count: kProf.count)
        if stProf != nil { answerAnonymousProfiles(tasks, profRows, &renderedProfiles, &group) }

        if nB > 0 {
            try conn!.readPipeline(into: &pb, expected: nB)
            if let failed = pb.results.first(where: { $0.error != nil }) { throw .wire("phase B error: \(failed.error!)") }
            if let s = bArtmeta {
                for ri in pb.resultRows(s) {
                    let r = pb.rows[ri]
                    if let k = distinctArts.ordinal(of: pb.i64(r, 0)) { artMeta[Int(k)] = .phaseB(r) }
                }
            }
            if let s = bArtau {
                for ri in pb.resultRows(s) {
                    let r = pb.rows[ri]
                    if let k = distinctAuthors.ordinal(of: pb.i64(r, 0)) { authorSpans[Int(k)] = r }
                }
            }
            if let s = bArtx { renderArticleFragments(s) }
            if let s = bFlags {
                for ri in pb.resultRows(s) {
                    let r = pb.rows[ri]
                    let kind = pb.i64(r, 0), viewer = pb.i64(r, 1), target = pb.i64(r, 2)
                    if kind == 0 {
                        favViewerMask |= viewerBit(viewer)
                        favHits.append(Pair(v: viewer, t: target))
                    } else {
                        follViewerMask |= viewerBit(viewer)
                        follHits.append(Pair(v: viewer, t: target))
                    }
                }
                favHits.sort()
                follHits.sort()
            }
        }

        let cachedComments = stCmts.map { renderCommentFragments($0, grpCmts) } ?? []

        var renderedSlugs = [[UInt8]?](repeating: nil, count: kSlug.count)
        var renderedComments = [[UInt8]?](repeating: nil, count: kCmts.count)
        var renderedGlobal = [[UInt8]?](repeating: nil, count: globalPages.count)
        var renderedFilters = filterResults.map { [[UInt8]?](repeating: nil, count: $0.1.count) }

        for (task, slot) in zip(tasks, plan) {
            let viewer = task.viewer
            let addr = task.addr
            switch slot {
            case .tags, .user, .login:
                break
            case .profile(let k):
                if viewer == 0 { continue }
                guard let r = profRows[Int(k)] else {
                    replies.append(errorReply(addr, 404, "profile not found"))
                    continue
                }
                let following = isFollowing(viewer, pa.i64(r, 0))
                if !following, let shared = renderedProfiles[Int(k)] {
                    replies.append(OutgoingReply(addr: addr, status: 200, body: shared))
                    continue
                }
                var body = ByteBuffer(capacity: 256)
                body.append("{\"profile\":")
                writeProfileJSON(&body, username: pa.text(pa.cell(r, 1)), bio: pa.bytes(pa.cell(r, 2)),
                                 image: pa.bytes(pa.cell(r, 3)), following: following)
                body.append(0x7D)
                let bytes = body.take()
                if !following { renderedProfiles[Int(k)] = bytes }
                replies.append(OutgoingReply(addr: addr, status: 200, body: bytes))
            case .bySlug(let k):
                guard let art = slugRows[Int(k)] else {
                    replies.append(errorReply(addr, 404, "article not found"))
                    continue
                }
                let unflagged = isArticleUnflagged(art, viewer)
                if unflagged, let shared = renderedSlugs[Int(k)] {
                    replies.append(OutgoingReply(addr: addr, status: 200, body: shared))
                    continue
                }
                var body = ByteBuffer(capacity: 2048)
                body.append("{\"article\":")
                if writeArticle(&body, art, includeBody: true, viewer: viewer, knownFollowing: false, knownFav: nil) {
                    body.append(0x7D)
                    let bytes = body.take()
                    if unflagged { renderedSlugs[Int(k)] = bytes }
                    replies.append(OutgoingReply(addr: addr, status: 200, body: bytes))
                } else {
                    replies.append(errorReply(addr, 404, "article not found"))
                }
            case .byId(let k, let knownFav):
                guard let art = idRows[Int(k)] else {
                    replies.append(errorReply(addr, 404, "article not found"))
                    continue
                }
                var body = ByteBuffer(capacity: 2048)
                body.append("{\"article\":")
                if writeArticle(&body, art, includeBody: true, viewer: viewer, knownFollowing: false, knownFav: knownFav) {
                    body.append(0x7D)
                    replies.append(OutgoingReply(addr: addr, status: 200, body: body.take()))
                } else {
                    replies.append(errorReply(addr, 404, "article not found"))
                }
            case .comments(let k):
                guard let list = cachedComments[Int(k)] else {
                    replies.append(errorReply(addr, 404, "article not found"))
                    continue
                }
                let unflagged = viewer == 0 || list.allSatisfy { !isFollowing(viewer, $0.authorID) }
                if unflagged, let shared = renderedComments[Int(k)] {
                    replies.append(OutgoingReply(addr: addr, status: 200, body: shared))
                    continue
                }
                var body = ByteBuffer(capacity: 64 + 320 * list.count)
                body.append("{\"comments\":[")
                for (i, c) in list.enumerated() {
                    if i > 0 { body.append(0x2C) }
                    body.append(arena, Int(c.start)..<Int(c.end))
                    body.append(!unflagged && isFollowing(viewer, c.authorID) ? "true}}" : "false}}")
                }
                body.append("]}")
                let bytes = body.take()
                if unflagged { renderedComments[Int(k)] = bytes }
                replies.append(OutgoingReply(addr: addr, status: 200, body: bytes))
            case .global, .filtered, .feed:
                let rows: [ArticleRef]
                let total: Int64
                let isFeed: Bool
                switch slot {
                case .global(let p): (rows, total, isFeed) = (globalPages[Int(p)], globalCounts[0], false)
                case .filtered(let kind, let c, let p): (rows, total, isFeed) = (filterResults[kind].1[Int(p)], filterResults[kind].0[Int(c)], false)
                case .feed(let c, let p): (rows, total, isFeed) = (feedPages[Int(p)], feedCounts[Int(c)], true)
                default: continue
                }
                let unflagged = !isFeed && (viewer == 0 || rows.allSatisfy { isArticleUnflagged($0, viewer) })
                if unflagged {
                    var cached: [UInt8]?
                    if case .global(let p) = slot { cached = renderedGlobal[Int(p)] }
                    if case .filtered(let kind, _, let p) = slot { cached = renderedFilters[kind][Int(p)] }
                    if let cached {
                        replies.append(OutgoingReply(addr: addr, status: 200, body: cached))
                        continue
                    }
                }
                var body = ByteBuffer(capacity: 512 + 700 * rows.count)
                body.append("{\"articles\":[")
                var first = true
                for art in rows {
                    let mark = body.count
                    if !first { body.append(0x2C) }
                    if writeArticle(&body, art, includeBody: false, viewer: unflagged ? 0 : viewer, knownFollowing: isFeed,
                                    knownFav: nil) {
                        first = false
                    } else {
                        body.truncate(mark)
                    }
                }
                body.append("],\"articlesCount\":")
                writeI64(&body, total)
                body.append(0x7D)
                let bytes = body.take()
                if unflagged {
                    if case .global(let p) = slot { renderedGlobal[Int(p)] = bytes }
                    if case .filtered(let kind, _, let p) = slot { renderedFilters[kind][Int(p)] = bytes }
                }
                replies.append(OutgoingReply(addr: addr, status: 200, body: bytes))
            }
        }
    }

    /// Phase A1's replies, sent at once: tags, the current user, and logins whose email has no user; the others go to
    /// the bcrypt workers.
    private func answerPhaseA1(_ tasks: [ReadTask], stTags: Int?, stUid: Int?, stUemail: Int?,
                               _ group: inout DiscardingTaskGroup) {
        let uidRows = mapRows(stUid, kUid, column: 0)
        let uemailRows = mapRows(stUemail, kUemail, column: 2)
        var early: [OutgoingReply] = []
        var logins: [CryptoTask] = []
        var renderedTags: [UInt8]?
        for (task, slot) in zip(tasks, plan) {
            switch slot {
            case .tags:
                if renderedTags == nil, let s = stTags {
                    var buf = ByteBuffer(capacity: 4096)
                    buf.append("{\"tags\":[")
                    for (i, ri) in pa.resultRows(s).enumerated() {
                        if i > 0 { buf.append(0x2C) }
                        writeStr(&buf, pa.text(pa.cell(pa.rows[ri], 1)))
                    }
                    buf.append("]}")
                    renderedTags = buf.take()
                }
                early.append(OutgoingReply(addr: task.addr, status: 200, body: renderedTags ?? []))
            case .user(let k):
                guard case .currentUser(_, let token) = task.op else { continue }
                if let r = uidRows[Int(k)] {
                    var body = ByteBuffer(capacity: 512)
                    writeUserEnvelope(&body, email: pa.text(pa.cell(r, 2)), token: token.span, username: pa.text(pa.cell(r, 1)),
                                      bio: pa.bytes(pa.cell(r, 3)), image: pa.bytes(pa.cell(r, 4)))
                    early.append(OutgoingReply(addr: task.addr, status: 200, body: body.take()))
                } else {
                    early.append(errorReply(task.addr, 401, "unauthorized"))
                }
            case .login(let k):
                guard case .login(_, let password) = task.op else { continue }
                if let r = uemailRows[Int(k)] {
                    let user = UserRecord(id: pa.i64(r, 0), username: pa.copy(pa.cell(r, 1)) ?? [],
                                          email: pa.copy(pa.cell(r, 2)) ?? [], bio: pa.copy(pa.cell(r, 3)),
                                          image: pa.copy(pa.cell(r, 4)))
                    logins.append(.verifyLogin(password: password, hash: pa.copy(pa.cell(r, 5)) ?? [], user: user, addr: task.addr))
                } else {
                    early.append(errorReply(task.addr, 401, "invalid email or password"))
                }
            default:
                break
            }
        }
        if !logins.isEmpty {
            let scheduler = scheduler
            let work = Submission(crypto: logins)
            group.addTask(executorPreference: scheduler.loop) { await scheduler.submit(work) }
        }
        deliverReplies(early, to: reactors, &group)
    }

    /// Profiles asked for without a token depend on nothing phase B fetches: answered while it runs.
    private func answerAnonymousProfiles(_ tasks: [ReadTask], _ profRows: [RowSpan?], _ rendered: inout [[UInt8]?],
                                         _ group: inout DiscardingTaskGroup) {
        var mid: [OutgoingReply] = []
        for (task, slot) in zip(tasks, plan) where task.viewer == 0 {
            guard case .profile(let k) = slot else { continue }
            guard let r = profRows[Int(k)] else {
                mid.append(errorReply(task.addr, 404, "profile not found"))
                continue
            }
            if rendered[Int(k)] == nil {
                var body = ByteBuffer(capacity: 256)
                body.append("{\"profile\":")
                writeProfileJSON(&body, username: pa.text(pa.cell(r, 1)), bio: pa.bytes(pa.cell(r, 2)),
                                 image: pa.bytes(pa.cell(r, 3)), following: false)
                body.append(0x7D)
                rendered[Int(k)] = body.take()
            }
            mid.append(OutgoingReply(addr: task.addr, status: 200, body: rendered[Int(k)] ?? []))
        }
        guard !mid.isEmpty else { return }
        deliverReplies(mid, to: reactors, &group)
        errorAddrs = zip(tasks, plan).filter { task, slot in
            if slot.answeredByPhaseA1 { return false }
            if case .profile = slot, task.viewer == 0 { return false }
            return true
        }.map(\.0.addr)
    }

    /// Each distinct article's JSON, once, into the arena, split where the viewer-dependent parts go.
    private func renderArticleFragments(_ s: Int) {
        for ri in pb.resultRows(s) {
            let r = pb.rows[ri]
            guard let ord = distinctArts.ordinal(of: pb.i64(r, 0)) else { continue }
            let k = Int(ord)
            let auOrd = Int(artAuthorOrds[k])
            guard auOrd < authorSpans.count, let au = authorSpans[auOrd] else { continue }

            let headStart = UInt32(arena.count)
            let createdAt: Int64
            let updatedAt: Int64
            switch artMeta[k] {
            case .phaseA(let m): (createdAt, updatedAt) = writeArticleHead(&arena, pa, m, firstColumn: 3)
            case .phaseB(let m): (createdAt, updatedAt) = writeArticleHead(&arena, pb, m, firstColumn: 1)
            case .none: continue
            }
            let headEnd = UInt32(arena.count)

            arena.append(",\"tagList\":[")
            tagSortBuf.removeAll(keepingCapacity: true)
            forEachArrayElement(pb.text(pb.cell(r, 1))) { elem in
                guard elem.count == 4 else { return }
                let tid = Int(elem.bytes.load(fromByteOffset: 0, as: Int32.self, .bigEndian))
                if tid >= 0 && tid < tagLut.count && !tagLut[tid].isNull { tagSortBuf.append(tagLut[tid]) }
            }
            if tagSortBuf.count > 1 { tagSortBuf.sort { lexLess(pa.text($0), pa.text($1)) } }
            for (i, name) in tagSortBuf.enumerated() {
                if i > 0 { arena.append(0x2C) }
                writeStr(&arena, pa.text(name))
            }
            arena.append("],\"createdAt\":")
            writeTimestamp(&arena, createdAt)
            arena.append(",\"updatedAt\":")
            writeTimestamp(&arena, updatedAt)
            arena.append(",\"favorited\":")
            let midEnd = UInt32(arena.count)

            arena.append(",\"favoritesCount\":")
            writeI64(&arena, pb.i64(r, 2))
            arena.append(",\"author\":{\"username\":")
            writeStr(&arena, pb.text(pb.cell(au, 1)))
            arena.append(",\"bio\":")
            writeNullableStr(&arena, pb.bytes(pb.cell(au, 2)))
            arena.append(",\"image\":")
            writeNullableStr(&arena, pb.bytes(pb.cell(au, 3)))
            arena.append(",\"following\":")
            let tailEnd = UInt32(arena.count)

            cachedArts[k] = CachedArticleSlices(ready: true, headStart: headStart, headEnd: headEnd, midEnd: midEnd, tailEnd: tailEnd)
        }
    }

    /// Each requested article's comment list, newest first, into the arena (authors from phase B's `artau`); nil for
    /// an article that doesn't exist.
    private func renderCommentFragments(_ s: Int, _ groups: [[Int]]) -> [[CachedCommentSlice]?] {
        let base = pa.resultRows(s).lowerBound
        var out: [[CachedCommentSlice]?] = []
        out.reserveCapacity(groups.count)
        for indices in groups {
            if indices.isEmpty {
                out.append(nil)
                continue
            }
            var rows: [(created: Int64, id: Int64, row: RowSpan, author: RowSpan)] = []
            rows.reserveCapacity(indices.count)
            for i in indices {
                let r = pa.rows[base + i]
                guard !pa.cell(r, 1).isNull && !pa.cell(r, 5).isNull,
                      let au = distinctAuthors.ordinal(of: pa.i64(r, 5)), let author = authorSpans[Int(au)] else { continue }
                rows.append((pa.i64(r, 3), pa.i64(r, 1), r, author))
            }
            rows.sort { $0.created != $1.created ? $0.created > $1.created : $0.id > $1.id }
            var list: [CachedCommentSlice] = []
            list.reserveCapacity(rows.count)
            for c in rows {
                let start = UInt32(arena.count)
                arena.append("{\"id\":")
                writeI64(&arena, c.id)
                arena.append(",\"createdAt\":")
                writeTimestamp(&arena, c.created)
                arena.append(",\"updatedAt\":")
                writeTimestamp(&arena, pa.i64(c.row, 4))
                arena.append(",\"body\":")
                writeStr(&arena, pa.text(pa.cell(c.row, 2)))
                arena.append(",\"author\":{\"username\":")
                writeStr(&arena, pb.text(pb.cell(c.author, 1)))
                arena.append(",\"bio\":")
                writeNullableStr(&arena, pb.bytes(pb.cell(c.author, 2)))
                arena.append(",\"image\":")
                writeNullableStr(&arena, pb.bytes(pb.cell(c.author, 3)))
                arena.append(",\"following\":")
                list.append(CachedCommentSlice(authorID: pa.i64(c.row, 5), start: start, end: UInt32(arena.count)))
            }
            out.append(list)
        }
        return out
    }

    // ---------- flags and rendering (RenderCtx) ----------

    @inline(__always) private func isFollowing(_ viewer: Int64, _ author: Int64) -> Bool {
        follViewerMask & viewerBit(viewer) != 0 && follHits.containsSorted(Pair(v: viewer, t: author))
    }

    @inline(__always) private func isFavorited(_ viewer: Int64, _ article: Int64) -> Bool {
        favViewerMask & viewerBit(viewer) != 0 && favHits.containsSorted(Pair(v: viewer, t: article))
    }

    @inline(__always) private func isArticleUnflagged(_ art: ArticleRef, _ viewer: Int64) -> Bool {
        viewer == 0 || (!isFavorited(viewer, art.aid) && !isFollowing(viewer, art.author))
    }

    /// `knownFav`: the favorited flag a write just set, used instead of the looked-up one.
    private func writeArticle(_ dst: inout ByteBuffer, _ art: ArticleRef, includeBody: Bool, viewer: Int64,
                              knownFollowing: Bool, knownFav: Bool?) -> Bool {
        guard Int(art.artOrd) < cachedArts.count else { return false }
        let slices = cachedArts[Int(art.artOrd)]
        guard slices.ready else { return false }
        let fav = knownFav ?? (viewer != 0 && isFavorited(viewer, art.aid))
        let foll = knownFollowing || (viewer != 0 && isFollowing(viewer, art.author))
        if includeBody {
            dst.append(arena, Int(slices.headStart)..<Int(slices.headEnd))
            dst.append(",\"body\":")
            writeStr(&dst, pa.text(pa.cell(art.row, 8)))
            dst.append(arena, Int(slices.headEnd)..<Int(slices.midEnd))
        } else {
            dst.append(arena, Int(slices.headStart)..<Int(slices.midEnd))
        }
        dst.append(fav ? "true" : "false")
        dst.append(arena, Int(slices.midEnd)..<Int(slices.tailEnd))
        dst.append(foll ? "true}}" : "false}}")
        return true
    }
}

/// An article's `{"slug":…,"title":…,"description":…` from a row whose metadata (slug, title, description,
/// created_at, updated_at) starts at column `first`; returns the two timestamps.
private func writeArticleHead(_ dst: inout ByteBuffer, _ p: borrowing PipelineBuf, _ r: RowSpan,
                              firstColumn first: Int) -> (Int64, Int64) {
    dst.append("{\"slug\":")
    writeStr(&dst, p.text(p.cell(r, first)))
    dst.append(",\"title\":")
    writeStr(&dst, p.text(p.cell(r, first + 1)))
    dst.append(",\"description\":")
    writeStr(&dst, p.text(p.cell(r, first + 2)))
    return (p.i64(r, first + 3), p.i64(r, first + 4))
}
