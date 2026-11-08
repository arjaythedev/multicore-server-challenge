// reactor.rs: an HTTP/1.1 reactor on its own SO_REUSEPORT listener, with a file descriptor table of its own. It is an
// actor on its own event loop: the connection table is plain actor state, touched only by this actor's thread. Each
// turn it takes the ready events off its epoll instance, parses and routes what arrived, and hands the tick's work
// to the scheduler in one call, which its task makes on the scheduler's loop and comes back from. Replies arrive as
// `deliver` calls from the lanes, one per batch, and go out with writev.
import Glibc
import Syscalls

actor Reactor {
    let index: UInt16
    nonisolated let loop: EventLoop
    nonisolated var unownedExecutor: UnownedSerialExecutor { loop.asUnownedSerialExecutor() }

    private let signer: TokenSigner
    private let scheduler: Scheduler
    private let host: String
    private let port: UInt16
    private let fdBudget: Int

    private var listenFD: Int32 = -1
    private var slots = UniqueArray<ClientSlot>(capacity: 16384)
    private var freeSlots: [UInt32] = []
    private var scratch = ByteBuffer(capacity: 256 * 1024)
    /// Error bodies are written here, and sent from here.
    private var errorBody = ByteBuffer(capacity: 256)
    private var pipelinedSlots: [UInt32] = []
    private var activeConns = 0
    private var idleHead = idleNone
    private var idleTail = idleNone
    private var events: [UInt8]
    private let maxEvents = 1024
    /// What this tick routed, for the scheduler.
    private var pending = Submission()
    /// How long a tick that didn't fill `events` lasts, counted from its epoll_wait.
    private let passNanos: UInt64

    init(index: Int, loop: EventLoop, signer: TokenSigner, scheduler: Scheduler, host: String, port: UInt16, fdBudget: Int,
         passNanos: UInt64) {
        self.index = UInt16(index)
        self.passNanos = passNanos
        self.loop = loop
        self.signer = signer
        self.scheduler = scheduler
        self.host = host
        self.port = port
        self.fdBudget = max(fdBudget, 256)
        events = [UInt8](repeating: 0, count: maxEvents * Sys.epollEventStride)
        freeSlots.reserveCapacity(4096)
        pipelinedSlots.reserveCapacity(256)
    }

    @inline(__always) private func ctl(_ op: Int32, _ fd: Int32, _ events: UInt32, _ token: UInt64) -> Bool {
        EventLoop.control(loop.epollFD, op, fd, events, token) == 0
    }

    // ---------- the loop ----------

    func run() async {
        Sys.unshareFiles()
        do {
            listenFD = try Sys.bindListener(host: host, port: port)
        } catch {
            fatalError("failed to bind listener: \(error)")
        }
        guard ctl(Sys.EPOLL_CTL_ADD, listenFD, Sys.EPOLLIN, Self.tokenListener) else { fatalError("epoll_ctl listener: \(errno)") }
        while true {
            // One epoll_wait per tick, as the Rust's loop: it blocks here, on this actor's own thread, until a socket is
            // ready or a message (a lane's `deliver`) is queued for the actor.
            let (n, messagesWaiting) = loop.waitForEvents(&events)
            let turnStarted = Sys.monotonicNanos()
            for i in 0..<n {
                let base = i * Sys.epollEventStride
                let flags = events.span.bytes.load(fromByteOffset: base, as: UInt32.self)
                let token = events.span.bytes.load(fromByteOffset: base + Sys.epollDataOffset, as: UInt64.self)
                switch token {
                case Self.tokenListener: acceptReady()
                default:
                    let slot = UInt32(truncatingIfNeeded: token)
                    if flags & Sys.EPOLLOUT != 0 { flushTx(slot) }
                    if flags & (Sys.EPOLLIN | Sys.EPOLLHUP | Sys.EPOLLERR | Sys.EPOLLRDHUP) != 0 { readReady(slot, flags) }
                }
            }
            if !pending.isEmpty {
                // While this task is on the scheduler's loop, the messages queued here run.
                await submitPending()
            } else if messagesWaiting {
                // Let them run now (jobs on this same thread: Task.yield re-enqueues on the actor's executor).
                await Task.yield()
            }
            // A lane's replies may have routed pipelined requests: they go to the scheduler now, not after the next
            // wake-up, which may not come.
            if !pending.isEmpty { await submitPending() }
            // A fixed cadence: a tick that didn't fill `events` lasts `passNanos` from its epoll_wait, so what arrives
            // meanwhile is routed in the next one and goes to the scheduler in one call with it: one round trip for
            // many requests. The task waits on this loop, whose thread runs the lanes' deliveries in the meantime. A
            // full tick goes straight on, so the cadence can't cap throughput.
            if n > 0 && n < maxEvents && passNanos > 0 {
                let deadline = turnStarted + passNanos
                if Sys.monotonicNanos() < deadline { await loop.wait(until: deadline) }
            }
        }
    }

    /// Hands this tick's work to the scheduler: this task carries it to the scheduler's loop and comes back with the
    /// submission emptied, which the next tick fills (unless a delivery that ran meanwhile already started one).
    private func submitPending() async {
        var work = Submission()
        swap(&work, &pending)
        let emptied = await scheduler.submit(consume work)
        if pending.isEmpty { pending = emptied }
    }

    /// A batch of replies from a lane (flush_outbox), with the buffer their `.slice` bodies are in, lent for the call.
    func deliver(_ replies: borrowing [OutgoingReply], bodies: borrowing [UInt8]) {
        for i in replies.indices {
            let rep = replies[i]
            let s = Int(rep.addr.slot)
            guard s < slots.count, slots[s].fd >= 0, slots[s].epoch == rep.addr.epoch, slots[s].inFlight else { continue }
            let hasBufferedRx = !slots[s].rx.isEmpty
            switch rep.body {
            case .bytes(let body): body.withUnsafeBytes { writeResponse(rep.addr.slot, rep.status, $0) }
            case .slice(let range):
                bodies.withUnsafeBytes {
                    writeResponse(rep.addr.slot, rep.status, UnsafeRawBufferPointer(rebasing: $0[Int(range.lowerBound)..<Int(range.upperBound)]))
                }
            case .error(let message): writeError(rep.addr.slot, rep.status, message)
            }
            if hasBufferedRx { pipelinedSlots.append(rep.addr.slot) }
        }
        for slot in pipelinedSlots { drainRxBuf(slot) }
        pipelinedSlots.removeAll(keepingCapacity: true)
        // Pipelined requests routed here go out as soon as the tick that let this message run resumes.
    }

    // ---------- connections ----------

    private func linkIdle(_ slot: UInt32) {
        let s = Int(slot)
        if slots[s].inIdleLRU || slots[s].fd < 0 { return }
        slots[s].inIdleLRU = true
        slots[s].idlePrev = idleTail
        slots[s].idleNext = Self.idleNone
        if idleTail != Self.idleNone {
            slots[Int(idleTail)].idleNext = slot
        } else {
            idleHead = slot
        }
        idleTail = slot
    }

    private func unlinkIdle(_ slot: UInt32) {
        let s = Int(slot)
        guard slots[s].inIdleLRU else { return }
        slots[s].inIdleLRU = false
        let prev = slots[s].idlePrev
        let next = slots[s].idleNext
        slots[s].idlePrev = Self.idleNone
        slots[s].idleNext = Self.idleNone
        if prev != Self.idleNone { slots[Int(prev)].idleNext = next } else { idleHead = next }
        if next != Self.idleNone { slots[Int(next)].idlePrev = prev } else { idleTail = prev }
    }

    private func acceptReady() {
        while true {
            while activeConns >= fdBudget && idleHead != Self.idleNone { dropConn(idleHead) }
            let fd = sys_accept4(listenFD, nil, nil, Sys.SOCK_NONBLOCK | Sys.SOCK_CLOEXEC)
            if fd < 0 {
                switch errno {
                case Sys.EAGAIN: return
                case Sys.EINTR, Sys.ECONNABORTED: continue
                case Sys.EMFILE, Sys.ENFILE:
                    if idleHead != Self.idleNone {
                        dropConn(idleHead)
                        continue
                    }
                    return
                default: return
                }
            }
            Sys.setNoDelay(fd)
            let slot: UInt32
            if let idx = freeSlots.popLast() {
                let s = Int(idx)
                slots[s].fd = fd
                slots[s].inFlight = false
                slots[s].closeOnDone = false
                slots[s].eofSeen = false
                slots[s].pollingOut = false
                slots[s].continueSent = false
                slots[s].reused = false
                slots[s].inIdleLRU = false
                slots[s].idlePrev = Self.idleNone
                slots[s].idleNext = Self.idleNone
                slots[s].txOff = 0
                slot = idx
            } else {
                slots.append(ClientSlot(fd: fd))
                slot = UInt32(slots.count - 1)
            }
            activeConns += 1
            if !ctl(Sys.EPOLL_CTL_ADD, fd, Sys.EPOLLIN | Sys.EPOLLRDHUP, UInt64(slot)) { dropConn(slot) }
        }
    }

    private func dropConn(_ slot: UInt32) {
        let s = Int(slot)
        if slots[s].fd < 0 { return }
        unlinkIdle(slot)
        if slots[s].inFlight {
            // Its request may still be queued: the scheduler drops it (is_addr_alive in the Rust).
            pending.cancelled.append(ReplyAddr(worker: index, slot: slot, epoch: slots[s].epoch))
        }
        _ = sys_close(slots[s].fd)
        slots[s].fd = -1
        let nextEpoch = slots[s].epoch &+ 1
        slots[s].epoch = nextEpoch == Self.epochClosed ? 0 : nextEpoch
        slots[s].rx.release()
        slots[s].tx.release()
        slots[s].txOff = 0
        slots[s].inFlight = false
        slots[s].reused = false
        activeConns = max(activeConns - 1, 0)
        freeSlots.append(slot)
    }

    private func readReady(_ slot: UInt32, _ flags: UInt32) {
        let s = Int(slot)
        if slots[s].fd < 0 { return }
        if flags & (Sys.EPOLLHUP | Sys.EPOLLERR) != 0 && flags & Sys.EPOLLIN == 0 {
            dropConn(slot)
            return
        }
        unlinkIdle(slot)
        var firstRead = true
        while true {
            if slots[s].fd < 0 { return }
            let fd = slots[s].fd
            let canDirectParse = firstRead && !slots[s].inFlight && slots[s].rx.isEmpty
            firstRead = false
            scratch.removeAll()
            let n = scratch.appendSpare(maximum: 256 * 1024) { spare in sys_read(fd, spare.baseAddress, spare.count) }
            if n < 0 {
                switch errno {
                case Sys.EAGAIN:
                    if flags & (Sys.EPOLLHUP | Sys.EPOLLERR | Sys.EPOLLRDHUP) != 0 {
                        dropConn(slot)
                        return
                    }
                case Sys.EINTR:
                    continue
                default:
                    dropConn(slot)
                    return
                }
                break
            }
            if n == 0 {
                peerDone(slot)
                return
            }
            // Parse straight out of the scratch buffer when the connection has nothing left over.
            if canDirectParse && n < 256 * 1024 {
                let addr = ReplyAddr(worker: index, slot: slot, epoch: slots[s].epoch)
                let outcome = HTTP.parseRequest(signer, scratch.span, addr)
                switch consume outcome {
                case .complete(let consumed, let closeAfter, let dispatch):
                    slots[s].continueSent = false
                    slots[s].closeOnDone = closeAfter
                    slots[s].inFlight = true
                    if consumed < n { slots[s].rx.append(scratch, consumed..<n) }
                    if handle(dispatch, slot) && slots[s].fd >= 0 && !slots[s].rx.isEmpty { drainRxBuf(slot) }
                case .incomplete(let sendContinue):
                    slots[s].rx.append(scratch, 0..<n)
                    if sendContinue && !slots[s].continueSent {
                        slots[s].continueSent = true
                        writeRaw(slot, "HTTP/1.1 100 Continue\r\n\r\n")
                    }
                case .reject(let status):
                    rejectConn(slot, status)
                }
                return
            }
            slots[s].rx.append(scratch, 0..<n)
            if n < 256 * 1024 { break }
        }
        drainRxBuf(slot)
    }

    /// The peer is done sending (it may have only half-closed): what it sent is answered, then the connection closes.
    /// Its socket stops being polled for input, which epoll would otherwise report again and again.
    private func peerDone(_ slot: UInt32) {
        let s = Int(slot)
        guard slots[s].inFlight || slots[s].txOff < slots[s].tx.count || !slots[s].rx.isEmpty else {
            dropConn(slot)
            return
        }
        slots[s].eofSeen = true
        unlinkIdle(slot)
        _ = ctl(Sys.EPOLL_CTL_MOD, slots[s].fd, slots[s].pollingOut ? Sys.EPOLLOUT : 0, UInt64(slot))
        if !slots[s].inFlight { drainRxBuf(slot) }
    }

    /// Writes an immediate answer, or queues the work for this tick's submission. Whether it was immediate.
    private func handle(_ dispatch: consuming Router.Dispatch, _ slot: UInt32) -> Bool {
        switch consume dispatch {
        case .error(let status, let message):
            writeError(slot, status, message)
            return true
        case .constant(let status, let body):
            writeResponse(slot, status, UnsafeRawBufferPointer(start: body.utf8Start, count: body.utf8CodeUnitCount))
            return true
        case .read(let t): pending.reads.append(t)
        case .readFront(let t): pending.readsFront.append(t)
        case .write(let t): pending.writes.append(t)
        case .crypto(let t): pending.crypto.append(t)
        }
        return false
    }

    private func drainRxBuf(_ slot: UInt32) {
        let s = Int(slot)
        while true {
            if slots[s].fd < 0 || slots[s].inFlight || slots[s].rx.isEmpty {
                if slots[s].fd >= 0 && slots[s].rx.isEmpty {
                    if slots[s].rx.capacity > 4096 { slots[s].rx.release() } else { slots[s].rx.removeAll() }
                    let idle = !slots[s].inFlight && slots[s].txOff >= slots[s].tx.count
                    if idle && slots[s].eofSeen {
                        dropConn(slot)
                    } else if idle && slots[s].reused {
                        linkIdle(slot)
                    }
                }
                return
            }
            let addr = ReplyAddr(worker: index, slot: slot, epoch: slots[s].epoch)
            let outcome = HTTP.parseRequest(signer, slots[s].rx.span, addr)
            switch consume outcome {
            case .complete(let consumed, let closeAfter, let dispatch):
                slots[s].continueSent = false
                slots[s].closeOnDone = closeAfter
                slots[s].inFlight = true
                if consumed == slots[s].rx.count { slots[s].rx.release() } else { slots[s].rx.removeFirst(consumed) }
                if !handle(dispatch, slot) { return }
            case .incomplete(let sendContinue):
                // A request the peer will never finish.
                if slots[s].eofSeen {
                    if slots[s].txOff >= slots[s].tx.count { dropConn(slot) } else { slots[s].closeOnDone = true }
                    return
                }
                if sendContinue && !slots[s].continueSent {
                    slots[s].continueSent = true
                    writeRaw(slot, "HTTP/1.1 100 Continue\r\n\r\n")
                }
                return
            case .reject(let status):
                rejectConn(slot, status)
                return
            }
        }
    }

    private func rejectConn(_ slot: UInt32, _ status: UInt16) {
        let s = Int(slot)
        slots[s].closeOnDone = true
        slots[s].inFlight = true
        slots[s].rx.release()
        writeError(slot, status, HTTP.reasonPhrase(status))
    }

    /// The RealWorld error body, written here and sent from here.
    private func writeError(_ slot: UInt32, _ status: UInt16, _ message: StaticString) {
        errorBody.removeAll()
        JSON.writeError(&errorBody, message)
        errorBody.withBytes { writeResponse(slot, status, $0) }
    }

    // ---------- writing ----------

    private func writeResponse(_ slot: UInt32, _ status: UInt16, _ body: UnsafeRawBufferPointer) {
        let s = Int(slot)
        slots[s].inFlight = false
        slots[s].reused = true
        let close = slots[s].closeOnDone
        // The head in an inline array on the stack, as the Rust's `[0u8; 160]`: no allocation per response.
        var head = InlineArray<192, UInt8>(repeating: 0)
        var headSpan = head.mutableSpan
        let n = HTTP.formatHeader(into: &headSpan, status, body.count, close)
        head.span.withUnsafeBytes { send(slot, UnsafeRawBufferPointer(rebasing: $0[0..<n]), body) }
        updateWriteState(slot)
    }

    /// Writes header and body with one writev, keeping whatever the socket didn't take for EPOLLOUT.
    private func send(_ slot: UInt32, _ header: UnsafeRawBufferPointer, _ body: UnsafeRawBufferPointer) {
        let s = Int(slot)
        if slots[s].tx.count > slots[s].txOff {
            slots[s].tx.append(header)
            slots[s].tx.append(body)
            return
        }
        let total = header.count + body.count
        let rc = withUnsafeTemporaryAllocation(of: iovec.self, capacity: 2) { iov in
            iov[0] = iovec(iov_base: UnsafeMutableRawPointer(mutating: header.baseAddress), iov_len: header.count)
            iov[1] = iovec(iov_base: UnsafeMutableRawPointer(mutating: body.baseAddress), iov_len: body.count)
            return sys_writev(slots[s].fd, iov.baseAddress!, body.isEmpty ? 1 : 2)
        }
        var written = 0
        if rc < 0 {
            if errno != Sys.EAGAIN && errno != Sys.EINTR {
                dropConn(slot)
                return
            }
        } else {
            written = rc
        }
        if written < total {
            slots[s].tx.removeAll()
            slots[s].txOff = 0
            if written < header.count {
                slots[s].tx.append(UnsafeRawBufferPointer(rebasing: header[written...]))
                slots[s].tx.append(body)
            } else {
                slots[s].tx.append(UnsafeRawBufferPointer(rebasing: body[(written - header.count)...]))
            }
        }
    }

    private func writeRaw(_ slot: UInt32, _ raw: StaticString) {
        let s = Int(slot)
        let bytes = UnsafeRawBufferPointer(start: raw.utf8Start, count: raw.utf8CodeUnitCount)
        if slots[s].tx.count > slots[s].txOff {
            slots[s].tx.append(bytes)
        } else {
            let rc = sys_write(slots[s].fd, bytes.baseAddress, bytes.count)
            var written = 0
            if rc < 0 {
                if errno != Sys.EAGAIN && errno != Sys.EINTR {
                    dropConn(slot)
                    return
                }
            } else {
                written = rc
            }
            if written < bytes.count {
                slots[s].tx.removeAll()
                slots[s].txOff = 0
                slots[s].tx.append(UnsafeRawBufferPointer(rebasing: bytes[written...]))
            }
        }
        updateWriteState(slot)
    }

    private func flushTx(_ slot: UInt32) {
        let s = Int(slot)
        if slots[s].fd < 0 { return }
        while slots[s].txOff < slots[s].tx.count {
            let fd = slots[s].fd
            let off = slots[s].txOff
            let rc = slots[s].tx.withBytes { sys_write(fd, $0.baseAddress! + off, $0.count - off) }
            if rc < 0 {
                if errno == Sys.EAGAIN { break }
                if errno == Sys.EINTR { continue }
                dropConn(slot)
                return
            }
            slots[s].txOff += rc
        }
        updateWriteState(slot)
    }

    private func updateWriteState(_ slot: UInt32) {
        let s = Int(slot)
        if slots[s].fd < 0 { return }
        let hasUnsent = slots[s].txOff < slots[s].tx.count
        if !hasUnsent {
            if slots[s].tx.capacity > 4096 { slots[s].tx.release() } else { slots[s].tx.removeAll() }
            slots[s].txOff = 0
        }
        let inFlight = slots[s].inFlight
        let shouldDrop = !hasUnsent && !inFlight && (slots[s].closeOnDone || (slots[s].eofSeen && slots[s].rx.isEmpty))
        let shouldLinkIdle = !shouldDrop && !hasUnsent && !inFlight && slots[s].rx.isEmpty && slots[s].reused && !slots[s].eofSeen
        var maskChange: UInt32?
        if !shouldDrop && hasUnsent != slots[s].pollingOut {
            slots[s].pollingOut = hasUnsent
            let input = slots[s].eofSeen ? 0 : Sys.EPOLLIN | Sys.EPOLLRDHUP
            maskChange = hasUnsent ? input | Sys.EPOLLOUT : input
        }
        if shouldDrop {
            dropConn(slot)
            return
        }
        if shouldLinkIdle {
            linkIdle(slot)
        } else if hasUnsent {
            unlinkIdle(slot)
        }
        if let mask = maskChange { _ = ctl(Sys.EPOLL_CTL_MOD, slots[s].fd, mask, UInt64(slot)) }
    }
}

extension Reactor {
    private static let tokenListener = UInt64.max - 1
    private static let idleNone = UInt32.max
    private static let epochClosed = UInt32.max

    /// A connection: its socket and buffers (owned, so the slot is noncopyable), and the Rust's flags.
    struct ClientSlot: ~Copyable {
        var fd: Int32
        var epoch: UInt32 = 0
        var rx = ByteBuffer()
        var tx = ByteBuffer()
        var txOff = 0
        var inFlight = false
        var closeOnDone = false
        /// The peer is done sending: once what it sent is answered, the connection closes.
        var eofSeen = false
        var pollingOut = false
        var continueSent = false
        var reused = false
        var inIdleLRU = false
        var idlePrev = idleNone
        var idleNext = idleNone
    }
}

/// HTTP/1.1: the response head, and (below) request parsing.
enum HTTP {
    private static let limitHead = 64 * 1024
    private static let limitBody = 1024 * 1024

    fileprivate static func reasonPhrase(_ status: UInt16) -> StaticString {
        switch status {
        case 100: "100 Continue"
        case 200: "200 OK"
        case 201: "201 Created"
        case 204: "204 No Content"
        case 400: "400 Bad Request"
        case 401: "401 Unauthorized"
        case 403: "403 Forbidden"
        case 404: "404 Not Found"
        case 413: "413 Payload Too Large"
        case 422: "422 Unprocessable Entity"
        case 431: "431 Request Header Fields Too Large"
        default: "500 Internal Server Error"
        }
    }

    /// The response head (status line, Content-Type, Content-Length, Connection) into `out`; returns its length.
    fileprivate static func formatHeader(into out: inout MutableSpan<UInt8>, _ status: UInt16, _ length: Int, _ close: Bool) -> Int {
        var n = 0
        if status == 200 && !close {
            n = put(&out, n, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ")
            n = putDecimal(&out, n, length)
            n = put(&out, n, "\r\n\r\n")
        } else if status == 204 {
            n = put(&out, n, close ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" : "HTTP/1.1 204 No Content\r\n\r\n")
        } else {
            n = put(&out, n, "HTTP/1.1 ")
            n = put(&out, n, reasonPhrase(status))
            n = put(&out, n, "\r\nContent-Type: application/json\r\nContent-Length: ")
            n = putDecimal(&out, n, length)
            n = put(&out, n, close ? "\r\nConnection: close\r\n\r\n" : "\r\n\r\n")
        }
        return n
    }

    @inline(__always) private static func put(_ out: inout MutableSpan<UInt8>, _ at: Int, _ text: StaticString) -> Int {
        let bytes = text.utf8Start
        for i in 0..<text.utf8CodeUnitCount { out[at + i] = bytes[i] }
        return at + text.utf8CodeUnitCount
    }

    @inline(__always) private static func putDecimal(_ out: inout MutableSpan<UInt8>, _ at: Int, _ value: Int) -> Int {
        var digits = 1
        var v = value
        while v >= 10 {
            v /= 10
            digits += 1
        }
        v = value
        for i in stride(from: at + digits - 1, through: at, by: -1) {
            out[i] = 0x30 + UInt8(v % 10)
            v /= 10
        }
        return at + digits
    }

    enum ParseOutcome: ~Copyable {
        case complete(consumed: Int, closeAfter: Bool, dispatch: Router.Dispatch)
        case incomplete(sendContinue: Bool)
        case reject(UInt16)
    }
}

// ---------- HTTP/1.1 parsing ----------

extension HTTP {
    @inline(__always) private static func trimOWS(_ s: Span<UInt8>) -> Span<UInt8> {
        var a = 0
        var b = s.count
        while a < b && (s[a] == 0x20 || s[a] == 0x09) { a += 1 }
        while b > a && (s[b - 1] == 0x20 || s[b - 1] == 0x09) { b -= 1 }
        return s.extracting(a..<b)
    }

    @inline(__always) private static func parseUsize(_ s: Span<UInt8>) -> Int? {
        guard s.count > 0 else { return nil }
        var value = 0
        for i in 0..<s.count {
            let b = s[i]
            guard (0x30...0x39).contains(b) else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (v, o2) = m.addingReportingOverflow(Int(b - 0x30))
            if o1 || o2 { return nil }
            value = v
        }
        return value
    }

    @inline(__always) private static func isTokenName(_ s: Span<UInt8>) -> Bool {
        guard s.count > 0 else { return false }
        for i in 0..<s.count {
            let b = s[i]
            if b <= 0x20 || b >= 0x7F { return false }
            switch b {
            case 0x28, 0x29, 0x3C, 0x3E, 0x40, 0x2C, 0x3B, 0x3A, 0x5C, 0x22, 0x2F, 0x5B, 0x5D, 0x3F, 0x3D, 0x7B, 0x7D: return false
            default: continue
            }
        }
        return true
    }

    @inline(__always) private static func equalsIgnoringCase(_ s: Span<UInt8>, _ lower: StaticString) -> Bool {
        guard s.count == lower.utf8CodeUnitCount else { return false }
        let l = lower.utf8Start
        for i in 0..<s.count {
            var c = s[i]
            if (0x41...0x5A).contains(c) { c |= 0x20 }
            if c != l[i] { return false }
        }
        return true
    }

    static func parseRequest(_ signer: TokenSigner, _ buf: Span<UInt8>, _ addr: ReplyAddr) -> ParseOutcome {
        guard let reqLineEnd = Bytes.findCRLF(buf) else {
            return buf.count > limitHead ? .reject(431) : .incomplete(sendContinue: false)
        }
        let reqLine = buf.extracting(0..<reqLineEnd)
        guard let sp1 = Bytes.find(reqLine, 0x20) else { return .reject(400) }
        let method = reqLine.extracting(0..<sp1)
        guard isTokenName(method) else { return .reject(400) }
        guard let sp2 = Bytes.find(reqLine, 0x20, from: sp1 + 1) else { return .reject(400) }
        let rawTarget = reqLine.extracting((sp1 + 1)..<sp2)
        guard rawTarget.count > 0 else { return .reject(400) }
        for i in 0..<rawTarget.count where rawTarget[i] <= 0x20 || rawTarget[i] == 0x7F { return .reject(400) }
        let version = reqLine.extracting((sp2 + 1)..<reqLine.count)
        let isHTTP10: Bool
        if Bytes.equal(version, "HTTP/1.1") {
            isHTTP10 = false
        } else if Bytes.equal(version, "HTTP/1.0") {
            isHTTP10 = true
        } else {
            return .reject(400)
        }

        var contentLength: Int?
        var isChunked = false
        var authRange: Range<Int>?
        var keepAlive = !isHTTP10
        var expect100 = false

        var pos = reqLineEnd + 2
        var headEnd = 0
        while true {
            guard let lineEnd = Bytes.findCRLF(buf, from: pos) else {
                return buf.count > limitHead ? .reject(431) : .incomplete(sendContinue: false)
            }
            if lineEnd + 2 > limitHead { return .reject(431) }
            if lineEnd == pos {
                headEnd = pos + 2
                break
            }
            let line = buf.extracting(pos..<lineEnd)
            let lineStart = pos
            pos = lineEnd + 2
            guard let colon = Bytes.find(line, 0x3A) else { return .reject(400) }
            let name = line.extracting(0..<colon)
            guard isTokenName(name) else { return .reject(400) }
            let value = trimOWS(line.extracting((colon + 1)..<line.count))
            switch name.count {
            case 13 where equalsIgnoringCase(name, "authorization"):
                // The value's place in `buf` (after the leading whitespace trimOWS skipped), so the request borrows it.
                var a = colon + 1
                while a < line.count && (line[a] == 0x20 || line[a] == 0x09) { a += 1 }
                let valueStart = lineStart + a
                authRange = valueStart..<(valueStart + value.count)
            case 14 where equalsIgnoringCase(name, "content-length"):
                guard let n = parseUsize(value) else { return .reject(400) }
                if let prev = contentLength, prev != n { return .reject(400) }
                contentLength = n
            case 10 where equalsIgnoringCase(name, "connection"):
                if equalsIgnoringCase(value, "close") {
                    keepAlive = false
                } else if equalsIgnoringCase(value, "keep-alive") {
                    keepAlive = true
                }
            case 17 where equalsIgnoringCase(name, "transfer-encoding"):
                isChunked = equalsIgnoringCase(value, "chunked")
                if !isChunked { return .reject(400) }
            case 6 where equalsIgnoringCase(name, "expect"):
                expect100 = equalsIgnoringCase(value, "100-continue")
            default:
                break
            }
        }

        if isChunked && contentLength != nil { return .reject(400) }

        let qpos = Bytes.find(rawTarget, 0x3F) ?? rawTarget.count
        let path = rawTarget.extracting(0..<qpos)
        let query = rawTarget.extracting(min(qpos + 1, rawTarget.count)..<rawTarget.count)
        var auth: Span<UInt8>? = nil
        if let authRange { auth = buf.extracting(authRange) }

        if isChunked {
            switch decodeChunkedBody(buf.extracting(headEnd..<buf.count)) {
            case .complete(let decoded, let used):
                if decoded.count > limitBody { return .reject(413) }
                let req = Request(method: method, path: path, query: query, auth: auth, body: decoded.span)
                let dispatch = Router.route(signer, req, addr)
                return .complete(consumed: headEnd + used, closeAfter: !keepAlive, dispatch: dispatch)
            case .incomplete:
                if buf.count - headEnd > limitBody + 64 * 1024 { return .reject(413) }
                return .incomplete(sendContinue: expect100)
            case .malformed:
                return .reject(400)
            }
        }
        let cl = contentLength ?? 0
        if cl > limitBody { return .reject(413) }
        if buf.count < headEnd + cl { return .incomplete(sendContinue: expect100) }
        let req = Request(method: method, path: path, query: query, auth: auth, body: buf.extracting(headEnd..<(headEnd + cl)))
        let dispatch = Router.route(signer, req, addr)
        return .complete(consumed: headEnd + cl, closeAfter: !keepAlive, dispatch: dispatch)
    }

    private enum ChunkResult {
        case complete([UInt8], Int)
        case incomplete
        case malformed
    }

    private static func decodeChunkedBody(_ src: Span<UInt8>) -> ChunkResult {
        var out: [UInt8] = []
        var pos = 0
        while true {
            guard let crlf = Bytes.findCRLF(src, from: pos) else { return .incomplete }
            let line = src.extracting(pos..<crlf)
            let hexPart = line.extracting(0..<(Bytes.find(line, 0x3B) ?? line.count))
            guard Bytes.isValidUTF8(hexPart) else { return .malformed }
            let text = hexPart.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
                .trimmingCharacters(in: " \t")
            guard let chunkLen = Int(text, radix: 16), chunkLen >= 0 else { return .malformed }
            pos = crlf + 2
            if chunkLen == 0 {
                while true {
                    guard let endLine = Bytes.findCRLF(src, from: pos) else { return .incomplete }
                    let empty = endLine == pos
                    pos = endLine + 2
                    if empty { return .complete(out, pos) }
                }
            }
            if chunkLen > limitBody || out.count + chunkLen > limitBody {
                return .complete([UInt8](repeating: 0, count: limitBody + 1), pos)
            }
            if src.count < pos + chunkLen + 2 { return .incomplete }
            src.extracting(pos..<(pos + chunkLen)).withUnsafeBufferPointer { out.append(contentsOf: $0) }
            if src[pos + chunkLen] != 0x0D || src[pos + chunkLen + 1] != 0x0A { return .malformed }
            pos += chunkLen + 2
        }
    }
}

extension String {
    /// Rust's `str::trim` for the few characters chunk sizes may carry.
    fileprivate func trimmingCharacters(in set: String) -> String {
        let chars = Set(set)
        return String(self.drop { chars.contains($0) }.reversed().drop { chars.contains($0) }.reversed())
    }
}
