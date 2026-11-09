// engine.rs's ReadWorker: a read lane, an actor with one Postgres connection, answering a whole batch of reads of
// every kind in two pipelined round trips. Phase A resolves what each request is about with one statement per kind
// present, over the batch's distinct keys, in two parts sent in one flush: A1 (tags, the current user, logins) has
// its own Sync, so those replies go out, and logins reach the bcrypt workers, while Postgres still runs A2's lists.
// Phase B enriches the union of the articles phase A found (tags, favorite counts, authors, and metadata for those
// an index-only list found), once each, and the viewers' favorited/following flags; anonymous profiles are answered
// while it runs. Every article's JSON is written once per batch with its two viewer-dependent booleans left open,
// and responses that come out identical are built once and shared.

extension JSON {
    static func writeUser(_ dst: inout ByteBuffer, email: Span<UInt8>, token: Span<UInt8>, username: Span<UInt8>,
                          bio: Span<UInt8>?, image: Span<UInt8>?) {
        dst.append("{\"user\":{\"email\":")
        writeString(&dst, email)
        dst.append(",\"token\":")
        writeString(&dst, token)
        dst.append(",\"username\":")
        writeString(&dst, username)
        dst.append(",\"bio\":")
        writeNullableString(&dst, bio)
        dst.append(",\"image\":")
        writeNullableString(&dst, image)
        dst.append("}}")
    }

    static func writeProfile(_ dst: inout ByteBuffer, username: Span<UInt8>, bio: Span<UInt8>?, image: Span<UInt8>?, following: Bool) {
        dst.append("{\"username\":")
        writeString(&dst, username)
        dst.append(",\"bio\":")
        writeNullableString(&dst, bio)
        dst.append(",\"image\":")
        writeNullableString(&dst, image)
        dst.append(",\"following\":")
        writeBool(&dst, following)
        dst.append(0x7D)
    }
}

extension OutgoingReply {
    static func error(_ addr: ReplyAddr, _ status: UInt16, _ message: StaticString) -> OutgoingReply {
        OutgoingReply(addr: addr, status: status, error: message)
    }

    /// Sends each reactor its share of `replies`: one call per reactor, which the caller's task makes on that
    /// reactor's loop, one after another, lending `bodies` (where the `.slice` bodies are) for each. Once the calls
    /// are back no reactor holds `bodies` or a bucket any more, so the caller writes into them again in place.
    /// `buckets` is the caller's, one per reactor, kept from one delivery to the next.
    static func deliver(_ replies: borrowing [OutgoingReply], to reactors: [Reactor], bodies: Span<UInt8>,
                        buckets: inout [[OutgoingReply]]) async {
        guard !replies.isEmpty else { return }
        if reactors.count == 1 || replies.allSatisfy({ $0.addr.worker == replies[0].addr.worker }) {
            await reactors[Int(replies[0].addr.worker)].deliver(replies, bodies: bodies)
            return
        }
        if buckets.count != reactors.count { buckets = [[OutgoingReply]](repeating: [], count: reactors.count) }
        for i in replies.indices { buckets[Int(replies[i].addr.worker)].append(replies[i]) }
        for i in buckets.indices where !buckets[i].isEmpty {
            await reactors[i].deliver(buckets[i], bodies: bodies)
            buckets[i].removeAll(keepingCapacity: true)
        }
    }

    /// `deliver` for replies with no `.slice` bodies.
    static func deliver(_ replies: borrowing [OutgoingReply], to reactors: [Reactor], buckets: inout [[OutgoingReply]]) async {
        let none: [UInt8] = []
        await deliver(replies, to: reactors, bodies: none.span, buckets: &buckets)
    }
}

actor ReadLane: LoopIsolated {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let db: DbEndpoint
    private let scheduler: Scheduler
    private let reactors: [Reactor]

    private var conn: PgConn?
    private var pa = PipelineBuf()
    private var pb = PipelineBuf()
    private var arena = ByteBuffer(capacity: 128 * 1024)
    /// The batch's response bodies, which its replies point into; lent to the reactors with each delivery.
    private var out = ByteBuffer(capacity: 256 * 1024)
    /// Replies sorted by reactor for a delivery, kept from one to the next.
    private var buckets: [[OutgoingReply]] = []
    private var tagLut: [Cell] = []
    private var kUid = KeySet<Int64>()
    private var kUemail = BytesKeySet()
    private var kProf = KeySet<ProfileKey>()
    private var kSlug = BytesKeySet()
    private var kAid = KeySet<Int64>()
    private var kCmts = BytesKeySet()
    /// The signed-in readers of each comment thread (viewer, the thread's 1-based ordinal): the statement returns which
    /// of the thread's authors each of them follows.
    private var kCmtViewers = KeySet<PairKey>()
    /// A batch's threads as phase A2 returned them: each thread's comment rows, whether its article exists, every
    /// author's row once, the follows of each reader among them, and each thread's comments rendered into the arena.
    private var cmtThreads: [[RowSpan]] = []
    private var cmtFound: [Bool] = []
    private var cmtAuthors = KeySet<Int64>()
    private var cmtAuthorRows: [RowSpan] = []
    private var cmtFollows: [Pair] = []
    private var cmtSlices: [CachedCommentSlice] = []
    /// A thread's comments as they are sorted: created, id, the comment's row and its author's (`cmt_sort_buf`).
    private var cmtSortBuf: [(created: Int64, id: Int64, row: RowSpan, author: RowSpan)] = []
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
    /// The (viewer, article) and (viewer, author) pairs phase B asks about, packed as `packPair` packs them.
    private var favPairs: [UInt64] = []
    private var follPairs: [UInt64] = []
    private var favViewers: [Int64] = []
    private var favTargets: [Int64] = []
    private var favStarts: [Int32] = []
    private var favEnds: [Int32] = []
    private var follViewers: [Int64] = []
    private var follTargets: [Int64] = []
    private var follStarts: [Int32] = []
    private var follEnds: [Int32] = []
    /// Phase B's favorites and follows as packed (viewer, target) pairs, sorted, behind bit filters: 512 bits over the
    /// viewers with any of them and 2,048 over each kind's pairs, so most lookups end at one bit.
    private var favHits: [UInt64] = []
    private var follHits: [UInt64] = []
    private var flaggedViewers = InlineArray<8, UInt64>(repeating: 0)
    private var favPairBits = InlineArray<32, UInt64>(repeating: 0)
    private var follPairBits = InlineArray<32, UInt64>(repeating: 0)
    private var cachedArts: [CachedArticleSlices] = []
    private var feedDepths: [Int64] = []
    private var tagSortBuf: [Cell] = []
    /// Keys sorted for binding, kept from one batch to the next.
    private var sortedKeys: [Int64] = []

    init(loop: EventLoop, db: DbEndpoint, scheduler: Scheduler, reactors: [Reactor]) {
        self.loop = loop
        self.db = db
        self.scheduler = scheduler
        self.reactors = reactors
    }

    private func ensureConn() throws(PgError) {
        if conn == nil {
            var c = try PgConn.connect(db)
            try c.prepareBatch(Catalog.reads())
            conn = consume c
        }
    }

    func run() async {
        var finished: Scheduler.ReadBatchDone?
        while true {
            let batch = await scheduler.nextReads(for: self, finished: finished)
            let tasks = batch.tasks
            let t0 = Sys.monotonicNanos()
            out.removeAll()
            var replies: [OutgoingReply] = []
            replies.reserveCapacity(tasks.count)
            do {
                try await executeBatch(tasks, &replies)
            } catch {
                Sys.logLine("read batch error: \(error)")
                conn = nil
                replies = errorAddrs.map { OutgoingReply.error($0, 500, "internal server error") }
            }
            finished = Scheduler.ReadBatchDone(queue: batch.queue, count: tasks.count, elapsedUs: Int((Sys.monotonicNanos() - t0) / 1000))
            await send(replies)
        }
    }

    /// `replies` to their reactors, the batch's bodies lent along.
    private func send(_ replies: borrowing [OutgoingReply]) async {
        var b: [[OutgoingReply]] = []
        swap(&b, &buckets)
        await OutgoingReply.deliver(replies, to: reactors, bodies: out.span, buckets: &b)
        swap(&b, &buckets)
    }

    /// `keys` in ascending order, in `sortedKeys` (valid until the next call; binding copies it into the send buffer).
    private func sortedCopy(_ keys: [Int64]) -> [Int64] {
        sortedKeys.removeAll(keepingCapacity: true)
        sortedKeys.append(contentsOf: keys)
        sortedKeys.sortUnstable()
        return sortedKeys
    }

    /// Where the next body written into `out` starts.
    private var mark: Int32 { Int32(out.count) }

    /// The reply for the body written into `out` since `start`.
    private func reply(_ addr: ReplyAddr, _ start: Int32) -> OutgoingReply {
        OutgoingReply(addr: addr, status: 200, slice: start..<mark)
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

    /// Each key's row of statement `res`, matched by its first column, the key's 1-based ordinal (`WITH ORDINALITY`).
    private func rowsByOrdinal(_ res: Int?, _ keys: Int) -> [RowSpan?] {
        var out = [RowSpan?](repeating: nil, count: keys)
        guard let res else { return out }
        for ri in pa.resultRows(res) {
            let r = pa.rows[ri]
            let ord = pa.i64(r, 0)
            if ord >= 1 && ord <= Int64(keys) { out[Int(ord) - 1] = r }
        }
        return out
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
            if rp.count > 1 { rp.sortUnstable { $0.0 > $1.0 } }
            pages[p].reserveCapacity(rp.count)
            for (aid, author, span) in rp { pages[p].append(internArt(aid, author, span, hasMeta ? .phaseA(span) : .none)) }
        }
        return (counts, pages)
    }

    private func executeBatch(_ tasks: [ReadTask], _ replies: inout [OutgoingReply]) async throws(PgError) {
        errorAddrs = tasks.map(\.addr)
        var needTagsEndpoint = false
        kUid.clear()
        kUemail.clear()
        kProf.clear()
        kSlug.clear()
        kAid.clear()
        kCmts.clear()
        kCmtViewers.clear()
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
            case .profile(let username): slot = .profile(kProf.intern(ProfileKey(viewer: t.viewer, username: username)))
            case .articleBySlug(let slug): slot = .bySlug(kSlug.intern(slug))
            case .articleById(let id, let knownFav): slot = .byId(kAid.intern(id), knownFav: knownFav)
            case .comments(let slug):
                let k = kCmts.intern(slug)
                if t.viewer != 0 { _ = kCmtViewers.intern(PairKey(a: t.viewer, b: Int64(k) + 1)) }
                slot = .comments(k)
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
        let nA1 = [stTags, stUid, stUemail, stProf].count { $0 != nil }
        let nA2 = nA - nA1

        if nA1 > 0 {
            if stTags != nil { conn!.tx.bindAndExec("tags", []) }
            if stUid != nil { conn!.tx.bindAndExec("uid", [.i64Array(kUid.items)]) }
            if stUemail != nil { conn!.tx.bindAndExec("uemail", [.keyArray(kUemail.items)]) }
            // A profile carries its viewer's `following` (one EXISTS per profile asked for), so it needs no phase B.
            if stProf != nil {
                conn!.tx.bindAndExec("prof", [.i64Array(kProf.items.map(\.viewer)), .keyArray(kProf.items.map(\.username))])
            }
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
            if stSlug != nil { conn!.tx.bindAndExec("aslug", [.keyArray(kSlug.items)]) }
            if stAid != nil { conn!.tx.bindAndExec("aid", [.i64Array(kAid.items)]) }
            if stCmts != nil {
                conn!.tx.bindAndExec("cmts", [.keyArray(kCmts.items), .i64Array(kCmtViewers.items.map(\.a)),
                                              .i64Array(kCmtViewers.items.map(\.b))])
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
                conn!.tx.bindAndExec(Self.filterStatementNames[i], [
                    .keyArray(kFilterCounts[i].items),
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
                // In place, as the Rust sorts the slice: the rows go aside while the comparison reads cells and bytes.
                var rows: [RowSpan] = []
                swap(&rows, &pa.rows)
                rows.withUnsafeMutableBufferPointer {
                    [RowSpan].sortUnstable(UnsafeMutableBufferPointer(rebasing: $0[range])) {
                        Self.lexLess(pa.text(pa.cell($0, 1)), pa.text(pa.cell($1, 1)))
                    }
                }
                swap(&rows, &pa.rows)
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
            await answerPhaseA1(tasks, stTags: stTags, stUid: stUid, stUemail: stUemail, stProf: stProf)
            errorAddrs = zip(tasks, plan).filter { !$0.1.answeredByPhaseA1 }.map(\.0.addr)
            if nA2 == 0 { return }
        }
        if nA2 > 0 {
            try conn!.readPipeline(appendingTo: &pa, expected: nA2)
            if let failed = pa.results[nA1...].first(where: { $0.error != nil }) { throw .wire("phase A2 error: \(failed.error!)") }
            if let s = stCmts { await answerComments(tasks, s) }
        }

        distinctArts.clear()
        distinctAuthors.clear()
        artAuthorOrds.removeAll(keepingCapacity: true)
        artMeta.removeAll(keepingCapacity: true)


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
                    favPairs.append(Self.packPair(v, art.aid))
                    follPairs.append(Self.packPair(v, art.author))
                }
            case .byId(let k, let knownFav):
                if let art = idRows[Int(k)] {
                    if knownFav == nil { favPairs.append(Self.packPair(v, art.aid)) }
                    follPairs.append(Self.packPair(v, art.author))
                }
            case .global(let p):
                for art in globalPages[Int(p)] {
                    favPairs.append(Self.packPair(v, art.aid))
                    follPairs.append(Self.packPair(v, art.author))
                }
            case .filtered(let kind, _, let p):
                let rows = filterResults[kind].1[Int(p)]
                if kind == 1 {
                    if let first = rows.first { follPairs.append(Self.packPair(v, first.author)) }
                    for art in rows { favPairs.append(Self.packPair(v, art.aid)) }
                } else {
                    for art in rows {
                        favPairs.append(Self.packPair(v, art.aid))
                        follPairs.append(Self.packPair(v, art.author))
                    }
                }
            case .feed(_, let p):
                for art in feedPages[Int(p)] { favPairs.append(Self.packPair(v, art.aid)) }
            case .tags, .user, .login, .profile, .comments:
                break
            }
        }
        Self.buildFlagRuns(&favPairs, &favViewers, &favTargets, &favStarts, &favEnds)
        Self.buildFlagRuns(&follPairs, &follViewers, &follTargets, &follStarts, &follEnds)

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
            // Keys bound in ascending order, so each statement walks its indexes forward; rows are matched back by id.
            if bArtmeta != nil { conn!.tx.bindAndExec("artmeta", [.i64Array(sortedCopy(metaRequestIDs))]) }
            if bArtx != nil { conn!.tx.bindAndExec("artx", [.i64Array(sortedCopy(distinctArts.items))]) }
            if bArtau != nil { conn!.tx.bindAndExec("artau", [.i64Array(sortedCopy(distinctAuthors.items))]) }
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
        flaggedViewers = InlineArray(repeating: 0)
        favPairBits = InlineArray(repeating: 0)
        follPairBits = InlineArray(repeating: 0)

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
                    let packed = Self.packPair(viewer, target)
                    let (w, bit) = Self.viewerBitPosition(viewer)
                    flaggedViewers[w] |= bit
                    let (pw, pbit) = Self.pairBitPosition(packed)
                    if kind == 0 {
                        favPairBits[pw] |= pbit
                        favHits.append(packed)
                    } else {
                        follPairBits[pw] |= pbit
                        follHits.append(packed)
                    }
                }
                favHits.sortUnstable()
                follHits.sortUnstable()
            }
        }

        var renderedSlugs = [Range<Int32>?](repeating: nil, count: kSlug.count)
        var renderedGlobal = [Range<Int32>?](repeating: nil, count: globalPages.count)
        var renderedFilters = filterResults.map { [Range<Int32>?](repeating: nil, count: $0.1.count) }

        for (task, slot) in zip(tasks, plan) {
            let viewer = task.viewer
            let addr = task.addr
            switch slot {
            case .tags, .user, .login, .profile, .comments:
                break
            case .bySlug(let k):
                guard let art = slugRows[Int(k)] else {
                    replies.append(OutgoingReply.error(addr, 404, "article not found"))
                    continue
                }
                let unflagged = isArticleUnflagged(art, viewer)
                if unflagged, let shared = renderedSlugs[Int(k)] {
                    replies.append(OutgoingReply(addr: addr, status: 200, slice: shared))
                    continue
                }
                let start = mark
                out.append("{\"article\":")
                if writeArticle(&out, art, includeBody: true, viewer: viewer, knownFollowing: false, knownFav: nil) {
                    out.append(0x7D)
                    if unflagged { renderedSlugs[Int(k)] = start..<mark }
                    replies.append(reply(addr, start))
                } else {
                    out.truncate(Int(start))
                    replies.append(OutgoingReply.error(addr, 404, "article not found"))
                }
            case .byId(let k, let knownFav):
                guard let art = idRows[Int(k)] else {
                    replies.append(OutgoingReply.error(addr, 404, "article not found"))
                    continue
                }
                let start = mark
                out.append("{\"article\":")
                if writeArticle(&out, art, includeBody: true, viewer: viewer, knownFollowing: false, knownFav: knownFav) {
                    out.append(0x7D)
                    replies.append(reply(addr, start))
                } else {
                    out.truncate(Int(start))
                    replies.append(OutgoingReply.error(addr, 404, "article not found"))
                }
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
                    var cached: Range<Int32>?
                    if case .global(let p) = slot { cached = renderedGlobal[Int(p)] }
                    if case .filtered(let kind, _, let p) = slot { cached = renderedFilters[kind][Int(p)] }
                    if let cached {
                        replies.append(OutgoingReply(addr: addr, status: 200, slice: cached))
                        continue
                    }
                }
                let start = mark
                out.append("{\"articles\":[")
                var first = true
                for art in rows {
                    let articleStart = out.count
                    if !first { out.append(0x2C) }
                    if writeArticle(&out, art, includeBody: false, viewer: unflagged ? 0 : viewer, knownFollowing: isFeed,
                                    knownFav: nil) {
                        first = false
                    } else {
                        out.truncate(articleStart)
                    }
                }
                out.append("],\"articlesCount\":")
                JSON.writeInt(&out, total)
                out.append(0x7D)
                if unflagged {
                    if case .global(let p) = slot { renderedGlobal[Int(p)] = start..<mark }
                    if case .filtered(let kind, _, let p) = slot { renderedFilters[kind][Int(p)] = start..<mark }
                }
                replies.append(reply(addr, start))
            }
        }
    }

    /// Phase A1's replies, sent at once: tags, the current user, and logins whose email has no user; the others go to
    /// the bcrypt workers.
    private func answerPhaseA1(_ tasks: [ReadTask], stTags: Int?, stUid: Int?, stUemail: Int?, stProf: Int?) async {
        let uidRows = mapRows(stUid, kUid, column: 0)
        let uemailRows = mapRows(stUemail, kUemail, column: 2)
        let profRows = rowsByOrdinal(stProf, kProf.count)
        var renderedProfiles = [Range<Int32>?](repeating: nil, count: kProf.count)
        var early: [OutgoingReply] = []
        var logins: [CryptoTask] = []
        var renderedTags: Range<Int32>?
        for (task, slot) in zip(tasks, plan) {
            switch slot {
            case .tags:
                if renderedTags == nil, let s = stTags {
                    let start = mark
                    out.append("{\"tags\":[")
                    for (i, ri) in pa.resultRows(s).enumerated() {
                        if i > 0 { out.append(0x2C) }
                        JSON.writeString(&out, pa.text(pa.cell(pa.rows[ri], 1)))
                    }
                    out.append("]}")
                    renderedTags = start..<mark
                }
                early.append(OutgoingReply(addr: task.addr, status: 200, slice: renderedTags ?? mark..<mark))
            case .user(let k):
                guard case .currentUser(_, let token) = task.op else { continue }
                if let r = uidRows[Int(k)] {
                    let start = mark
                    JSON.writeUser(&out, email: pa.text(pa.cell(r, 2)), token: token.span, username: pa.text(pa.cell(r, 1)),
                                   bio: pa.bytes(pa.cell(r, 3)), image: pa.bytes(pa.cell(r, 4)))
                    early.append(reply(task.addr, start))
                } else {
                    early.append(OutgoingReply.error(task.addr, 401, "unauthorized"))
                }
            case .profile(let k):
                // (username, bio, image, following) after the ordinal; no row: no such user.
                guard let r = profRows[Int(k)] else {
                    early.append(OutgoingReply.error(task.addr, 404, "profile not found"))
                    continue
                }
                if renderedProfiles[Int(k)] == nil {
                    let start = mark
                    out.append("{\"profile\":")
                    JSON.writeProfile(&out, username: pa.text(pa.cell(r, 1)), bio: pa.bytes(pa.cell(r, 2)),
                                      image: pa.bytes(pa.cell(r, 3)), following: pa.bool(pa.cell(r, 4)))
                    out.append(0x7D)
                    renderedProfiles[Int(k)] = start..<mark
                }
                early.append(OutgoingReply(addr: task.addr, status: 200, slice: renderedProfiles[Int(k)]!))
            case .login(let k):
                guard case .login(_, let password) = task.op else { continue }
                if let r = uemailRows[Int(k)] {
                    let user = UserRecord(id: pa.i64(r, 0), username: pa.copy(pa.cell(r, 1)) ?? [],
                                          email: pa.copy(pa.cell(r, 2)) ?? [], bio: pa.copy(pa.cell(r, 3)),
                                          image: pa.copy(pa.cell(r, 4)))
                    logins.append(.verifyLogin(password: password, hash: pa.copy(pa.cell(r, 5)) ?? [], user: user, addr: task.addr))
                } else {
                    early.append(OutgoingReply.error(task.addr, 401, "invalid email or password"))
                }
            default:
                break
            }
        }
        if !logins.isEmpty { scheduler.submit(Submission(crypto: logins)) }
        await send(early)
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
            case .phaseA(let m): (createdAt, updatedAt) = Self.writeArticleHead(&arena, pa, m, firstColumn: 3)
            case .phaseB(let m): (createdAt, updatedAt) = Self.writeArticleHead(&arena, pb, m, firstColumn: 1)
            case .none: continue
            }
            let headEnd = UInt32(arena.count)

            arena.append(",\"tagList\":[")
            tagSortBuf.removeAll(keepingCapacity: true)
            PgConn.forEachArrayElement(pb.text(pb.cell(r, 1))) { elem in
                guard elem.count == 4 else { return }
                let tid = Int(elem.bytes.load(fromByteOffset: 0, as: Int32.self, .bigEndian))
                if tid >= 0 && tid < tagLut.count && !tagLut[tid].isNull { tagSortBuf.append(tagLut[tid]) }
            }
            if tagSortBuf.count > 1 { tagSortBuf.sortUnstable { Self.lexLess(pa.text($0), pa.text($1)) } }
            for (i, name) in tagSortBuf.enumerated() {
                if i > 0 { arena.append(0x2C) }
                JSON.writeString(&arena, pa.text(name))
            }
            arena.append("],\"createdAt\":")
            JSON.writeTimestamp(&arena, createdAt)
            arena.append(",\"updatedAt\":")
            JSON.writeTimestamp(&arena, updatedAt)
            arena.append(",\"favorited\":")
            let midEnd = UInt32(arena.count)

            arena.append(",\"favoritesCount\":")
            JSON.writeInt(&arena, pb.i64(r, 2))
            arena.append(",\"author\":{\"username\":")
            JSON.writeString(&arena, pb.text(pb.cell(au, 1)))
            arena.append(",\"bio\":")
            JSON.writeNullableString(&arena, pb.bytes(pb.cell(au, 2)))
            arena.append(",\"image\":")
            JSON.writeNullableString(&arena, pb.bytes(pb.cell(au, 3)))
            arena.append(",\"following\":")
            let tailEnd = UInt32(arena.count)

            cachedArts[k] = CachedArticleSlices(ready: true, headStart: headStart, headEnd: headEnd, midEnd: midEnd, tailEnd: tailEnd)
        }
    }

    /// Each requested article's comment list, newest first, into the arena (authors from phase B's `artau`); nil for
    /// an article that doesn't exist.
    /// Comment threads come whole from phase A2's `cmts` (rows of kind 0: a thread's comments; 1: their authors, once
    /// each; 2: a reader and an author of that reader's thread they follow), so they are answered before phase B.
    private func answerComments(_ tasks: [ReadTask], _ s: Int) async {
        let n = kCmts.count
        if cmtThreads.count < n { cmtThreads.append(contentsOf: repeatElement([], count: n - cmtThreads.count)) }
        for i in 0..<n { cmtThreads[i].removeAll(keepingCapacity: true) }
        cmtFound.removeAll(keepingCapacity: true)
        cmtFound.append(contentsOf: repeatElement(false, count: n))
        cmtAuthors.clear()
        cmtAuthorRows.removeAll(keepingCapacity: true)
        cmtFollows.removeAll(keepingCapacity: true)
        cmtSlices.removeAll(keepingCapacity: true)
        for ri in pa.resultRows(s) {
            let r = pa.rows[ri]
            switch pa.i64(r, 0) {
            case 0:
                // (0, ordinal, comment id, author id, created, updated, body): an article with no comments is one row
                // whose comment columns are null; an unknown slug has no row.
                let k = Int(pa.i64(r, 1)) - 1
                guard k >= 0 && k < n else { continue }
                cmtFound[k] = true
                if !pa.cell(r, 2).isNull { cmtThreads[k].append(r) }
            case 1:
                // (1, user id, 0, 0, null, null, username, bio, image)
                if Int(cmtAuthors.intern(pa.i64(r, 1))) == cmtAuthorRows.count { cmtAuthorRows.append(r) }
            default:
                // (2, reader, followed author)
                cmtFollows.append(Pair(v: pa.i64(r, 1), t: pa.i64(r, 2)))
            }
        }
        cmtFollows.sortUnstable()
        var threadSlices = [Range<Int>?](repeating: nil, count: n)
        var rendered = [Range<Int32>?](repeating: nil, count: n)
        var replies: [OutgoingReply] = []
        for (task, slot) in zip(tasks, plan) {
            guard case .comments(let k32) = slot else { continue }
            let k = Int(k32)
            guard cmtFound[k] else {
                replies.append(OutgoingReply.error(task.addr, 404, "article not found"))
                continue
            }
            if threadSlices[k] == nil { threadSlices[k] = renderThread(k) }
            let slices = threadSlices[k]!
            let viewer = task.viewer
            let unflagged = viewer == 0 || !cmtSlices[slices].contains { cmtFollows.containsSorted(Pair(v: viewer, t: $0.authorID)) }
            if unflagged, let shared = rendered[k] {
                replies.append(OutgoingReply(addr: task.addr, status: 200, slice: shared))
                continue
            }
            let start = mark
            out.append("{\"comments\":[")
            for i in slices {
                let c = cmtSlices[i]
                if i > slices.lowerBound { out.append(0x2C) }
                out.append(arena, Int(c.start)..<Int(c.end))
                out.append(!unflagged && cmtFollows.containsSorted(Pair(v: viewer, t: c.authorID)) ? "true}}" : "false}}")
            }
            out.append("]}")
            if unflagged { rendered[k] = start..<mark }
            replies.append(reply(task.addr, start))
        }
        guard !replies.isEmpty else { return }
        await send(replies)
        errorAddrs = zip(tasks, plan).filter { task, slot in
            if slot.answeredByPhaseA1 { return false }
            if case .comments = slot { return false }
            return true
        }.map(\.0.addr)
    }

    /// Thread `k`'s comments, newest first, each written once into the arena up to its author's `following`; their
    /// slices are appended to `cmtSlices`, and the range they take there returned.
    private func renderThread(_ k: Int) -> Range<Int> {
        // The sort keys read out first, as the Rust does, so the sort compares integers.
        cmtSortBuf.removeAll(keepingCapacity: true)
        for r in cmtThreads[k] {
            guard let au = cmtAuthors.ordinal(of: pa.i64(r, 3)) else { continue }
            cmtSortBuf.append((pa.i64(r, 4), pa.i64(r, 2), r, cmtAuthorRows[Int(au)]))
        }
        cmtSortBuf.sortUnstable { a, b in a.created != b.created ? a.created > b.created : a.id > b.id }
        let first = cmtSlices.count
        for (created, id, r, author) in cmtSortBuf {
            let authorID = pa.i64(r, 3)
            let start = UInt32(arena.count)
            arena.append("{\"id\":")
            JSON.writeInt(&arena, id)
            arena.append(",\"createdAt\":")
            JSON.writeTimestamp(&arena, created)
            arena.append(",\"updatedAt\":")
            JSON.writeTimestamp(&arena, pa.i64(r, 5))
            arena.append(",\"body\":")
            JSON.writeString(&arena, pa.text(pa.cell(r, 6)))
            arena.append(",\"author\":{\"username\":")
            JSON.writeString(&arena, pa.text(pa.cell(author, 6)))
            arena.append(",\"bio\":")
            JSON.writeNullableString(&arena, pa.bytes(pa.cell(author, 7)))
            arena.append(",\"image\":")
            JSON.writeNullableString(&arena, pa.bytes(pa.cell(author, 8)))
            arena.append(",\"following\":")
            cmtSlices.append(CachedCommentSlice(authorID: authorID, start: start, end: UInt32(arena.count)))
        }
        return first..<cmtSlices.count
    }

    // ---------- flags and rendering (RenderCtx) ----------

    @inline(__always) private func viewerHasAnyFlag(_ viewer: Int64) -> Bool {
        guard viewer != 0 else { return false }
        let (w, bit) = Self.viewerBitPosition(viewer)
        return flaggedViewers[w] & bit != 0
    }

    @inline(__always) private func isFollowing(_ viewer: Int64, _ author: Int64) -> Bool {
        let packed = Self.packPair(viewer, author)
        let (w, bit) = Self.pairBitPosition(packed)
        return follPairBits[w] & bit != 0 && follHits.containsSorted(packed)
    }

    @inline(__always) private func isFavorited(_ viewer: Int64, _ article: Int64) -> Bool {
        let packed = Self.packPair(viewer, article)
        let (w, bit) = Self.pairBitPosition(packed)
        return favPairBits[w] & bit != 0 && favHits.containsSorted(packed)
    }

    @inline(__always) private func isArticleUnflagged(_ art: ArticleRef, _ viewer: Int64) -> Bool {
        !viewerHasAnyFlag(viewer) || (!isFavorited(viewer, art.aid) && !isFollowing(viewer, art.author))
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
            JSON.writeString(&dst, pa.text(pa.cell(art.row, 8)))
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

extension ReadLane {
    /// A profile as one viewer asks for it: the row carries whether that viewer follows it.
    struct ProfileKey: FastHashable {
        let viewer: Int64
        let username: SmallBytes

        func feed(_ hasher: inout FastHasher) {
            hasher.write(viewer)
            username.feed(&hasher)
        }
    }

    struct PairKey: FastHashable {
        let a: Int64
        let b: Int64

        func feed(_ hasher: inout FastHasher) {
            hasher.write(a)
            hasher.write(b)
        }
    }

    struct PageKey: FastHashable {
        let c: UInt32
        let lim: Int64
        let off: Int64

        func feed(_ hasher: inout FastHasher) {
            hasher.write(UInt64(c))
            hasher.write(lim)
            hasher.write(off)
        }
    }

    /// Distinct keys in first-seen order, each with its ordinal (`KeySet`), indexed by their `FastHasher` hash.
    struct KeySet<K: FastHashable> {
        private var index = IndexTable()
        private(set) var items: [K] = []

        var count: Int { items.count }

        mutating func clear() {
            index.clear()
            items.removeAll(keepingCapacity: true)
        }

        mutating func intern(_ key: K) -> UInt32 {
            let h = key.fastHash
            if let i = index.find(h, { items[Int($0)] == key }) { return i }
            let i = UInt32(items.count)
            index.insert(h, i)
            items.append(key)
            return i
        }

        @inline(__always) func ordinal(of key: K) -> UInt32? { index.find(key.fastHash) { items[Int($0)] == key } }
    }

    @inline(__always) private static func sameBytes(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
        guard a.count == b.count else { return false }
        return a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in Bytes.compare(pa.baseAddress, pb.baseAddress, a.count) == 0 } }
    }

    /// `KeySet<String>`, whose items go to Postgres as a text[]. It is also looked up by a row's column, a borrowed
    /// `Span`, without copying it: a `SmallBytes` and the same bytes in a `Span` hash alike.
    struct BytesKeySet {
        private var index = IndexTable()
        private(set) var items: [SmallBytes] = []

        var count: Int { items.count }

        mutating func clear() {
            index.clear()
            items.removeAll(keepingCapacity: true)
        }

        @inline(__always) private static func hash(_ key: Span<UInt8>) -> UInt64 {
            var h = FastHasher()
            h.write(bytes: key)
            return h.finish()
        }

        func ordinal(of key: Span<UInt8>) -> UInt32? {
            index.find(Self.hash(key)) { items[Int($0)].withSpan { sameBytes($0, key) } }
        }

        mutating func intern(_ key: SmallBytes) -> UInt32 {
            let h = key.fastHash
            if let i = index.find(h, { items[Int($0)] == key }) { return i }
            let i = UInt32(items.count)
            index.insert(h, i)
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

        /// Answered from phase A1 alone (tags, the current user, profiles, logins handed to the bcrypt workers).
        var answeredByPhaseA1: Bool {
            switch self {
            case .tags, .user, .login, .profile: true
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
        let aid: Int64
        let author: Int64
        let artOrd: UInt32
        let row: RowSpan
    }

    private struct CachedArticleSlices {
        var ready = false
        var headStart: UInt32 = 0
        var headEnd: UInt32 = 0
        var midEnd: UInt32 = 0
        var tailEnd: UInt32 = 0
    }

    private struct CachedCommentSlice {
        let authorID: Int64
        let start: UInt32
        let end: UInt32
    }

    struct Pair: Comparable {
        let v: Int64
        let t: Int64
        static func < (a: Pair, b: Pair) -> Bool { a.v != b.v ? a.v < b.v : a.t < b.t }
    }

    /// A viewer and a target in one word (`pack_pair`): the viewer's id in the high half, the target's in the low.
    @inline(__always) private static func packPair(_ viewer: Int64, _ target: Int64) -> UInt64 {
        UInt64(bitPattern: viewer) << 32 | UInt64(UInt32(truncatingIfNeeded: target))
    }

    /// Which word and bit of the 512-bit viewer filter `viewer` sets.
    @inline(__always) private static func viewerBitPosition(_ viewer: Int64) -> (Int, UInt64) {
        let h = (UInt64(bitPattern: viewer) &* 0x9E37_79B9_7F4A_7C15) >> 55
        return (Int(h >> 6), 1 << (h & 63))
    }

    /// Which word and bit of a 2,048-bit pair filter `packed` sets.
    @inline(__always) private static func pairBitPosition(_ packed: UInt64) -> (Int, UInt64) {
        let h = (packed &* 0x9E37_79B9_7F4A_7C15) >> 53
        return (Int(h >> 6), 1 << (h & 63))
    }

    @inline(__always) private static func lexLess(_ a: Span<UInt8>, _ b: Span<UInt8>) -> Bool {
        let n = min(a.count, b.count)
        let c = a.withUnsafeBytes { pa in b.withUnsafeBytes { pb in Bytes.compare(pa.baseAddress, pb.baseAddress, n) } }
        return c != 0 ? c < 0 : a.count < b.count
    }

    /// The packed pairs sorted and deduplicated as integers, then as runs: each viewer once, its targets in a row.
    private static func buildFlagRuns(_ pairs: inout [UInt64], _ viewers: inout [Int64], _ targets: inout [Int64],
                                      _ starts: inout [Int32], _ ends: inout [Int32]) {
        pairs.sortAndDedup()
        viewers.removeAll(keepingCapacity: true)
        targets.removeAll(keepingCapacity: true)
        starts.removeAll(keepingCapacity: true)
        ends.removeAll(keepingCapacity: true)
        guard let first = pairs.first else { return }
        var current = Int64(Int32(truncatingIfNeeded: first >> 32))
        var runStart: Int32 = 1
        for (i, p) in pairs.enumerated() {
            let v = Int64(Int32(truncatingIfNeeded: p >> 32))
            if v != current {
                viewers.append(current)
                starts.append(runStart)
                ends.append(Int32(i))
                current = v
                runStart = Int32(i) + 1
            }
            targets.append(Int64(Int32(truncatingIfNeeded: p)))
        }
        viewers.append(current)
        starts.append(runStart)
        ends.append(Int32(pairs.count))
    }

    private static let filterStatementNames = ["tag", "author", "favlist"]

    /// An article's `{"slug":…,"title":…,"description":…` from a row whose metadata (slug, title, description,
    /// created_at, updated_at) starts at column `first`; returns the two timestamps.
    private static func writeArticleHead(_ dst: inout ByteBuffer, _ p: borrowing PipelineBuf, _ r: RowSpan,
                                         firstColumn first: Int) -> (Int64, Int64) {
        dst.append("{\"slug\":")
        JSON.writeString(&dst, p.text(p.cell(r, first)))
        dst.append(",\"title\":")
        JSON.writeString(&dst, p.text(p.cell(r, first + 1)))
        dst.append(",\"description\":")
        JSON.writeString(&dst, p.text(p.cell(r, first + 2)))
        return (p.i64(r, first + 3), p.i64(r, first + 4))
    }
}

extension Array where Element: Comparable {
    fileprivate func containsSorted(_ x: Element) -> Bool {
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid] < x { lo = mid + 1 } else { hi = mid }
        }
        return lo < count && self[lo] == x
    }
}

extension Array where Element == UInt64 {
    fileprivate mutating func sortAndDedup() {
        sortUnstable()
        var w = 0
        for i in indices where w == 0 || self[i] != self[w - 1] {
            self[w] = self[i]
            w += 1
        }
        removeLast(count - w)
    }
}
