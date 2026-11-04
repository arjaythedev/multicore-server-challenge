// Writes. All the writes that gather while the last group commits go out as one pipeline with one
// Sync, so they share one transaction and one WAL flush, and each response waits for ReadyForQuery.
// If a statement fails, Postgres rolls the whole group back, and each member retries alone.

#if os(Linux)
import CBcrypt
import CShim

enum WriteKind: UInt8 {
    case register, updateUser, follow, unfollow, favorite, unfavorite
    case createArticle, updateArticle, deleteArticle, createComment, deleteComment
}

struct WriteItem {
    var kind: WriteKind
    var close: Bool
    var solo: Bool
    var generation: UInt16
    var reactor: Int32
    var ring: Int32
    var slot: UInt32
    var viewer: Int64
    /// The Bind and Execute bytes, then the presented token, in the queue's buffer.
    var start: Int32
    var end: Int32
    var tokenEnd: Int32
    // Filled in from the result.
    var groupLast = false
    var hasRow = false
    var id: Int64 = 0
    var result = Span()
}

final class WriteQueue {
    var items: [WriteItem] = []
    var bytes = OutBuffer(capacity: 1 << 16)
    let lock = sv_mutex_new()

    @inline(__always)
    func add(_ kind: WriteKind, _ waiter: Waiter, viewer: Int64, token: ByteView, solo: Bool, bind: (inout OutBuffer) -> Void) {
        let start = bytes.count
        bind(&bytes)
        let end = bytes.count
        bytes.append(token)
        items.append(WriteItem(kind: kind, close: waiter.close, solo: solo, generation: waiter.generation,
                               reactor: waiter.reactor, ring: waiter.ring, slot: waiter.slot, viewer: viewer,
                               start: Int32(truncatingIfNeeded: start), end: Int32(truncatingIfNeeded: end),
                               tokenEnd: Int32(truncatingIfNeeded: bytes.count)))
    }

    /// Moves everything in `other` here. The caller holds this queue's lock.
    func absorb(_ other: WriteQueue) {
        let shift = Int32(truncatingIfNeeded: bytes.count)
        for var item in other.items {
            item.start &+= shift
            item.end &+= shift
            item.tokenEnd &+= shift
            items.append(item)
        }
        bytes.append(other.bytes.view)
        other.items.removeAll(keepingCapacity: true)
        other.bytes.truncate(0)
    }
}

/// The group on the wire.
final class WriteGroup {
    var items: [WriteItem] = []
    var bytes = OutBuffer(capacity: 1 << 16)
    var active = false
    var cursor = 0
    var groupStart = 0
    var failed = false
    var uniqueViolation = false
    var result = OutBuffer(capacity: 1 << 14)
}

/// Work for the hashing threads. Holds its own copies, since the request's memory is gone by then.
final class CryptoWork {
    enum Kind { case login, register, updateUser }
    let kind: Kind
    let waiter: Waiter
    var id: Int64 = 0
    var fragment: [UInt8] = []
    var fields: [[UInt8]?] = []
    var token: [UInt8] = []

    init(kind: Kind, waiter: Waiter) {
        self.kind = kind
        self.waiter = waiter
    }
}

extension Planner {
    /// Puts everything queued on the wire, if the last group is done.
    func startWrites() {
        let q = shared.writes
        guard !q.items.isEmpty else { return } // a racy read: the next tick sees it
        let g = writeGroup
        guard !g.active || !writer.alive else { return }
        sv_lock(q.lock)
        swap(&g.items, &q.items)
        swap(&g.bytes, &q.bytes)
        q.items.removeAll(keepingCapacity: true)
        q.bytes.truncate(0)
        sv_unlock(q.lock)
        guard writer.alive else {
            _ = errors(500, "internal error")
            for item in g.items { answer(item, 500, body.view) }
            return
        }
        g.result.truncate(0)
        g.active = true
        g.cursor = 0
        g.groupStart = 0
        g.failed = false
        g.uniqueViolation = false
        var open = false
        let c = writer
        let base = UnsafePointer(g.bytes.base)
        for i in 0..<g.items.count {
            let item = g.items[i]
            if item.solo && open {
                c.out.appendSync()
                g.items[i &- 1].groupLast = true
                open = false
            }
            c.out.append(base + Int(item.start), Int(item.end &- item.start))
            if item.solo {
                c.out.appendSync()
                g.items[i].groupLast = true
            } else {
                open = true
            }
        }
        if open {
            c.out.appendSync()
            g.items[g.items.count &- 1].groupLast = true
        }
    }

    func writeRow(_ message: UnsafePointer<UInt8>) {
        let g = writeGroup
        guard g.cursor < g.items.count else { return }
        var row = Columns(message)
        let i = g.cursor
        g.items[i].hasRow = true
        let start = g.result.count
        switch g.items[i].kind {
        case .register, .updateUser:
            let id = row.int8()
            let username = row.text()
            let email = row.text()
            let bio = row.next()
            let image = row.next()
            g.result.append("{\"user\":{")
            g.result.appendUserFields(email: email, username: username, bio: bio, image: image)
            g.result.append(",\"token\":\"")
            if g.items[i].kind == .register {
                jwt.sign(id: id, nowSeconds: sv_now_ms() / 1000, into: &g.result)
            } else {
                g.result.append(UnsafePointer(g.bytes.base) + Int(g.items[i].end),
                                Int(g.items[i].tokenEnd &- g.items[i].end))
            }
            g.result.append("\"}}")
        case .follow, .unfollow:
            let username = row.text()
            let bio = row.next()
            let image = row.next()
            g.result.append("{\"profile\":{\"username\":")
            g.result.appendJSONString(username)
            g.result.append(",\"bio\":")
            g.result.appendOptionalJSONString(bio)
            g.result.append(",\"image\":")
            g.result.appendOptionalJSONString(image)
            g.result.append(",\"following\":")
            g.result.appendBool(g.items[i].kind == .follow)
            g.result.append("}}")
        case .favorite, .unfavorite, .createArticle:
            g.items[i].id = row.int8()
        case .updateArticle:
            g.items[i].id = row.int8()
            g.items[i].hasRow = row.int8() == g.items[i].viewer
            g.items[i].result.count = g.items[i].hasRow ? 0 : 1
        case .deleteArticle, .deleteComment:
            g.items[i].hasRow = row.int8() == g.items[i].viewer
            g.items[i].result.count = g.items[i].hasRow ? 0 : 1
            return
        case .createComment:
            let id = row.int8()
            let text = row.text()
            let created = row.int8()
            let updated = row.int8()
            let username = row.text()
            let bio = row.next()
            let image = row.next()
            g.result.append("{\"comment\":{\"id\":")
            g.result.appendInt(id)
            g.result.append(",\"createdAt\":")
            g.result.appendTimestamp(created)
            g.result.append(",\"updatedAt\":")
            g.result.appendTimestamp(updated)
            g.result.append(",\"body\":")
            g.result.appendJSONString(text)
            g.result.append(",\"author\":{\"username\":")
            g.result.appendJSONString(username)
            g.result.append(",\"bio\":")
            g.result.appendOptionalJSONString(bio)
            g.result.append(",\"image\":")
            g.result.appendOptionalJSONString(image)
            g.result.append(",\"following\":false}}}")
        }
        if g.items[i].kind != .updateArticle {
            g.items[i].result = Span(start: Int32(truncatingIfNeeded: start), count: Int32(truncatingIfNeeded: g.result.count &- start))
        }
    }

    /// Postgres ended a transaction: everything before the Sync is committed, or none of it.
    func writeReady() {
        let g = writeGroup
        let start = g.groupStart
        var end = start
        while end < g.items.count && !g.items[end].groupLast { end &+= 1 }
        guard end < g.items.count else { return }
        if g.failed {
            if end == start {
                let status = g.uniqueViolation ? errors(422, "already taken") : errors(500, "internal error")
                answer(g.items[start], status, body.view)
            } else {
                let q = shared.writes
                sv_lock(q.lock)
                for i in start...end {
                    var item = g.items[i]
                    let from = Int(item.start)
                    let start = q.bytes.count
                    q.bytes.append(UnsafePointer(g.bytes.base) + from, Int(item.tokenEnd) &- from)
                    item.end = item.end &- item.start &+ Int32(truncatingIfNeeded: start)
                    item.tokenEnd = Int32(truncatingIfNeeded: q.bytes.count)
                    item.start = Int32(truncatingIfNeeded: start)
                    item.solo = true
                    item.hasRow = false
                    item.groupLast = false
                    q.items.append(item)
                }
                sv_unlock(q.lock)
            }
        } else {
            for i in start...end { completeWrite(g.items[i]) }
        }
        g.failed = false
        g.uniqueViolation = false
        g.groupStart = end &+ 1
        g.cursor = end &+ 1
        if g.groupStart == g.items.count { g.active = false }
    }

    func completeWrite(_ item: WriteItem) {
        let g = writeGroup
        let view = ByteView(base: UnsafePointer(g.result.base) + Int(item.result.start), count: Int(item.result.count))
        switch item.kind {
        case .register:
            if item.hasRow {
                answer(item, 201, view)
            } else {
                answer(item, errors(422, "already taken"), body.view)
            }
        case .updateUser:
            if item.hasRow {
                answer(item, 200, view)
            } else {
                answer(item, errors(401, "unauthorized"), body.view)
            }
        case .follow, .unfollow:
            if item.hasRow {
                answer(item, 200, view)
            } else {
                answer(item, errors(404, "not found"), body.view)
            }
        case .createComment:
            if item.hasRow {
                answer(item, 201, view)
            } else {
                answer(item, errors(404, "not found"), body.view)
            }
        case .favorite, .unfavorite, .createArticle:
            if item.hasRow {
                readBack(item, status: item.kind == .createArticle ? 201 : 200)
            } else {
                answer(item, errors(404, "not found"), body.view)
            }
        case .updateArticle:
            if item.hasRow {
                readBack(item, status: 200)
            } else if item.result.count == 1 {
                answer(item, errors(403, "forbidden"), body.view)
            } else {
                answer(item, errors(404, "not found"), body.view)
            }
        case .deleteArticle, .deleteComment:
            if item.hasRow {
                answer(item, 204, .empty)
            } else if item.result.count == 1 {
                answer(item, errors(403, "forbidden"), body.view)
            } else {
                answer(item, errors(404, "not found"), body.view)
            }
        }
    }

    /// The write committed; the response shows the article as it is now.
    func readBack(_ item: WriteItem, status: Int32) {
        var r = Req(kind: .articleByID, close: item.close, generation: item.generation, ring: item.ring, slot: item.slot)
        r.reactor = item.reactor
        r.status = status
        r.viewer = item.viewer
        r.id = item.id
        let lane = shared.lanes[listsLane]
        sv_lock(lane.lock)
        lane.push(r, now: passStart)
        sv_unlock(lane.lock)
    }

    /// The writer's connection died: nobody knows what committed, so everything on the wire fails.
    func writerLost() {
        let g = writeGroup
        guard g.active else { return }
        _ = errors(500, "internal error")
        for i in g.groupStart..<g.items.count { answer(g.items[i], 500, body.view) }
        g.active = false
    }

    // MARK: bcrypt

    /// A planner's own write, from a finished hash.
    func enqueueWrite(_ kind: WriteKind, _ waiter: Waiter, viewer: Int64, token: ByteView, solo: Bool, bind: (inout OutBuffer) -> Void) {
        let q = shared.writes
        sv_lock(q.lock)
        q.add(kind, waiter, viewer: viewer, token: token, solo: solo, bind: bind)
        sv_unlock(q.lock)
    }

    func startLogin(_ r: Req, secret: ByteView, hash: ByteView, id: Int64, email: ByteView, username: ByteView,
                    bio: ByteView?, image: ByteView?) {
        let work = CryptoWork(kind: .login, waiter: Waiter(reactor: r.reactor, ring: r.ring, slot: r.slot, generation: r.generation, close: r.close))
        work.id = id
        body.truncate(0)
        body.append("{\"user\":{")
        body.appendUserFields(email: email, username: username, bio: bio, image: image)
        work.fragment = Array(UnsafeBufferPointer(start: UnsafePointer(body.base), count: body.count))
        submitCrypto(work, password: secret, hash: hash)
    }

    /// Takes finished hashes. Called once a pass; costs one atomic load when there are none.
    func collectCrypto() {
        var job = bc_collect(0)
        while let finished = job {
            job = finished.pointee.next
            let work = Unmanaged<CryptoWork>.fromOpaque(finished.pointee.context).takeRetainedValue()
            let matched = finished.pointee.matched != 0
            let hash: [UInt8] = withUnsafeBytes(of: &finished.pointee.hash) { Array($0.prefix(60)) }
            bc_free(finished)
            finishCrypto(work, matched: matched, hash: hash)
        }
    }

    func finishCrypto(_ work: CryptoWork, matched: Bool, hash: [UInt8]) {
        switch work.kind {
        case .login:
            guard matched else {
                answer(work.waiter, errors(401, "invalid credentials"), body.view)
                return
            }
            body.truncate(0)
            work.fragment.withUnsafeBufferPointer { body.append($0.baseAddress.unsafelyUnwrapped, $0.count) }
            body.append(",\"token\":\"")
            jwt.sign(id: work.id, nowSeconds: sv_now_ms() / 1000, into: &body)
            body.append("\"}}")
            answer(work.waiter, 200, body.view)
        case .register:
            guard matched else {
                answer(work.waiter, errors(500, "internal error"), body.view)
                return
            }
            enqueueWrite(.register, work.waiter, viewer: 0, token: .empty, solo: false) { out in
                out.appendBindExecute("register", parameterCount: 3) { p in
                    p.appendTextParameter(work.fields[0])
                    p.appendTextParameter(work.fields[1])
                    p.appendTextBytes(hash)
                }
            }
        case .updateUser:
            guard matched else {
                answer(work.waiter, errors(500, "internal error"), body.view)
                return
            }
            work.token.withUnsafeBufferPointer { token in
                enqueueWrite(.updateUser, work.waiter, viewer: work.id, token: ByteView(base: token.baseAddress, count: token.count), solo: true) { out in
                    out.appendBindExecute("upduser", parameterCount: 6) { p in
                        p.appendInt8Parameter(work.id)
                        p.appendTextParameter(work.fields[0])
                        p.appendTextParameter(work.fields[1])
                        p.appendTextBytes(hash)
                        p.appendTextParameter(work.fields[2])
                        p.appendTextParameter(work.fields[3])
                    }
                }
            }
        }
    }
}

/// Hands a hash to the pool. Any thread may call this.
func submitCrypto(_ work: CryptoWork, password: ByteView, hash: ByteView?) {
    guard let job = bc_new() else { return }
    job.pointee.context = Unmanaged.passRetained(work).toOpaque()
    job.pointee.owner = 0
    job.pointee.verify = hash == nil ? 0 : 1
    let n = min(password.count, 72)
    job.pointee.password_len = Int32(n)
    withUnsafeMutableBytes(of: &job.pointee.password) { raw in
        let p = raw.baseAddress.unsafelyUnwrapped.assumingMemoryBound(to: UInt8.self)
        if n > 0 { p.update(from: password.base.unsafelyUnwrapped, count: n) }
    }
    if let hash {
        let m = min(hash.count, 60)
        withUnsafeMutableBytes(of: &job.pointee.hash) { raw in
            let p = raw.baseAddress.unsafelyUnwrapped.assumingMemoryBound(to: UInt8.self)
            if m > 0 { p.update(from: hash.base.unsafelyUnwrapped, count: m) }
            p[m] = 0
        }
    }
    bc_submit(job)
}


extension OutBuffer {
    mutating func appendTextParameter(_ bytes: [UInt8]?) {
        guard let bytes else {
            appendBE32(-1)
            return
        }
        appendTextBytes(bytes)
    }

    mutating func appendTextBytes(_ bytes: [UInt8]) {
        appendBE32(Int32(truncatingIfNeeded: bytes.count))
        bytes.withUnsafeBufferPointer { if $0.count > 0 { append($0.baseAddress.unsafelyUnwrapped, $0.count) } }
    }
}
#endif
