// engine.rs's WriteWorker: the write lane. Every write waiting is pipelined before one Sync, which makes them one
// implicit transaction committed at the Sync (group commit); responses go out only after Postgres reports it done.
// Favorites, follows and new comments of a group run as one `unnest` statement per kind, unless the group also
// changes what they would read (the same article, or a profile). If any statement fails, each write is retried on
// its own. A new article is answered from its insert; other writes that answer with an article read it back through
// the read lanes, with the favorited flag they just set.
import Glibc

private enum WriteLoc {
    case direct(start: Int, count: Int)
    case batchedFav(on: Bool, ord: Int)
    case batchedFollow(on: Bool, ord: Int)
    case batchedComment(ord: Int)
}

private struct WriteFailure: Error {
    var error: PgError
    var addrs: [ReplyAddr]
}

private func stmtCount(_ task: WriteTask) -> Int {
    if case .createArticle(_, _, _, let tags) = task.op, !tags.isEmpty { return 3 }
    return 1
}

/// The slug's prefix: ASCII letters and digits, lowercased, runs of anything else as one dash.
func slugifyASCII(_ title: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    out.reserveCapacity(title.count)
    var pendingDash = false
    for b in title {
        switch b {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39:
            if pendingDash && !out.isEmpty { out.append(0x2D) }
            pendingDash = false
            out.append((0x41...0x5A).contains(b) ? b + 32 : b)
        default:
            pendingDash = true
        }
    }
    return out
}

@inline(__always) private func optText(_ v: [UInt8]?) -> BindParam {
    v.map(BindParam.text) ?? .null
}

private func bindSingleWrite(_ tx: inout TxBuf, _ task: WriteTask) {
    let v = task.viewer
    switch task.op {
    case .register(let username, let email, let hash):
        tx.bindAndExec("register", [.text(username), .text(email), .text(hash)])
    case .updateUser(_, let email, let username, let hash, let bio, let image):
        tx.bindAndExec("upduser", [.i64(v), optText(email), optText(username), optText(hash), optText(bio), optText(image)])
    case .follow(let username, let on):
        tx.bindAndExec(on ? "follow" : "unfollow", [.i64(v), .text(username)])
    case .favorite(let slug, let on):
        tx.bindAndExec(on ? "fav" : "unfav", [.i64(v), .text(slug)])
    case .createArticle(let title, let description, let body, let tags):
        tx.bindAndExec("newart", [.i64(v), .text(title), .text(description), .text(body), .text(slugifyASCII(title))])
        if !tags.isEmpty {
            tx.bindAndExec("newtags", [.textArray(tags)])
            tx.bindAndExec("arttags", [.textArray(tags)])
        }
    case .updateArticle(let slug, let title, let description, let body):
        tx.bindAndExec("updart", [.text(slug), optText(title), optText(description), optText(body), .i64(v),
                                  optText(title.map(slugifyASCII))])
    case .deleteArticle(let slug):
        tx.bindAndExec("delart", [.text(slug), .i64(v)])
    case .createComment(let slug, let body):
        tx.bindAndExec("newcmt", [.text(slug), .i64(v), .text(body)])
    case .deleteComment(let slug, let id):
        tx.bindAndExec("delcmt", [.i64(id), .text(slug), .i64(v)])
    }
}

private func writeCommentJSON(_ body: inout ByteBuffer, _ p: borrowing PipelineBuf, _ r: RowSpan,
                              id: Int, text: Int, created: Int, updated: Int, author: Int) {
    body.append("{\"comment\":{\"id\":")
    writeI64(&body, p.i64(r, id))
    body.append(",\"createdAt\":")
    writeTimestamp(&body, p.i64(r, created))
    body.append(",\"updatedAt\":")
    writeTimestamp(&body, p.i64(r, updated))
    body.append(",\"body\":")
    writeStr(&body, p.text(p.cell(r, text)))
    body.append(",\"author\":")
    writeProfileJSON(&body, username: p.text(p.cell(r, author)), bio: p.bytes(p.cell(r, author + 1)),
                     image: p.bytes(p.cell(r, author + 2)), following: false)
    body.append("}}")
}

/// A new article's `{"article":{…}}` (`write_full_article_envelope`), from `newart`'s row (slug, created_at,
/// updated_at, the author's username, bio, image, and whether the writer follows them) and the request's fields.
private func writeFullArticleEnvelope(_ dst: inout ByteBuffer, _ p: borrowing PipelineBuf, _ r: RowSpan, title: [UInt8],
                                      description: [UInt8], body: [UInt8], tags: [[UInt8]]) {
    dst.append("{\"article\":{\"slug\":")
    writeStr(&dst, p.text(p.cell(r, 0)))
    dst.append(",\"title\":")
    writeStr(&dst, title)
    dst.append(",\"description\":")
    writeStr(&dst, description)
    dst.append(",\"body\":")
    writeStr(&dst, body)
    dst.append(",\"tagList\":[")
    for (i, tag) in tags.enumerated() {
        if i > 0 { dst.append(0x2C) }
        writeStr(&dst, tag)
    }
    dst.append("],\"createdAt\":")
    writeTimestamp(&dst, p.i64(r, 1))
    dst.append(",\"updatedAt\":")
    writeTimestamp(&dst, p.i64(r, 2))
    dst.append(",\"favorited\":false,\"favoritesCount\":0,\"author\":")
    writeProfileJSON(&dst, username: p.text(p.cell(r, 3)), bio: p.bytes(p.cell(r, 4)), image: p.bytes(p.cell(r, 5)),
                     following: p.bool(p.cell(r, 6)))
    dst.append("}}")
}

actor WriteLane {
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let db: DbEndpoint
    private let scheduler: Scheduler
    private let reactors: [Reactor]
    private let signer: TokenSigner
    private var conn: PgConn?
    private var pipe = PipelineBuf()

    init(loop: EventLoop, db: DbEndpoint, scheduler: Scheduler, reactors: [Reactor], signer: TokenSigner) {
        self.loop = loop
        self.db = db
        self.scheduler = scheduler
        self.reactors = reactors
        self.signer = signer
    }

    private func ensureConn() throws(PgError) {
        if conn == nil {
            var c = try PgConn.connect(db)
            try c.prepareBatch(writeCatalog())
            conn = consume c
        }
    }

    func run() async {
        await withDiscardingTaskGroup { group in
            while true {
                let tasks = await scheduler.nextWrites()
                var replies: [OutgoingReply] = []
                var postReads: [ReadTask] = []
                do throws(WriteFailure) {
                    try commitGroup(tasks, &replies, &postReads)
                } catch {
                    logLine("write group error: \(error.error)")
                    conn = nil
                    replies.append(contentsOf: error.addrs.map { errorReply($0, 500, "internal server error") })
                }
                if !postReads.isEmpty {
                    let scheduler = scheduler
                    let work = Submission(reads: postReads)
                    group.addTask(executorPreference: scheduler.loop) { await scheduler.submit(work) }
                }
                deliverReplies(replies, to: reactors, &group)
            }
        }
    }

    private func commitGroup(_ tasks: [WriteTask], _ replies: inout [OutgoingReply],
                             _ postReads: inout [ReadTask]) throws(WriteFailure) {
        guard !tasks.isEmpty else { return }
        let allAddrs = tasks.map(\.addr)
        do { try ensureConn() } catch { throw WriteFailure(error: error, addrs: allAddrs) }

        let isSingle = tasks.count == 1
        // A profile changed in the group would show in the follow and comment replies, whose rows carry the author.
        let hasUserMutation = !isSingle && tasks.contains {
            if case .updateUser = $0.op { return true }
            return false
        }
        var mutatedSlugs: [[UInt8]] = []
        var favOn: [(Int64, [UInt8])] = [], favOff: [(Int64, [UInt8])] = []
        var follOn: [(Int64, [UInt8])] = [], follOff: [(Int64, [UInt8])] = []
        var comments: [(Int64, [UInt8], [UInt8])] = []
        if !isSingle {
            for t in tasks {
                switch t.op {
                case .updateArticle(let slug, _, _, _), .deleteArticle(let slug): mutatedSlugs.append(slug)
                case .favorite(let slug, true): favOn.append((t.viewer, slug))
                case .favorite(let slug, false): favOff.append((t.viewer, slug))
                case .follow(let username, true): follOn.append((t.viewer, username))
                case .follow(let username, false): follOff.append((t.viewer, username))
                case .createComment(let slug, let body): comments.append((t.viewer, slug, body))
                default: break
                }
            }
        }
        // A merged statement runs before the group's other writes, so it can't touch what they change.
        let favConflict = favOn.contains { a in favOff.contains { $0.1 == a.1 } || mutatedSlugs.contains(a.1) }
            || favOff.contains { mutatedSlugs.contains($0.1) }
        let follConflict = hasUserMutation || follOn.contains { a in follOff.contains { $0.1 == a.1 } }
        let commentConflict = hasUserMutation || comments.contains { mutatedSlugs.contains($0.1) }
        let batchFavOn = !favConflict && favOn.count >= 2
        let batchFavOff = !favConflict && favOff.count >= 2
        let batchFollOn = !follConflict && follOn.count >= 2
        let batchFollOff = !follConflict && follOff.count >= 2
        let batchComments = !commentConflict && comments.count >= 2

        var nExec = 0
        func merged(_ active: Bool, _ statement: String, _ params: @autoclosure () -> [BindParam]) -> Int? {
            guard active else { return nil }
            conn!.tx.bindAndExec(statement, params())
            defer { nExec += 1 }
            return nExec
        }
        let slotFollOn = merged(batchFollOn, "follow_batch", [.i64Array(follOn.map(\.0)), .textArray(follOn.map(\.1))])
        let slotFollOff = merged(batchFollOff, "unfollow_batch", [.i64Array(follOff.map(\.0)), .textArray(follOff.map(\.1))])
        let slotFavOn = merged(batchFavOn, "fav_batch", [.i64Array(favOn.map(\.0)), .textArray(favOn.map(\.1))])
        let slotFavOff = merged(batchFavOff, "unfav_batch", [.i64Array(favOff.map(\.0)), .textArray(favOff.map(\.1))])
        let slotComments = merged(batchComments, "newcmt_batch",
                                  [.i64Array(comments.map(\.0)), .textArray(comments.map(\.1)), .textArray(comments.map(\.2))])

        var counts = (favOn: 0, favOff: 0, follOn: 0, follOff: 0, comments: 0)
        var locs: [WriteLoc] = []
        locs.reserveCapacity(tasks.count)
        for t in tasks {
            switch t.op {
            case .favorite(_, true) where batchFavOn:
                counts.favOn += 1
                locs.append(.batchedFav(on: true, ord: counts.favOn))
            case .favorite(_, false) where batchFavOff:
                counts.favOff += 1
                locs.append(.batchedFav(on: false, ord: counts.favOff))
            case .follow(_, true) where batchFollOn:
                counts.follOn += 1
                locs.append(.batchedFollow(on: true, ord: counts.follOn))
            case .follow(_, false) where batchFollOff:
                counts.follOff += 1
                locs.append(.batchedFollow(on: false, ord: counts.follOff))
            case .createComment where batchComments:
                counts.comments += 1
                locs.append(.batchedComment(ord: counts.comments))
            default:
                let n = stmtCount(t)
                locs.append(.direct(start: nExec, count: n))
                bindSingleWrite(&conn!.tx, t)
                nExec += n
            }
        }
        conn!.tx.writeSync()
        do {
            try conn!.flush()
            try conn!.readPipeline(into: &pipe, expected: nExec)
        } catch {
            throw WriteFailure(error: error, addrs: allAddrs)
        }

        if !isSingle && pipe.results.contains(where: { $0.error != nil }) {
            for (i, t) in tasks.enumerated() {
                do {
                    try execIndividual(t, &replies, &postReads)
                } catch {
                    throw WriteFailure(error: error, addrs: tasks[i...].map(\.addr))
                }
            }
            return
        }

        func decodeOrdinals(_ slot: Int?, _ len: Int) -> [RowSpan?] {
            var out = [RowSpan?](repeating: nil, count: len)
            guard let slot else { return out }
            for ri in pipe.resultRows(slot) {
                let r = pipe.rows[ri]
                let k = pipe.i64(r, 0)
                if k >= 1 && k <= Int64(len) { out[Int(k) - 1] = r }
            }
            return out
        }
        let favOnRows = decodeOrdinals(slotFavOn, counts.favOn)
        let favOffRows = decodeOrdinals(slotFavOff, counts.favOff)
        let follOnRows = decodeOrdinals(slotFollOn, counts.follOn)
        let follOffRows = decodeOrdinals(slotFollOff, counts.follOff)
        let commentRows = decodeOrdinals(slotComments, counts.comments)

        for (task, loc) in zip(tasks, locs) {
            switch loc {
            case .direct(let start, let count):
                finalize(task, start, count, &replies, &postReads)
            case .batchedFav(let on, let ord):
                if let r = (on ? favOnRows : favOffRows)[ord - 1] {
                    postReads.append(ReadTask(op: .articleById(id: pipe.i64(r, 1), knownFav: on), viewer: task.viewer, addr: task.addr))
                } else {
                    replies.append(errorReply(task.addr, 404, "article not found"))
                }
            case .batchedFollow(let on, let ord):
                if let r = (on ? follOnRows : follOffRows)[ord - 1] {
                    var body = ByteBuffer(capacity: 256)
                    body.append("{\"profile\":")
                    writeProfileJSON(&body, username: pipe.text(pipe.cell(r, 1)), bio: pipe.bytes(pipe.cell(r, 2)),
                                     image: pipe.bytes(pipe.cell(r, 3)), following: on)
                    body.append(0x7D)
                    replies.append(OutgoingReply(addr: task.addr, status: 200, body: body.take()))
                } else {
                    replies.append(errorReply(task.addr, 404, "profile not found"))
                }
            case .batchedComment(let ord):
                if let r = commentRows[ord - 1] {
                    var body = ByteBuffer(capacity: 512)
                    writeCommentJSON(&body, pipe, r, id: 1, text: 2, created: 3, updated: 4, author: 5)
                    replies.append(OutgoingReply(addr: task.addr, status: 201, body: body.take()))
                } else {
                    replies.append(errorReply(task.addr, 404, "article not found"))
                }
            }
        }
    }

    private func execIndividual(_ task: WriteTask, _ replies: inout [OutgoingReply],
                                _ postReads: inout [ReadTask]) throws(PgError) {
        try ensureConn()
        let n = stmtCount(task)
        bindSingleWrite(&conn!.tx, task)
        conn!.tx.writeSync()
        try conn!.flush()
        try conn!.readPipeline(into: &pipe, expected: n)
        finalize(task, 0, n, &replies, &postReads)
    }

    private func finalize(_ task: WriteTask, _ start: Int, _ count: Int, _ replies: inout [OutgoingReply],
                          _ postReads: inout [ReadTask]) {
        let addr = task.addr
        let viewer = task.viewer
        if let err = pipe.results[start..<(start + count)].first(where: { $0.error != nil })?.error {
            if err.code == "23505" {
                replies.append(errorReply(addr, 422, "duplicate username or email"))
            } else {
                logLine("write statement error: \(err)")
                replies.append(errorReply(addr, 500, "internal server error"))
            }
            return
        }
        let rows = pipe.resultRows(start)
        let first: RowSpan? = rows.isEmpty ? nil : pipe.rows[rows.lowerBound]
        func reply(_ status: UInt16, _ build: (inout ByteBuffer) -> Void) {
            var body = ByteBuffer(capacity: 512)
            build(&body)
            replies.append(OutgoingReply(addr: addr, status: status, body: body.take()))
        }
        func readBack(_ r: RowSpan, knownFav: Bool?) {
            postReads.append(ReadTask(op: .articleById(id: pipe.i64(r, 0), knownFav: knownFav), viewer: viewer, addr: addr))
        }
        switch task.op {
        case .register:
            guard let r = first else { return replies.append(errorReply(addr, 422, "duplicate username or email")) }
            let token = signer.issue(pipe.i64(r, 0))
            reply(201) {
                writeUserEnvelope(&$0, email: pipe.text(pipe.cell(r, 2)), token: token.span, username: pipe.text(pipe.cell(r, 1)),
                                  bio: pipe.bytes(pipe.cell(r, 3)), image: pipe.bytes(pipe.cell(r, 4)))
            }
        case .updateUser(let token, _, _, _, _, _):
            guard let r = first else { return replies.append(errorReply(addr, 401, "unauthorized")) }
            reply(200) {
                writeUserEnvelope(&$0, email: pipe.text(pipe.cell(r, 2)), token: token.span, username: pipe.text(pipe.cell(r, 1)),
                                  bio: pipe.bytes(pipe.cell(r, 3)), image: pipe.bytes(pipe.cell(r, 4)))
            }
        case .follow(_, let on):
            guard let r = first else { return replies.append(errorReply(addr, 404, "profile not found")) }
            reply(200) {
                $0.append("{\"profile\":")
                writeProfileJSON(&$0, username: pipe.text(pipe.cell(r, 0)), bio: pipe.bytes(pipe.cell(r, 1)),
                                 image: pipe.bytes(pipe.cell(r, 2)), following: on)
                $0.append(0x7D)
            }
        case .favorite(_, let on):
            guard let r = first else { return replies.append(errorReply(addr, 404, "article not found")) }
            readBack(r, knownFav: on)
        case .createArticle(let title, let description, let articleBody, let tags):
            // Answered from the insert (slug, timestamps, author) and the request itself: a new article has no
            // favorites, and its tags are the ones just sent.
            guard let r = first else { return replies.append(errorReply(addr, 500, "internal server error")) }
            var sortedTags = tags
            if sortedTags.count > 1 {
                sortedTags.sort { $0.lexicographicallyPrecedes($1) }
                var w = 1
                for i in 1..<sortedTags.count where sortedTags[i] != sortedTags[w - 1] {
                    sortedTags[w] = sortedTags[i]
                    w += 1
                }
                sortedTags.removeLast(sortedTags.count - w)
            }
            var body = ByteBuffer(capacity: 2048)
            writeFullArticleEnvelope(&body, pipe, r, title: title, description: description, body: articleBody, tags: sortedTags)
            replies.append(OutgoingReply(addr: addr, status: 201, body: body.take()))
        case .updateArticle:
            guard let r = first else { return replies.append(errorReply(addr, 404, "article not found")) }
            if pipe.i64(r, 1) != viewer { return replies.append(errorReply(addr, 403, "forbidden")) }
            readBack(r, knownFav: nil)
        case .deleteArticle:
            guard let r = first else { return replies.append(errorReply(addr, 404, "article not found")) }
            if pipe.i64(r, 0) != viewer { return replies.append(errorReply(addr, 403, "forbidden")) }
            replies.append(OutgoingReply(addr: addr, status: 204, body: []))
        case .createComment:
            guard let r = first else { return replies.append(errorReply(addr, 404, "article not found")) }
            reply(201) { writeCommentJSON(&$0, pipe, r, id: 0, text: 1, created: 2, updated: 3, author: 4) }
        case .deleteComment:
            guard let r = first else { return replies.append(errorReply(addr, 404, "comment not found")) }
            if pipe.i64(r, 0) != viewer { return replies.append(errorReply(addr, 403, "forbidden")) }
            replies.append(OutgoingReply(addr: addr, status: 204, body: []))
        }
    }
}
