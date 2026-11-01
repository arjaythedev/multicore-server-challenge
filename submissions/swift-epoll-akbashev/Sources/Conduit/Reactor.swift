// reactor.rs: an HTTP/1.1 reactor on its own SO_REUSEPORT listener, with a file descriptor table of its own. It is an
// actor on its own event loop: the connection table is plain actor state, touched only by this actor's thread. Each
// turn it takes the ready events off its epoll instance, parses and routes what arrived, and hands the tick's work
// to the scheduler in one message (a child task of the reactor's own task group). Replies arrive as `deliver`
// messages from the lanes, one per batch, and go out with writev.
import Glibc

private let tokenListener = UInt64.max - 1
private let idleNone = UInt32.max
private let epochClosed = UInt32.max
private let limitHead = 64 * 1024
private let limitBody = 1024 * 1024

/// A connection: its socket and buffers (owned, so the slot is noncopyable), and the Rust's flags.
struct ClientSlot: ~Copyable {
    var fd: Int32
    var epoch: UInt32 = 0
    var rx = ByteBuffer()
    var tx = ByteBuffer()
    var txOff = 0
    var inFlight = false
    var closeOnDone = false
    var eofSeen = false
    var pollingOut = false
    var continueSent = false
    var reused = false
    var inIdleLRU = false
    var idlePrev = idleNone
    var idleNext = idleNone
}

private func reasonPhrase(_ status: UInt16) -> StaticString {
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
private func formatHeader(_ out: UnsafeMutableRawBufferPointer, _ status: UInt16, _ length: Int, _ close: Bool) -> Int {
    var n = 0
    func put(_ s: StaticString) {
        (out.baseAddress! + n).copyMemory(from: s.utf8Start, byteCount: s.utf8CodeUnitCount)
        n += s.utf8CodeUnitCount
    }
    func putLength() {
        var digits = 1
        var v = length
        while v >= 10 {
            v /= 10
            digits += 1
        }
        v = length
        for i in stride(from: n + digits - 1, through: n, by: -1) {
            out[i] = 0x30 + UInt8(v % 10)
            v /= 10
        }
        n += digits
    }
    if status == 200 && !close {
        put("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ")
        putLength()
        put("\r\n\r\n")
    } else if status == 204 {
        put(close ? "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n" : "HTTP/1.1 204 No Content\r\n\r\n")
    } else {
        put("HTTP/1.1 ")
        put(reasonPhrase(status))
        put("\r\nContent-Type: application/json\r\nContent-Length: ")
        putLength()
        put(close ? "\r\nConnection: close\r\n\r\n" : "\r\n\r\n")
    }
    return n
}

enum ParseOutcome: ~Copyable {
    case complete(consumed: Int, closeAfter: Bool, dispatch: Dispatch)
    case incomplete(sendContinue: Bool)
    case reject(UInt16)
}

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
    private var pipelinedSlots: [UInt32] = []
    private var activeConns = 0
    private var idleHead = idleNone
    private var idleTail = idleNone
    private let events: UnsafeMutableRawPointer
    private let maxEvents = 1024
    /// What this tick routed, for the scheduler.
    private var pending = Submission()

    init(index: Int, loop: EventLoop, signer: TokenSigner, scheduler: Scheduler, host: String, port: UInt16, fdBudget: Int) {
        self.index = UInt16(index)
        self.loop = loop
        self.signer = signer
        self.scheduler = scheduler
        self.host = host
        self.port = port
        self.fdBudget = max(fdBudget, 256)
        events = .allocate(byteCount: 1024 * Sys.epollEventStride, alignment: 8)
        freeSlots.reserveCapacity(4096)
        pipelinedSlots.reserveCapacity(256)
    }

    @inline(__always) private func ctl(_ op: Int32, _ fd: Int32, _ events: UInt32, _ token: UInt64) -> Bool {
        EventLoop.control(loop.epollFD, op, fd, events, token) == 0
    }

    // ---------- the loop ----------

    func run() async {
        unshareFiles()
        do {
            listenFD = try bindListener(host: host, port: port)
        } catch {
            fatalError("failed to bind listener: \(error)")
        }
        guard ctl(Sys.EPOLL_CTL_ADD, listenFD, Sys.EPOLLIN, tokenListener) else { fatalError("epoll_ctl listener: \(errno)") }
        await withDiscardingTaskGroup { group in
            while true {
                // One epoll_wait per tick, as the Rust's loop: it blocks here, on this actor's own thread, until a
                // socket is ready or a message (a lane's `deliver`) is queued for the actor.
                let (n, messagesWaiting) = loop.waitForEvents(events, Int32(maxEvents))
                for i in 0..<n {
                    let base = i * Sys.epollEventStride
                    let flags = events.loadUnaligned(fromByteOffset: base, as: UInt32.self)
                    let token = events.loadUnaligned(fromByteOffset: base + Sys.epollDataOffset, as: UInt64.self)
                    switch token {
                    case tokenListener: acceptReady()
                    default:
                        let slot = UInt32(truncatingIfNeeded: token)
                        if flags & Sys.EPOLLOUT != 0 { flushTx(slot) }
                        if flags & (Sys.EPOLLIN | Sys.EPOLLHUP | Sys.EPOLLERR | Sys.EPOLLRDHUP) != 0 { readReady(slot, flags) }
                    }
                }
                submitPending(&group)
                // Let the queued messages run (jobs on this same thread: Task.yield re-enqueues on the actor's executor),
                // then carry on.
                if messagesWaiting { await Task.yield() }
            }
        }
    }

    /// Hands this tick's work to the scheduler: one message, a child task that starts on the scheduler's loop.
    private func submitPending(_ group: inout DiscardingTaskGroup) {
        guard !pending.isEmpty else { return }
        let work = pending
        pending = Submission()
        let scheduler = scheduler
        group.addTask(executorPreference: scheduler.loop) { await scheduler.submit(work) }
    }

    /// A batch of replies from a lane (flush_outbox).
    func deliver(_ replies: [OutgoingReply]) {
        pipelinedSlots.removeAll(keepingCapacity: true)
        for rep in replies {
            let s = Int(rep.addr.slot)
            guard s < slots.count, slots[s].fd >= 0, slots[s].epoch == rep.addr.epoch, slots[s].inFlight else { continue }
            let hasBufferedRx = !slots[s].rx.isEmpty
            rep.body.withUnsafeBytes { writeResponse(rep.addr.slot, rep.status, $0) }
            if hasBufferedRx { pipelinedSlots.append(rep.addr.slot) }
        }
        for slot in pipelinedSlots { drainRxBuf(slot) }
        pipelinedSlots.removeAll(keepingCapacity: true)
        // Pipelined requests routed here go out with the tick that resumes after this message.
    }

    // ---------- connections ----------

    private func linkIdle(_ slot: UInt32) {
        let s = Int(slot)
        if slots[s].inIdleLRU || slots[s].fd < 0 { return }
        slots[s].inIdleLRU = true
        slots[s].idlePrev = idleTail
        slots[s].idleNext = idleNone
        if idleTail != idleNone {
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
        slots[s].idlePrev = idleNone
        slots[s].idleNext = idleNone
        if prev != idleNone { slots[Int(prev)].idleNext = next } else { idleHead = next }
        if next != idleNone { slots[Int(next)].idlePrev = prev } else { idleTail = prev }
    }

    private func acceptReady() {
        while true {
            while activeConns >= fdBudget && idleHead != idleNone { dropConn(idleHead) }
            let fd = sys_accept4(listenFD, nil, nil, Sys.SOCK_NONBLOCK | Sys.SOCK_CLOEXEC)
            if fd < 0 {
                switch errno {
                case Sys.EAGAIN: return
                case Sys.EINTR, Sys.ECONNABORTED: continue
                case Sys.EMFILE, Sys.ENFILE:
                    if idleHead != idleNone {
                        dropConn(idleHead)
                        continue
                    }
                    return
                default: return
                }
            }
            setNoDelay(fd)
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
                slots[s].idlePrev = idleNone
                slots[s].idleNext = idleNone
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
        slots[s].epoch = nextEpoch == epochClosed ? 0 : nextEpoch
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
                dropConn(slot)
                return
            }
            // Parse straight out of the scratch buffer when the connection has nothing left over.
            if canDirectParse && n < 256 * 1024 {
                let addr = ReplyAddr(worker: index, slot: slot, epoch: slots[s].epoch)
                let outcome = parseOneHTTP(signer, scratch.span, addr)
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

    /// Writes an immediate answer, or queues the work for this tick's submission. Whether it was immediate.
    private func handle(_ dispatch: consuming Dispatch, _ slot: UInt32) -> Bool {
        switch consume dispatch {
        case .immediate(let status, let body):
            body.withBytes { writeResponse(slot, status, $0) }
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
                    if !slots[s].inFlight && slots[s].txOff >= slots[s].tx.count && slots[s].reused { linkIdle(slot) }
                }
                return
            }
            let addr = ReplyAddr(worker: index, slot: slot, epoch: slots[s].epoch)
            let outcome = parseOneHTTP(signer, slots[s].rx.span, addr)
            switch consume outcome {
            case .complete(let consumed, let closeAfter, let dispatch):
                slots[s].continueSent = false
                slots[s].closeOnDone = closeAfter
                slots[s].inFlight = true
                if consumed == slots[s].rx.count { slots[s].rx.release() } else { slots[s].rx.removeFirst(consumed) }
                if !handle(dispatch, slot) { return }
            case .incomplete(let sendContinue):
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
        makeErrorJSON(reasonPhrase(status)).withBytes { writeResponse(slot, status, $0) }
    }

    // ---------- writing ----------

    private func writeResponse(_ slot: UInt32, _ status: UInt16, _ body: UnsafeRawBufferPointer) {
        let s = Int(slot)
        slots[s].inFlight = false
        slots[s].reused = true
        let close = slots[s].closeOnDone
        // The header in a stack buffer, as the Rust's `[0u8; 160]`: no allocation per response.
        withUnsafeTemporaryAllocation(byteCount: 192, alignment: 8) { raw in
            let header = UnsafeRawBufferPointer(rebasing: raw[0..<formatHeader(raw, status, body.count, close)])
            send(slot, header, body)
        }
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
        let shouldDrop = !hasUnsent && !inFlight && (slots[s].closeOnDone || slots[s].eofSeen)
        let shouldLinkIdle = !shouldDrop && !hasUnsent && !inFlight && slots[s].rx.isEmpty && slots[s].reused
        var maskChange: UInt32?
        if !shouldDrop && hasUnsent != slots[s].pollingOut {
            slots[s].pollingOut = hasUnsent
            maskChange = hasUnsent ? Sys.EPOLLIN | Sys.EPOLLOUT | Sys.EPOLLRDHUP : Sys.EPOLLIN | Sys.EPOLLRDHUP
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

// ---------- HTTP/1.1 parsing ----------

@inline(__always) private func trimOWS(_ s: Span<UInt8>) -> Span<UInt8> {
    var a = 0
    var b = s.count
    while a < b && (s[a] == 0x20 || s[a] == 0x09) { a += 1 }
    while b > a && (s[b - 1] == 0x20 || s[b - 1] == 0x09) { b -= 1 }
    return s.extracting(a..<b)
}

@inline(__always) private func parseUsize(_ s: Span<UInt8>) -> Int? {
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

@inline(__always) private func isTokenName(_ s: Span<UInt8>) -> Bool {
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

@inline(__always) private func equalsIgnoringCase(_ s: Span<UInt8>, _ lower: StaticString) -> Bool {
    guard s.count == lower.utf8CodeUnitCount else { return false }
    let l = lower.utf8Start
    for i in 0..<s.count {
        var c = s[i]
        if (0x41...0x5A).contains(c) { c |= 0x20 }
        if c != l[i] { return false }
    }
    return true
}

func parseOneHTTP(_ signer: TokenSigner, _ buf: Span<UInt8>, _ addr: ReplyAddr) -> ParseOutcome {
    guard let reqLineEnd = findCRLF(buf) else {
        return buf.count > limitHead ? .reject(431) : .incomplete(sendContinue: false)
    }
    let reqLine = buf.extracting(0..<reqLineEnd)
    guard let sp1 = findByte(reqLine, 0x20) else { return .reject(400) }
    let method = reqLine.extracting(0..<sp1)
    guard isTokenName(method) else { return .reject(400) }
    guard let sp2 = findByte(reqLine, 0x20, from: sp1 + 1) else { return .reject(400) }
    let rawTarget = reqLine.extracting((sp1 + 1)..<sp2)
    guard rawTarget.count > 0 else { return .reject(400) }
    for i in 0..<rawTarget.count where rawTarget[i] <= 0x20 || rawTarget[i] == 0x7F { return .reject(400) }
    let version = reqLine.extracting((sp2 + 1)..<reqLine.count)
    let isHTTP10: Bool
    if spanEqual(version, "HTTP/1.1") {
        isHTTP10 = false
    } else if spanEqual(version, "HTTP/1.0") {
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
        guard let lineEnd = findCRLF(buf, from: pos) else {
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
        guard let colon = findByte(line, 0x3A) else { return .reject(400) }
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

    let qpos = findByte(rawTarget, 0x3F) ?? rawTarget.count
    let path = rawTarget.extracting(0..<qpos)
    let query = rawTarget.extracting(min(qpos + 1, rawTarget.count)..<rawTarget.count)
    var auth: Span<UInt8>? = nil
    if let authRange { auth = buf.extracting(authRange) }

    if isChunked {
        switch decodeChunkedBody(buf.extracting(headEnd..<buf.count)) {
        case .complete(let decoded, let used):
            if decoded.count > limitBody { return .reject(413) }
            let req = HttpReq(method: method, path: path, query: query, auth: auth, body: decoded.span)
            let dispatch = routeRequest(signer, req, addr)
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
    let req = HttpReq(method: method, path: path, query: query, auth: auth, body: buf.extracting(headEnd..<(headEnd + cl)))
    let dispatch = routeRequest(signer, req, addr)
    return .complete(consumed: headEnd + cl, closeAfter: !keepAlive, dispatch: dispatch)
}

private enum ChunkResult {
    case complete([UInt8], Int)
    case incomplete
    case malformed
}

private func decodeChunkedBody(_ src: Span<UInt8>) -> ChunkResult {
    var out: [UInt8] = []
    var pos = 0
    while true {
        guard let crlf = findCRLF(src, from: pos) else { return .incomplete }
        let line = src.extracting(pos..<crlf)
        let hexPart = line.extracting(0..<(findByte(line, 0x3B) ?? line.count))
        guard isValidUTF8(hexPart) else { return .malformed }
        let text = hexPart.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
            .trimmingCharacters(in: " \t")
        guard let chunkLen = Int(text, radix: 16), chunkLen >= 0 else { return .malformed }
        pos = crlf + 2
        if chunkLen == 0 {
            while true {
                guard let endLine = findCRLF(src, from: pos) else { return .incomplete }
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

extension String {
    /// Rust's `str::trim` for the few characters chunk sizes may carry.
    fileprivate func trimmingCharacters(in set: String) -> String {
        let chars = Set(set)
        return String(self.drop { chars.contains($0) }.reversed().drop { chars.contains($0) }.reversed())
    }
}
