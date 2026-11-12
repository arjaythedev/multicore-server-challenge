// A planner thread: it owns Postgres connections and turns the requests gathering in its lanes into
// batches. Reactors parse and plan nothing about Postgres, so every batch covers the whole server,
// and responses go back to each reactor in arenas it sends from.

#if os(Linux)
import CShim
import CUring

/// A reactor's incoming arenas.
final class Mailbox {
    let lock = sv_mutex_new()
    var arenas: [Arena] = []
    /// Read without the lock: a stale false only delays the mail by one pass.
    var hasMail = false

    func post(_ a: Arena) {
        sv_lock(lock)
        arenas.append(a)
        hasMail = true
        sv_unlock(lock)
    }

    func take() -> [Arena] {
        sv_lock(lock)
        let list = arenas
        arenas.removeAll(keepingCapacity: true)
        hasMail = false
        sv_unlock(lock)
        return list
    }
}

/// What the threads share: the lanes, the write queue, the mailboxes and spare arenas.
final class Shared: @unchecked Sendable {
    let lanes: [Lane] = [Lane(), Lane(), Lane()]
    let writes = WriteQueue()
    let mailboxes: [Mailbox]
    let poolLock = sv_mutex_new()
    var pool: [Arena] = []
    var ready = 0

    init(reactors: Int) {
        mailboxes = (0..<reactors).map { _ in Mailbox() }
    }

    func recycle(_ a: Arena) {
        a.out.truncate(0)
        a.responses.removeAll(keepingCapacity: true)
        a.pendingSends = 0
        sv_lock(poolLock)
        pool.append(a)
        sv_unlock(poolLock)
    }

    func takeArena() -> Arena {
        sv_lock(poolLock)
        let a = pool.popLast()
        sv_unlock(poolLock)
        if let a { return a }
        let fresh = Arena()
        fresh.foreign = true
        return fresh
    }

    func markReady() {
        sv_lock(poolLock)
        ready &+= 1
        sv_unlock(poolLock)
    }

    func readyCount() -> Int {
        sv_lock(poolLock)
        let n = ready
        sv_unlock(poolLock)
        return n
    }
}

final class Planner {
    let shared: Shared
    let url: DatabaseURL
    let ring: UnsafeMutablePointer<io_uring>
    let cqes: UnsafeMutablePointer<UnsafeMutablePointer<io_uring_cqe>?>
    let maxCompletions = 4096
    let ownedLanes: [Int]
    var connections: [PgConnection] = []
    var readers: [PgConnection] = []
    let writer: PgConnection
    let writes: Bool
    let writeGroup = WriteGroup()
    let spareBatch = Batch(listing: false)
    var jwt: JWTVerifier
    var body = OutBuffer(capacity: 1 << 16)
    var lastReconnect: Int64 = 0
    var passStart: Int64 = 0
    /// One arena per reactor, filling until the end of the tick.
    var stage: [Arena?]

    /// `connectionCounts` holds how many connections each owned lane gets.
    init?(shared: Shared, url: DatabaseURL, secret: ByteView, lanes: [(lane: Int, connections: Int)], writes: Bool) {
        self.shared = shared
        self.url = url
        self.writes = writes
        ownedLanes = lanes.map { $0.lane }
        stage = Array(repeating: nil, count: shared.mailboxes.count)
        jwt = JWTVerifier(secret: secret)
        ring = .allocate(capacity: 1)
        cqes = .allocate(capacity: maxCompletions)
        guard tu_setup(ring, 2048, 8192) == 0 else { return nil }
        for (lane, count) in lanes {
            for _ in 0..<count {
                let c = PgConnection(index: UInt32(connections.count), lane: lane, batch: Batch(listing: lane == listsLane))
                connections.append(c)
                readers.append(c)
            }
        }
        writer = PgConnection(index: UInt32(connections.count), lane: -1, batch: nil)
        if writes { connections.append(writer) }
        for c in connections { attach(c) }
    }

    func run() -> Never {
        while true {
            _ = tu_wait(ring, 64, 1000)
            tick()
        }
    }

    func tick() {
        passStart = sv_monotonic_ns()
        let n = Int(io_uring_peek_batch_cqe(ring, cqes, UInt32(maxCompletions)))
        for i in 0..<n {
            let c = cqes[i].unsafelyUnwrapped
            let data = c.pointee.user_data
            let slot = UInt32(truncatingIfNeeded: (data >> 24) & 0xFF_FFFF)
            let generation = UInt16(truncatingIfNeeded: data >> 8)
            if data & 0xFF == pgReceiveTag {
                pgReceived(slot, generation, c.pointee.res)
            } else if data & 0xFF == pgSendTag {
                pgSent(slot, generation, c.pointee.res)
            }
        }
        if n > 0 { io_uring_cq_advance(ring, UInt32(n)) }
        if writes {
            collectCrypto()
            startWrites()
        }
        dispatch(passStart)
        for c in connections { flush(c) }
        for i in 0..<stage.count {
            if let a = stage[i] {
                shared.mailboxes[i].post(a)
                stage[i] = nil
            }
        }
        reconnect()
    }

    @inline(__always)
    func errors(_ status: Int, _ message: StaticString) -> Int {
        body.truncate(0)
        body.append("{\"errors\":{\"body\":[\"")
        body.append(message)
        body.append("\"]}}")
        return status
    }

    /// Writes the full response into the reactor's arena.
    func answer(_ w: Waiter, _ status: Int, _ view: ByteView) {
        let reactor = Int(w.reactor)
        let a: Arena
        if let current = stage[reactor] {
            a = current
        } else {
            a = shared.takeArena()
            stage[reactor] = a
        }
        let start = a.out.count
        appendHTTPResponse(status: status, body: view, close: w.close, into: &a.out)
        a.responses.append(Response(ring: w.ring, slot: w.slot, generation: w.generation, start: start, end: a.out.count, close: w.close))
    }

    @inline(__always)
    func answer(_ q: Req, _ status: Int, _ view: ByteView) {
        answer(Waiter(reactor: q.reactor, ring: q.ring, slot: q.slot, generation: q.generation, close: q.close), status, view)
    }

    @inline(__always)
    func answer(_ item: WriteItem, _ status: Int, _ view: ByteView) {
        answer(Waiter(reactor: item.reactor, ring: item.ring, slot: item.slot, generation: item.generation, close: item.close), status, view)
    }

    /// Connects `c` and starts receiving. On failure it stays dead until the next retry.
    func attach(_ c: PgConnection) {
        let fd = pgConnect(url)
        guard fd >= 0 else { return }
        c.fd = fd
        armPgReceive(c)
    }

    /// Parses every complete message in the connection's input.
    func parseMessages(_ c: PgConnection) {
        var offset = 0
        let input = UnsafePointer(c.input)
        let b = c.batch
        while c.inputCount &- offset >= 5 {
            let length = Int(readBE32(input + (offset &+ 1)))
            if c.inputCount &- offset < 1 &+ length { break }
            let message = input + (offset &+ 5)
            switch input[offset] {
            case UInt8(ascii: "D"):
                if let b {
                    if !b.failed { batchRow(b, message) }
                } else {
                    writeRow(message)
                }
            case UInt8(ascii: "C"):
                if let b { b.stepIndex &+= 1 } else { writeGroup.cursor &+= 1 }
            case UInt8(ascii: "Z"):
                if let b {
                    if b.active { batchReady(b, c) }
                } else {
                    writeReady()
                }
            case UInt8(ascii: "E"):
                if let b {
                    b.failed = true
                    logPostgresError(message, length &- 4)
                } else {
                    writeGroup.failed = true
                    if hasSQLState(message, length &- 4, "23505") { writeGroup.uniqueViolation = true } else { logPostgresError(message, length &- 4) }
                }
            default:
                break // ParseComplete, BindComplete, notices
            }
            offset &+= 1 &+ length
        }
        if offset > 0 {
            let rest = c.inputCount &- offset
            if rest > 0 { memmove(c.input, c.input + offset, rest) }
            c.inputCount = rest
        }
    }

    func hasSQLState(_ fields: UnsafePointer<UInt8>, _ n: Int, _ code: StaticString) -> Bool {
        var i = 0
        while i < n, fields[i] != 0 {
            let type = fields[i]
            var end = i &+ 1
            while end < n, fields[end] != 0 { end &+= 1 }
            if type == UInt8(ascii: "C") { return ByteView(base: fields + (i &+ 1), count: end &- i &- 1).equals(code) }
            i = end &+ 1
        }
        return false
    }

    /// Writes Postgres's message to stderr. Reads don't fail unless something is wrong.
    func logPostgresError(_ fields: UnsafePointer<UInt8>, _ n: Int) {
        var i = 0
        while i < n, fields[i] != 0 {
            let type = fields[i]
            var end = i &+ 1
            while end < n, fields[end] != 0 { end &+= 1 }
            if type == UInt8(ascii: "M") {
                _ = write(2, fields + (i &+ 1), end &- i &- 1)
                _ = write(2, "\n", 1)
            }
            i = end &+ 1
        }
    }

    /// Fails everything the connection owed and schedules a reconnect.
    func lost(_ c: PgConnection) {
        guard c.alive else { return }
        // The shutdown ends a receive still in flight, and the generation drops its completion.
        _ = shutdown(c.fd, Int32(SHUT_RDWR))
        _ = close(c.fd)
        c.fd = -1
        c.generation &+= 1
        c.inputCount = 0
        c.out.truncate(0)
        c.sendActive = false
        if let b = c.batch {
            if b.active { failBatch(b) }
        } else {
            writerLost()
        }
    }

    func armPgReceive(_ c: PgConnection) {
        tu_recv_plain(ring, c.fd, c.input + c.inputCount, UInt32(pgInputCapacity &- c.inputCount),
                      UInt64(pgReceiveTag) | UInt64(c.generation) << 8 | UInt64(c.index) << 24)
    }

    /// Sends what is queued, unless a send is in flight: its completion picks the rest up.
    func flush(_ c: PgConnection) {
        guard c.alive, !c.sendActive, c.out.count > 0 else { return }
        swap(&c.out, &c.sending)
        c.out.truncate(0)
        c.sent = 0
        c.sendActive = true
        submitPgSend(c)
    }

    func submitPgSend(_ c: PgConnection) {
        tu_send_plain(ring, c.fd, c.sending.base + c.sent, UInt32(c.sending.count &- c.sent),
                      UInt64(pgSendTag) | UInt64(c.generation) << 8 | UInt64(c.index) << 24)
    }

    func pgReceived(_ index: UInt32, _ generation: UInt16, _ res: Int32) {
        let c = connections[Int(index)]
        guard c.alive, c.generation == generation else { return }
        guard res > 0 else {
            lost(c)
            return
        }
        c.inputCount &+= Int(res)
        parseMessages(c)
        if c.alive { armPgReceive(c) }
    }

    func pgSent(_ index: UInt32, _ generation: UInt16, _ res: Int32) {
        let c = connections[Int(index)]
        guard c.alive, c.generation == generation else { return }
        guard res > 0 else {
            lost(c)
            return
        }
        c.sent &+= Int(res)
        if c.sent < c.sending.count {
            submitPgSend(c)
        } else {
            c.sendActive = false
        }
    }

    /// Retries dead connections, at most once a second.
    func reconnect() {
        let now = sv_monotonic_s()
        guard now != lastReconnect else { return }
        var dead = false
        for c in connections where !c.alive { dead = true }
        guard dead else { return }
        lastReconnect = now
        for c in connections where !c.alive {
            attach(c)
            if !c.alive { return }
        }
    }
}

let pgReceiveTag: UInt64 = 16
let pgSendTag: UInt64 = 17
#endif
