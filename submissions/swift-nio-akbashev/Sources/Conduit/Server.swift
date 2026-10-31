// The HTTP server: a NIO listener and one channel handler per connection, which parses each request from the bytes
// it receives and routes it (Routes.swift). A batched read is answered from the connection's event loop when its
// batch comes back; every other handler runs as a child task of the server, in one task group.
import Logging
import NIOCore
import NIOPosix
import ServiceLifecycle

final class HTTPServer: Service {
    let app: App
    private let host: String
    private let port: Int
    private let jobs: AsyncStream<@Sendable () async -> Void>
    private let submit: AsyncStream<@Sendable () async -> Void>.Continuation
    /// Each event loop's ReadOutbox, made on first use on that loop.
    private let outboxes: [ObjectIdentifier: NIOLoopBoundBox<ReadOutbox?>]

    init(app: App, host: String, port: Int) {
        self.app = app
        self.host = host
        self.port = port
        (jobs, submit) = AsyncStream.makeStream()
        outboxes = Dictionary(uniqueKeysWithValues: MultiThreadedEventLoopGroup.singleton.makeIterator().map { loop in
            (ObjectIdentifier(loop), NIOLoopBoundBox.makeEmptyBox(valueType: ReadOutbox.self, eventLoop: loop))
        })
    }

    /// The read outbox of `loop`, the event loop this is called on; nil without read batching.
    func outbox(for loop: any EventLoop) -> ReadOutbox? {
        guard let reads = app.reads, let box = outboxes[ObjectIdentifier(loop)] else { return nil }
        if let outbox = box.value { return outbox }
        let outbox = ReadOutbox(batcher: reads, loop: loop)
        box.value = outbox
        return outbox
    }

    /// Runs `job` as a child task of the server's task group; false once the server is shutting down.
    func spawn(_ job: @escaping @Sendable () async -> Void) -> Bool {
        if case .enqueued = submit.yield(job) { return true }
        return false
    }

    func run() async throws {
        let listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            // Front: direct, so this socket takes every user's connection: a backlog deep enough for a ramp (the
            // kernel caps it at net.core.somaxconn, 65535 on the box).
            .serverChannelOption(.backlog, value: 65535)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(HTTPConnection(server: self))
                }
            }
            .bind(host: host, port: port)
            .get()
        App.logger.info("listening on \(host):\(port)")

        // On shutdown: stop accepting, then wait for the handlers still running. Open connections stay until exit.
        await withDiscardingTaskGroup { group in
            group.addTask {
                try? await gracefulShutdown()
                try? await listener.close()
                self.submit.finish()
            }
            for await job in jobs {
                group.addTask { await job() }
            }
        }
    }
}

/// Where a request's response goes: its connection, on that connection's event loop, and which request it answers.
struct ReplyTo: Sendable {
    let connection: NIOLoopBound<HTTPConnection>
    let request: UInt32
}

/// One connection. Requests are answered one at a time, in order; bytes of requests pipelined behind the one in flight
/// wait in `pending`. Idle connections hold no buffer.
final class HTTPConnection: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// SPEC.md: keep idle connections open at least 65 s. A connection is closed at the first check, every 75 s, that
    /// finds it idle since the check before (so after 75 to 150 s); a request costs a counter increment, not a clock read.
    private static let idleCheck: TimeAmount = .seconds(75)

    private let server: HTTPServer
    private var context: ChannelHandlerContext?
    private var outbox: ReadOutbox?
    /// Received bytes not yet consumed: the start of a request, or requests behind the one in flight.
    private var pending: ByteBuffer?
    /// A request is being answered; nothing more is parsed until its response is written.
    private var busy = false
    private var keepAlive = true
    private var headRequest = false
    private var sentContinue = false
    /// Numbers requests, so a late reply can't answer a later request.
    private var sequence: UInt32 = 0
    /// GET /api/user's token, echoed back in its response.
    private var token: String?
    /// The status an article read answers with: 201 for the article just created.
    private var articleStatus: Status = .ok
    private var requestsAtLastCheck: UInt32 = 0
    private var idleTimer: Scheduled<Void>?

    init(server: HTTPServer) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        outbox = server.outbox(for: context.eventLoop)
        scheduleIdleCheck(context)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        idleTimer?.cancel()
        idleTimer = nil
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.context = nil
        idleTimer?.cancel()
        idleTimer = nil
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = unwrapInboundIn(data)
        if pending == nil {
            pending = bytes
        } else {
            pending!.writeImmutableBuffer(bytes)
            // A client that keeps sending while its request is answered gets cut off beyond one maximal request.
            if busy, pending!.readableBytes > maxHead + maxBody {
                context.close(promise: nil)
                return
            }
        }
        process(context)
    }

    // ---------- requests ----------

    /// Parses and dispatches requests from `pending` until one has to wait (for its bytes or for its answer).
    private func process(_ context: ChannelHandlerContext) {
        while !busy, let buffer = pending {
            guard buffer.readableBytes > 0 else {
                pending = nil
                return
            }
            let bytes = buffer.readableBytesUInt8Span
            let head: RequestHead
            switch parseHead(bytes) {
            case .incomplete: return
            case .invalid(let status): return fail(status, context)
            case .complete(let parsed): head = parsed
            }

            let body: ByteBuffer
            let consumed: Int
            if head.chunked {
                switch parseChunked(bytes, from: head.length) {
                case .incomplete: return expectingBody(head, context)
                case .invalid(let status): return fail(status, context)
                case .complete(let pieces, let size, let length):
                    var joined = context.channel.allocator.buffer(capacity: size)
                    for piece in pieces { joined.writeBytes(bytes.extracting(piece).bytes) }
                    body = joined
                    consumed = head.length + length
                }
            } else {
                guard head.contentLength <= maxBody else { return fail(.contentTooLarge, context) }
                consumed = head.length + head.contentLength
                guard bytes.count >= consumed else { return expectingBody(head, context) }
                body = buffer.getSlice(at: buffer.readerIndex + head.length, length: head.contentLength)!
            }

            busy = true
            keepAlive = head.keepAlive
            headRequest = head.method == .head
            sentContinue = false
            sequence &+= 1

            let target = bytes.extracting(head.target)
            var pathEnd = 0
            while pathEnd < target.count, target[pathEnd] != 0x3F { pathEnd += 1 } // ?
            let query = pathEnd < target.count
                ? buffer.getSlice(at: buffer.readerIndex + head.target.lowerBound + pathEnd + 1,
                                  length: target.count - pathEnd - 1)!
                : ByteBuffer()
            let dispatch = server.app.dispatch(head.method, path: target.extracting(0..<pathEnd), query: query,
                                               authorization: bytes.extracting(head.authorization), body: body)

            if buffer.readableBytes > consumed {
                pending = buffer.getSlice(at: buffer.readerIndex + consumed, length: buffer.readableBytes - consumed)
            } else {
                pending = nil
            }

            switch dispatch {
            case .now(let response):
                write(response, context)
            case .read(let read, let viewer, let token):
                self.token = token
                submit(read, viewer: viewer, context)
            case .later(let handler):
                let to = replyTo(context)
                let spawned = server.spawn {
                    let answer = await handler()
                    to.connection.eventLoop.execute { to.connection.value.answer(answer, request: to.request) }
                }
                if !spawned { write(errorResponse(.serviceUnavailable, "shutting down"), context) }
            }
        }
    }

    private func submit(_ read: Read, viewer: Int64, _ context: ChannelHandlerContext) {
        if let outbox {
            outbox.submit(read, viewer: viewer, replyTo: replyTo(context))
        } else if let reads = server.app.reads {
            var one = [reads.waiting(read, viewer: viewer, replyTo: replyTo(context))]
            reads.submit(&one)
        }
    }

    private func replyTo(_ context: ChannelHandlerContext) -> ReplyTo {
        ReplyTo(connection: NIOLoopBound(self, eventLoop: context.eventLoop), request: sequence)
    }

    /// The head is in, its body isn't yet. A client that sent `Expect: 100-continue` is waiting to be told to send it.
    private func expectingBody(_ head: RequestHead, _ context: ChannelHandlerContext) {
        guard head.expectContinue, !sentContinue else { return }
        sentContinue = true
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(staticString: "HTTP/1.1 100 Continue\r\n\r\n")), promise: nil)
    }

    /// A request that can't be read: answered, and the connection closed after it, since where the next one starts
    /// is unknown.
    private func fail(_ status: Status, _ context: ChannelHandlerContext) {
        pending = nil
        busy = true
        keepAlive = false
        headRequest = false
        let message = switch status {
        case .headerFieldsTooLarge: "request head too large"
        case .contentTooLarge: "request body too large"
        case .notImplemented: "unsupported transfer coding"
        default: "bad request"
        }
        write(errorResponse(status, message), context)
    }

    // ---------- responses ----------

    /// A batched read's result, on this connection's event loop.
    func deliver(_ result: Result<ReadResult, any Error>, request: UInt32) {
        guard busy, request == sequence, context != nil else { return }
        let response = switch result {
        case .success(let read): server.app.render(read, token: token, status: articleStatus)
        case .failure(let error): errorResponse(for: error)
        }
        token = nil
        articleStatus = .ok
        respond(response, request: request)
    }

    /// An async handler's answer, on this connection's event loop: a response, or a read to answer with.
    func answer(_ answer: Answer, request: UInt32) {
        guard busy, request == sequence, let context else { return }
        switch answer {
        case .response(let response):
            respond(response, request: request)
        case .read(let read, let viewer, let status):
            articleStatus = status
            submit(read, viewer: viewer, context)
        }
    }

    /// An async handler's response, on this connection's event loop. Then on to any request pipelined behind it.
    func respond(_ response: Response, request: UInt32) {
        guard busy, request == sequence, let context else { return }
        write(response, context)
        process(context)
    }

    /// Sends a response. After a `Connection: close` one, `busy` stays set, so nothing more is read before the close.
    private func write(_ response: Response, _ context: ChannelHandlerContext) {
        let bytes = response.wire(keepAlive: keepAlive, bodyless: headRequest)
        if keepAlive {
            busy = false
            context.writeAndFlush(wrapOutboundOut(bytes), promise: nil)
        } else {
            pending = nil
            context.writeAndFlush(wrapOutboundOut(bytes)).assumeIsolated().whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }

    private func scheduleIdleCheck(_ context: ChannelHandlerContext) {
        requestsAtLastCheck = sequence
        idleTimer = context.eventLoop.assumeIsolated().scheduleTask(in: Self.idleCheck) {
            guard self.context != nil else { return }
            if self.busy || self.sequence != self.requestsAtLastCheck {
                self.scheduleIdleCheck(context)
            } else {
                context.close(promise: nil)
            }
        }
    }
}
