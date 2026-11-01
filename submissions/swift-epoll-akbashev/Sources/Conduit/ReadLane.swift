// engine.rs's ReadWorker: a read lane, an actor with one Postgres connection, answering a whole batch of reads of
// every kind in two pipelined round trips. Phase A resolves what each request is about with one statement per kind
// present, over the batch's distinct keys; phase B enriches the union of the articles phase A found (metadata, tags,
// favorite counts, authors), once each, and the viewers' favorited/following flags. Every article's JSON is written
// once per batch with its two viewer-dependent booleans left open, and responses that come out identical are built
// once and shared.

/// A byte string as a dictionary key, hashed as one block of bytes.
struct ByteKey: Hashable {
    let bytes: [UInt8]
    func hash(into hasher: inout Hasher) { bytes.withUnsafeBytes { hasher.combine(bytes: $0) } }
}

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
}

/// `KeySet<String>`, whose items go to Postgres as a text[].
struct BytesKeySet {
    private var set = KeySet<ByteKey>()
    private(set) var items: [[UInt8]] = []

    var count: Int { items.count }

    mutating func clear() {
        set.clear()
        items.removeAll(keepingCapacity: true)
    }

    mutating func intern(_ key: [UInt8]) -> UInt32 {
        let before = set.count
        let i = set.intern(ByteKey(bytes: key))
        if set.count > before { items.append(key) }
        return i
    }
}

private enum PlanSlot {
    case tags
    case user(UInt32)
    case login(UInt32)
    case profile(UInt32)
    case bySlug(UInt32)
    case byId(UInt32)
    case comments(UInt32)
    case global(UInt32)
    case filtered(Int, UInt32, UInt32)
    case feed(UInt32, UInt32)
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
                    replies = tasks.map { errorReply($0.addr, 500, "internal server error") }
                }
                finished = ReadBatchDone(count: tasks.count, elapsedUs: Int((monotonicNanos() - t0) / 1000))
                deliverReplies(replies, to: reactors, &group)
            }
        }
    }

    // ---------- the batch ----------

    private func internArt(_ aid: Int64, _ author: Int64, _ row: RowSpan) -> ArticleRef {
        let before = distinctArts.count
        let ord = distinctArts.intern(aid)
        if Int(ord) == before { artAuthorOrds.append(distinctAuthors.intern(author)) }
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

    private func singleArticle(_ res: Int?, _ len: Int) -> [ArticleRef?] {
        var out = [ArticleRef?](repeating: nil, count: len)
        guard let res else { return out }
        for ri in pa.resultRows(res) {
            let r = pa.rows[ri]
            let ord = pa.i64(r, 0)
            if ord >= 1 && ord <= Int64(len) { out[Int(ord) - 1] = internArt(pa.i64(r, 1), pa.i64(r, 2), r) }
        }
        return out
    }

    private func unpackList(_ res: Int?, _ nCount: Int, _ nPage: Int) -> ([Int64], [[ArticleRef]]) {
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
            for (aid, author, span) in rp { pages[p].append(internArt(aid, author, span)) }
        }
        return (counts, pages)
    }

    private func executeBatch(_ tasks: [ReadTask], _ replies: inout [OutgoingReply],
                              _ group: inout DiscardingTaskGroup) throws(PgError) {
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
            case .articleById(let id, _): slot = .byId(kAid.intern(id))
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
        let stUid = alloc(kUid.count > 0)
        let stUemail = alloc(kUemail.count > 0)
        let stProf = alloc(kProf.count > 0)
        let stSlug = alloc(kSlug.count > 0)
        let stAid = alloc(kAid.count > 0)
        let stCmts = alloc(kCmts.count > 0)
        let stGlobal = alloc(kGlobal.count > 0)
        let stFilters = (0..<3).map { alloc(kFilterPages[$0].count > 0) }
        let stFeed = alloc(kFeedCnt.count > 0)
        let stTags = alloc(needTagsEndpoint || touchesArticles)

        if stUid != nil { conn!.tx.bindAndExec("uid", [.i64Array(kUid.items)]) }
        if stUemail != nil { conn!.tx.bindAndExec("uemail", [.textArray(kUemail.items)]) }
        if stProf != nil { conn!.tx.bindAndExec("prof", [.textArray(kProf.items)]) }
        if stSlug != nil { conn!.tx.bindAndExec("aslug", [.textArray(kSlug.items)]) }
        if stAid != nil { conn!.tx.bindAndExec("aid", [.i64Array(kAid.items)]) }
        if stCmts != nil { conn!.tx.bindAndExec("cmts", [.textArray(kCmts.items)]) }
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
        if stTags != nil { conn!.tx.bindAndExec("tags", []) }
        conn!.tx.writeSync()
        try conn!.flush()
        try conn!.readPipeline(into: &pa, expected: nA)
        if let failed = pa.results.first(where: { $0.error != nil }) { throw .wire("phase A error: \(failed.error!)") }

        if needTagsEndpoint, let s = stTags {
            let range = pa.resultRows(s)
            var sorted = Array(pa.rows[range])
            sorted.sort { lexLess(pa.text(pa.cell($0, 1)), pa.text(pa.cell($1, 1))) }
            pa.rows.replaceSubrange(range, with: sorted)
        }

        distinctArts.clear()
        distinctAuthors.clear()
        artAuthorOrds.removeAll(keepingCapacity: true)

        let grpUid = groupRowsByOrdinal(stUid, kUid.count)
        let grpUemail = groupRowsByOrdinal(stUemail, kUemail.count)
        let grpProf = groupRowsByOrdinal(stProf, kProf.count)
        let grpCmts = groupRowsByOrdinal(stCmts, kCmts.count)

        // Login password checks go to the bcrypt workers before phase B.
        if let sU = stUemail {
            var earlyErrors: [OutgoingReply] = []
            var logins: [CryptoTask] = []
            let base = pa.resultRows(sU).lowerBound
            for (task, slot) in zip(tasks, plan) {
                guard case .login(let k) = slot, case .login(_, let password) = task.op else { continue }
                if let ri = grpUemail[Int(k)].first {
                    let r = pa.rows[base + ri]
                    let user = UserRecord(id: pa.i64(r, 1), username: pa.copy(pa.cell(r, 2)) ?? [],
                                          email: pa.copy(pa.cell(r, 3)) ?? [], bio: pa.copy(pa.cell(r, 4)),
                                          image: pa.copy(pa.cell(r, 5)))
                    logins.append(.verifyLogin(password: password, hash: pa.copy(pa.cell(r, 6)) ?? [], user: user, addr: task.addr))
                } else {
                    earlyErrors.append(errorReply(task.addr, 401, "invalid email or password"))
                }
            }
            if !logins.isEmpty {
                let scheduler = scheduler
                group.addTask(executorPreference: scheduler.loop) { await scheduler.submit(Submission(crypto: logins)) }
            }
            deliverReplies(earlyErrors, to: reactors, &group)
        }

        let slugRows = singleArticle(stSlug, kSlug.count)
        let idRows = singleArticle(stAid, kAid.count)

        let globalCounts: [Int64]
        let globalPages: [[ArticleRef]]
        if useGlobalWin {
            let (counts, winPages) = unpackList(stGlobal, 1, 1)
            let win = winPages.first ?? []
            globalCounts = counts
            globalPages = kGlobal.items.map { k in
                let start = min(Int(max(k.b, 0)), win.count)
                let end = min(start + Int(max(k.a, 0)), win.count)
                return Array(win[start..<end])
            }
        } else {
            (globalCounts, globalPages) = unpackList(stGlobal, 1, kGlobal.count)
        }
        let filterResults = (0..<3).map { unpackList(stFilters[$0], kFilterCounts[$0].count, kFilterPages[$0].count) }
        let (feedCounts, feedPages) = unpackList(stFeed, kFeedCnt.count, kFeedPage.count)

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
            case .byId(let k):
                if let art = idRows[Int(k)] {
                    favPairs.append(Pair(v: v, t: art.aid))
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
                        if !pa.cell(r, 2).isNull { follPairs.append(Pair(v: v, t: pa.i64(r, 6))) }
                    }
                }
            case .profile(let k):
                if let s = stProf, let ri = grpProf[Int(k)].first {
                    follPairs.append(Pair(v: v, t: pa.i64(pa.rows[pa.resultRows(s).lowerBound + ri], 1)))
                }
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
        let bArtx = allocB(distinctArts.count > 0)
        let bArtau = allocB(distinctAuthors.count > 0)
        let bFlags = allocB(!favViewers.isEmpty || !follViewers.isEmpty)
        if nB > 0 {
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
            try conn!.readPipeline(into: &pb, expected: nB)
            if let failed = pb.results.first(where: { $0.error != nil }) { throw .wire("phase B error: \(failed.error!)") }
        } else {
            pb.clear()
        }

        tagLut.removeAll(keepingCapacity: true)
        if let s = stTags {
            let range = pa.resultRows(s)
            tagLut = [Cell](repeating: .null, count: range.count + 64)
            for ri in range {
                let r = pa.rows[ri]
                let tid = Int(pa.i64(r, 0))
                if tid >= tagLut.count { tagLut.append(contentsOf: repeatElement(.null, count: tid + 16 - tagLut.count)) }
                if tid >= 0 { tagLut[tid] = pa.cell(r, 1) }
            }
        }

        authorSpans = [RowSpan?](repeating: nil, count: distinctAuthors.count)
        cachedArts = [CachedArticleSlices](repeating: CachedArticleSlices(), count: distinctArts.count)
        arena.removeAll()
        favHits.removeAll(keepingCapacity: true)
        follHits.removeAll(keepingCapacity: true)
        favViewerMask = 0
        follViewerMask = 0

        if nB > 0 {
            if let s = bArtau {
                for ri in pb.resultRows(s) {
                    let r = pb.rows[ri]
                    let ord = pb.i64(r, 0)
                    if ord >= 1 && ord <= Int64(authorSpans.count) { authorSpans[Int(ord) - 1] = r }
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

        var renderedTags: [UInt8]?
        var renderedProfiles = [[UInt8]?](repeating: nil, count: kProf.count)
        var renderedSlugs = [[UInt8]?](repeating: nil, count: kSlug.count)
        var renderedComments = [[UInt8]?](repeating: nil, count: kCmts.count)
        var renderedGlobal = [[UInt8]?](repeating: nil, count: globalPages.count)
        var renderedFilters = filterResults.map { [[UInt8]?](repeating: nil, count: $0.1.count) }

        for (task, slot) in zip(tasks, plan) {
            let viewer = task.viewer
            let addr = task.addr
            switch slot {
            case .tags:
                if renderedTags == nil {
                    var buf = ByteBuffer(capacity: 4096)
                    buf.append("{\"tags\":[")
                    for (i, ri) in pa.resultRows(stTags!).enumerated() {
                        if i > 0 { buf.append(0x2C) }
                        writeStr(&buf, pa.text(pa.cell(pa.rows[ri], 1)))
                    }
                    buf.append("]}")
                    renderedTags = buf.take()
                }
                replies.append(OutgoingReply(addr: addr, status: 200, body: renderedTags!))
            case .user(let k):
                guard case .currentUser(_, let token) = task.op else { continue }
                if let ri = grpUid[Int(k)].first {
                    let r = pa.rows[pa.resultRows(stUid!).lowerBound + ri]
                    var body = ByteBuffer(capacity: 512)
                    writeUserEnvelope(&body, email: pa.text(pa.cell(r, 3)), token: token.span, username: pa.text(pa.cell(r, 2)),
                                      bio: pa.bytes(pa.cell(r, 4)), image: pa.bytes(pa.cell(r, 5)))
                    replies.append(OutgoingReply(addr: addr, status: 200, body: body.take()))
                } else {
                    replies.append(errorReply(addr, 401, "unauthorized"))
                }
            case .login:
                break
            case .profile(let k):
                guard let ri = grpProf[Int(k)].first else {
                    replies.append(errorReply(addr, 404, "profile not found"))
                    continue
                }
                let r = pa.rows[pa.resultRows(stProf!).lowerBound + ri]
                let following = viewer != 0 && isFollowing(viewer, pa.i64(r, 1))
                if !following, let shared = renderedProfiles[Int(k)] {
                    replies.append(OutgoingReply(addr: addr, status: 200, body: shared))
                    continue
                }
                var body = ByteBuffer(capacity: 256)
                body.append("{\"profile\":")
                writeProfileJSON(&body, username: pa.text(pa.cell(r, 2)), bio: pa.bytes(pa.cell(r, 3)),
                                 image: pa.bytes(pa.cell(r, 4)), following: following)
                body.append(0x7D)
                let bytes = body.take()
                if !following { renderedProfiles[Int(k)] = bytes }
                replies.append(OutgoingReply(addr: addr, status: 200, body: bytes))
            case .bySlug(let k), .byId(let k):
                let item: ArticleRef?
                let status: UInt16
                let isSlug: Bool
                if case .bySlug = slot {
                    (item, status, isSlug) = (slugRows[Int(k)], 200, true)
                } else {
                    guard case .articleById(_, let st) = task.op else { continue }
                    (item, status, isSlug) = (idRows[Int(k)], st, false)
                }
                guard let art = item else {
                    replies.append(errorReply(addr, 404, "article not found"))
                    continue
                }
                let unflagged = isSlug && isArticleUnflagged(art, viewer)
                if unflagged, let shared = renderedSlugs[Int(k)] {
                    replies.append(OutgoingReply(addr: addr, status: status, body: shared))
                    continue
                }
                var body = ByteBuffer(capacity: 2048)
                body.append("{\"article\":")
                if writeArticle(&body, art, includeBody: true, viewer: viewer, knownFollowing: false) {
                    body.append(0x7D)
                    let bytes = body.take()
                    if unflagged { renderedSlugs[Int(k)] = bytes }
                    replies.append(OutgoingReply(addr: addr, status: status, body: bytes))
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
                    if writeArticle(&body, art, includeBody: false, viewer: unflagged ? 0 : viewer, knownFollowing: isFeed) {
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

    /// Each distinct article's JSON, once, into the arena, split where the viewer-dependent parts go.
    private func renderArticleFragments(_ s: Int) {
        let nArts = distinctArts.count
        for ri in pb.resultRows(s) {
            let r = pb.rows[ri]
            let ord = pb.i64(r, 0)
            guard ord >= 1 && ord <= Int64(nArts) else { continue }
            let k = Int(ord) - 1
            let auOrd = Int(artAuthorOrds[k])
            guard auOrd < authorSpans.count, let au = authorSpans[auOrd] else { continue }

            let headStart = UInt32(arena.count)
            arena.append("{\"slug\":")
            writeStr(&arena, pb.text(pb.cell(r, 1)))
            arena.append(",\"title\":")
            writeStr(&arena, pb.text(pb.cell(r, 2)))
            arena.append(",\"description\":")
            writeStr(&arena, pb.text(pb.cell(r, 3)))
            let headEnd = UInt32(arena.count)

            arena.append(",\"tagList\":[")
            tagSortBuf.removeAll(keepingCapacity: true)
            forEachArrayElement(pb.text(pb.cell(r, 6))) { elem in
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
            writeTimestamp(&arena, pb.i64(r, 4))
            arena.append(",\"updatedAt\":")
            writeTimestamp(&arena, pb.i64(r, 5))
            arena.append(",\"favorited\":")
            let midEnd = UInt32(arena.count)

            arena.append(",\"favoritesCount\":")
            writeI64(&arena, pb.i64(r, 7))
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

    /// Each requested article's comment list, newest first, into the arena; nil for an article that doesn't exist.
    private func renderCommentFragments(_ s: Int, _ groups: [[Int]]) -> [[CachedCommentSlice]?] {
        let base = pa.resultRows(s).lowerBound
        var out: [[CachedCommentSlice]?] = []
        out.reserveCapacity(groups.count)
        for indices in groups {
            if indices.isEmpty {
                out.append(nil)
                continue
            }
            var rows = indices.map { pa.rows[base + $0] }.filter { !pa.cell($0, 2).isNull && !pa.cell($0, 7).isNull }
            rows.sort { a, b in
                let (ca, cb) = (pa.i64(a, 4), pa.i64(b, 4))
                return ca != cb ? ca > cb : pa.i64(a, 2) > pa.i64(b, 2)
            }
            var list: [CachedCommentSlice] = []
            list.reserveCapacity(rows.count)
            for r in rows {
                let start = UInt32(arena.count)
                arena.append("{\"id\":")
                writeI64(&arena, pa.i64(r, 2))
                arena.append(",\"createdAt\":")
                writeTimestamp(&arena, pa.i64(r, 4))
                arena.append(",\"updatedAt\":")
                writeTimestamp(&arena, pa.i64(r, 5))
                arena.append(",\"body\":")
                writeStr(&arena, pa.text(pa.cell(r, 3)))
                arena.append(",\"author\":{\"username\":")
                writeStr(&arena, pa.text(pa.cell(r, 7)))
                arena.append(",\"bio\":")
                writeNullableStr(&arena, pa.bytes(pa.cell(r, 8)))
                arena.append(",\"image\":")
                writeNullableStr(&arena, pa.bytes(pa.cell(r, 9)))
                arena.append(",\"following\":")
                list.append(CachedCommentSlice(authorID: pa.i64(r, 6), start: start, end: UInt32(arena.count)))
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

    private func writeArticle(_ dst: inout ByteBuffer, _ art: ArticleRef, includeBody: Bool, viewer: Int64, knownFollowing: Bool) -> Bool {
        guard Int(art.artOrd) < cachedArts.count else { return false }
        let slices = cachedArts[Int(art.artOrd)]
        guard slices.ready else { return false }
        let fav = viewer != 0 && isFavorited(viewer, art.aid)
        let foll = knownFollowing || (viewer != 0 && isFollowing(viewer, art.author))
        if includeBody {
            dst.append(arena, Int(slices.headStart)..<Int(slices.headEnd))
            dst.append(",\"body\":")
            writeStr(&dst, pa.text(pa.cell(art.row, 3)))
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
