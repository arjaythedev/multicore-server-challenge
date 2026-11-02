// The HTTP server, on the loops (Loop.swift). On Linux every loop listens on the port with a socket of its own
// (SO_REUSEPORT, so the kernel spreads new connections over them); on macOS one listener hands them out in turn. A
// connection stays on its loop for life: its bytes are read there, each request is parsed (HTTP.swift) and routed
// (Routes.swift) there, and its response is written there. A batched read is a task pinned to the connection's loop;
// every other handler runs as a child task of the server, in one task group.
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// What one loop's connections share: touched only on that loop.
final class LoopState: @unchecked Sendable {
    let loop: Loop
    let outbox: ReadOutbox
    fileprivate var connections: [HTTPConnection] = []
    /// Every read of a connection with nothing pending lands here, and is parsed in place; only what is left over (the
    /// start of a request, or requests behind the one in flight) is copied to the connection's own `pending`.
    fileprivate var receive = Bytes(capacity: 65536)
    fileprivate var listener: Listener?

    init(loop: Loop, reads: ReadBatcher) {
        self.loop = loop
        outbox = ReadOutbox(batcher: reads, loop: loop)
    }
}

final class HTTPServer: Service {
    let app: App
    private let host: String
    private let port: Int
    private let jobs: AsyncStream<@Sendable () async -> Void>
    private let submit: AsyncStream<@Sendable () async -> Void>.Continuation
    fileprivate let loops: [LoopState]
    /// A batched read is a task on its connection's loop; READ_TASKS=0: a callback instead.
    let readTasks = ProcessInfo.processInfo.environment["READ_TASKS"] != "0"

    init(app: App, host: String, port: Int) {
        self.app = app
        self.host = host
        self.port = port
        (jobs, submit) = AsyncStream.makeStream()
        loops = Loop.all.map { LoopState(loop: $0, reads: app.reads) }
    }

    /// Runs `job` as a child task of the server's task group; false once the server is shutting down.
    func spawn(_ job: @escaping @Sendable () async -> Void) -> Bool {
        if case .enqueued = submit.yield(job) { return true }
        return false
    }

    func run() async throws {
        #if os(Linux)
        let listening = loops
        #else
        let listening = [loops[0]]
        #endif
        for state in listening {
            try await withCheckedThrowingContinuation { (started: CheckedContinuation<Void, any Error>) in
                state.loop.execute {
                    do {
                        // Front: direct, so these sockets take every user's connection: a backlog deep enough for a
                        // ramp (the kernel caps it at net.core.somaxconn, 65535 on the box).
                        let fd = try Sockets.listen(host: self.host, port: self.port, reusePort: listening.count > 1, backlog: 65535)
                        let listener = Listener(fd: fd, server: self, state: state)
                        listener.token = state.loop.register(fd, listener, readable: true, writable: false)
                        state.listener = listener
                        started.resume()
                    } catch {
                        started.resume(throwing: error)
                    }
                }
            }
        }
        for state in loops {
            state.loop.execute { state.loop.every(HTTPConnection.idleCheck) { HTTPConnection.closeIdle(on: state) } }
        }
        App.logger.info("listening on \(host):\(port)")

        // On shutdown: stop accepting, then wait for the handlers still running. Open connections stay until exit.
        await withDiscardingTaskGroup { group in
            group.addTask {
                try? await gracefulShutdown()
                for state in listening { state.loop.execute { state.listener?.close() } }
                self.submit.finish()
            }
            for await job in jobs {
                group.addTask { await job() }
            }
        }
    }

    /// Takes on an accepted connection, on the loop it will live on.
    fileprivate func adopt(_ fd: Int32, on state: LoopState) {
        let connection = HTTPConnection(fd: fd, server: self, state: state)
        connection.index = state.connections.count
        state.connections.append(connection)
        connection.token = state.loop.register(fd, connection, readable: true, writable: false)
    }

    fileprivate func forget(_ connection: HTTPConnection, on state: LoopState) {
        let i = connection.index
        let last = state.connections.removeLast()
        if i < state.connections.count {
            state.connections[i] = last
            last.index = i
        }
    }
}

/// A listening socket, on its loop.
fileprivate final class Listener: LoopSource {
    private let fd: Int32
    private let server: HTTPServer
    private let state: LoopState
    var token: LoopToken?

    init(fd: Int32, server: HTTPServer, state: LoopState) {
        self.fd = fd
        self.server = server
        self.state = state
    }

    func ready(readable: Bool, writable: Bool) {
        // A bounded number per turn, so a burst of new connections doesn't hold up the requests of open ones.
        for _ in 0..<64 {
            guard let fd = Sockets.accept(fd) else { return }
            #if os(Linux)
            server.adopt(fd, on: state)
            #else
            let target = server.loops[Loop.next().index]
            let server = server
            target.loop.execute { server.adopt(fd, on: target) }
            #endif
        }
    }

    func close() {
        if let token { state.loop.unregister(token) }
        token = nil
        closeDescriptor(fd)
        state.listener = nil
    }
}

/// Where a request's response goes: its connection, on that connection's loop, and which request it answers.
struct ReplyTo: Sendable {
    let connection: LoopBound<HTTPConnection>
    let request: UInt32
}

/// One connection, on its loop. Requests are answered one at a time, in order; bytes of requests pipelined behind the
/// one in flight wait in `pending`. Idle connections hold no buffer.
final class HTTPConnection: LoopSource {
    /// SPEC.md: keep idle connections open at least 65 s. A connection is closed at the first check, every 75 s, that
    /// finds it idle since the check before (so after 75 to 150 s); a request costs a counter increment, not a clock read.
    fileprivate static let idleCheck: Duration = .seconds(75)
    private static let continueHead: JSONBytes = {
        var out = JSONWriter(capacity: 32)
        out.raw("HTTP/1.1 100 Continue\r\n\r\n")
        return out.finish()
    }()

    private let fd: Int32
    private let server: HTTPServer
    private let state: LoopState
    fileprivate var token: LoopToken?
    /// Its place in its loop's `connections`.
    fileprivate var index = 0
    private var open = true
    /// Received bytes not yet consumed: the start of a request, or requests behind the one in flight. Empty, and
    /// holding no memory, most of the time.
    private var pending = Bytes()
    /// Response bytes the socket hasn't taken yet, oldest first.
    private var unsent: [Outgoing] = []
    /// Close once `unsent` is out (the response said `Connection: close`).
    private var closeWhenSent = false
    /// A request is being answered; nothing more is parsed until its response is written.
    private var busy = false
    private var keepAlive = true
    private var headRequest = false
    private var sentContinue = false
    /// Numbers requests, so a late reply can't answer a later request.
    private var sequence: UInt32 = 0
    /// GET /api/user's token, echoed back in its response.
    private var userToken: String?
    /// The status an article read answers with: 201 for the article just created.
    private var articleStatus: Status = .ok
    private var requestsAtLastCheck: UInt32 = 0

    fileprivate init(fd: Int32, server: HTTPServer, state: LoopState) {
        self.fd = fd
        self.server = server
        self.state = state
    }

    private var loop: Loop { state.loop }

    fileprivate static func closeIdle(on state: LoopState) {
        for connection in state.connections where !connection.busy {
            if connection.sequence == connection.requestsAtLastCheck {
                connection.close()
            } else {
                connection.requestsAtLastCheck = connection.sequence
            }
        }
    }

    func ready(readable: Bool, writable: Bool) {
        if writable { flush() }
        if readable, open { receive() }
    }

    private func receive() {
        if pending.isEmpty {
            state.receive.clear()
            let n = state.receive.read(from: fd, minimum: 4096).count
            guard arrived(n) else { return }
            let consumed = state.receive.withSpan { parse($0) }
            if open, !closeWhenSent, consumed < state.receive.count {
                pending.append(state.receive, from: consumed, count: state.receive.count - consumed)
            }
        } else {
            let n = pending.read(from: fd, minimum: 4096).count
            guard arrived(n) else { return }
            // A client that keeps sending while its request is answered gets cut off beyond one maximal request.
            if busy, pending.count > maxHead + maxBody { return close() }
            process()
        }
    }

    /// Whether a read brought bytes; a connection whose read failed or reached end of stream is closed.
    private func arrived(_ n: Int) -> Bool {
        if n > 0 { return true }
        if n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return false }
        close() // an error, or the client closed its side
        return false
    }

    /// The connection is done. Its `pending` bytes stay until the connection object goes, since a parse may be
    /// reading them as it closes.
    private func close() {
        guard open else { return }
        open = false
        if let token { loop.unregister(token) }
        token = nil
        closeDescriptor(fd)
        server.forget(self, on: state)
        unsent = []
    }

    // ---------- requests ----------

    /// Parses and dispatches the requests `pending` holds: after a read, or once the request in flight is answered.
    private func process() {
        let consumed = pending.withSpan { parse($0) }
        guard open else { return }
        pending.consume(consumed)
        if pending.isEmpty { pending.release() }
    }

    /// Parses and dispatches requests from `bytes` until one has to wait (for the rest of its bytes, or for its
    /// answer); returns how many bytes that used.
    private func parse(_ bytes: Span<UInt8>) -> Int {
        var consumed = 0
        while open, !busy, consumed < bytes.count {
            let rest = bytes.extracting(consumed..<bytes.count)
            let head: RequestHead
            switch parseHead(rest) {
            case .incomplete: return consumed
            case .invalid(let status):
                fail(status)
                return bytes.count
            case .complete(let parsed): head = parsed
            }

            var body = Data()
            let length: Int
            if head.chunked {
                switch parseChunked(rest, from: head.length) {
                case .incomplete:
                    expectingBody(head)
                    return consumed
                case .invalid(let status):
                    fail(status)
                    return bytes.count
                case .complete(let pieces, let size, let chunkedLength):
                    body.reserveCapacity(size)
                    for piece in pieces { rest.extracting(piece).withUnsafeBytes { body.append(contentsOf: $0) } }
                    length = head.length + chunkedLength
                }
            } else {
                guard head.contentLength <= maxBody else {
                    fail(.contentTooLarge)
                    return bytes.count
                }
                length = head.length + head.contentLength
                guard rest.count >= length else {
                    expectingBody(head)
                    return consumed
                }
                // A copy of its own, so a handler that holds on to it holds on to nothing of the connection's.
                if head.contentLength > 0 { rest.extracting(head.length..<length).withUnsafeBytes { body = Data($0) } }
            }

            busy = true
            keepAlive = head.keepAlive
            headRequest = head.method == .head
            sentContinue = false
            sequence &+= 1

            let target = rest.extracting(head.target)
            var pathEnd = 0
            while pathEnd < target.count, target[pathEnd] != 0x3F { pathEnd += 1 } // ?
            let query = target.extracting(min(pathEnd + 1, target.count)..<target.count)
            let dispatch = server.app.dispatch(head.method, path: target.extracting(0..<pathEnd), query: query,
                                               authorization: rest.extracting(head.authorization), body: body)
            consumed += length

            switch dispatch {
            case .now(let response):
                write(response)
            case .read(let read, let viewer, let token):
                userToken = token
                submit(read, viewer: viewer)
            case .later(let handler):
                let to = replyTo()
                let spawned = server.spawn {
                    let answer = await handler()
                    to.connection.loop.execute { to.connection.value.answer(answer, request: to.request) }
                }
                if !spawned { write(errorResponse(.serviceUnavailable, "shutting down")) }
            }
        }
        return consumed
    }

    private func submit(_ read: Read, viewer: Int64) {
        if server.readTasks {
            // The read as a task pinned to this connection's loop: it queues the read, awaits its result and writes
            // the response, all without leaving the loop.
            let to = replyTo()
            let loop = loop
            let outbox = LoopBound(state.outbox, loop: loop)
            Task(executorPreference: loop) {
                let result: Result<ReadResult, any Error>
                do {
                    result = .success(try await withCheckedThrowingContinuation { continuation in
                        outbox.value.submit(read, viewer: viewer, reply: .task(continuation, on: loop))
                    })
                } catch {
                    result = .failure(error)
                }
                to.connection.value.deliver(result, request: to.request)
            }
        } else {
            state.outbox.submit(read, viewer: viewer, reply: .connection(replyTo()))
        }
    }

    private func replyTo() -> ReplyTo {
        ReplyTo(connection: LoopBound(self, loop: loop), request: sequence)
    }

    /// The head is in, its body isn't yet. A client that sent `Expect: 100-continue` is waiting to be told to send it.
    private func expectingBody(_ head: RequestHead) {
        guard head.expectContinue, !sentContinue else { return }
        sentContinue = true
        send(Outgoing(Self.continueHead))
    }

    /// A request that can't be read: answered, and the connection closed after it, since where the next one starts
    /// is unknown.
    private func fail(_ status: Status) {
        busy = true
        keepAlive = false
        headRequest = false
        let message = switch status {
        case .headerFieldsTooLarge: "request head too large"
        case .contentTooLarge: "request body too large"
        case .notImplemented: "unsupported transfer coding"
        default: "bad request"
        }
        write(errorResponse(status, message))
    }

    // ---------- responses ----------

    /// A batched read's result, on this connection's loop.
    func deliver(_ result: Result<ReadResult, any Error>, request: UInt32) {
        guard busy, request == sequence, open else { return }
        let response = switch result {
        case .success(let read): server.app.render(read, token: userToken, status: articleStatus)
        case .failure(let error): errorResponse(for: error)
        }
        userToken = nil
        articleStatus = .ok
        respond(response, request: request)
    }

    /// An async handler's answer, on this connection's loop: a response, or a read to answer with.
    func answer(_ answer: Answer, request: UInt32) {
        guard busy, request == sequence, open else { return }
        switch answer {
        case .response(let response):
            respond(response, request: request)
        case .read(let read, let viewer, let status):
            articleStatus = status
            submit(read, viewer: viewer)
        }
    }

    /// A response, on this connection's loop. Then on to any request pipelined behind it.
    func respond(_ response: Response, request: UInt32) {
        guard busy, request == sequence, open else { return }
        write(response)
        process()
    }

    /// Sends a response. After a `Connection: close` one, `busy` stays set, so nothing more is read before the close.
    private func write(_ response: Response) {
        let bytes = response.wire(keepAlive: keepAlive, bodyless: headRequest)
        if keepAlive {
            busy = false
        } else {
            closeWhenSent = true
        }
        send(bytes)
    }

    private func send(_ bytes: Outgoing) {
        guard open else { return }
        if !unsent.isEmpty {
            unsent.append(bytes)
            return
        }
        var bytes = bytes
        guard writeOut(&bytes) else { return }
        if !bytes.isEmpty {
            unsent.append(bytes)
            loop.watch(fd, token!, readable: true, writable: true)
        } else if closeWhenSent {
            close()
        }
    }

    private func flush() {
        guard open, !unsent.isEmpty else { return }
        while !unsent.isEmpty {
            // Taken out while it is written: a failed write closes the connection, which empties `unsent`.
            var bytes = unsent.removeFirst()
            guard writeOut(&bytes) else { return }
            if !bytes.isEmpty {
                unsent.insert(bytes, at: 0)
                return
            }
        }
        loop.watch(fd, token!, readable: true, writable: false)
        if closeWhenSent { close() }
    }

    /// Writes as much as the socket takes; false if the connection had to be closed.
    private func writeOut(_ bytes: inout Outgoing) -> Bool {
        while !bytes.isEmpty {
            let n = writeDescriptor(fd, UnsafeRawBufferPointer(start: bytes.bytes.base + bytes.start, count: bytes.end - bytes.start))
            if n > 0 {
                bytes.start += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return true
            } else {
                close()
                return false
            }
        }
        return true
    }
}
