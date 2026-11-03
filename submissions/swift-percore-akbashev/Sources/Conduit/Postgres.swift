// A small Postgres client of our own (instead of postgres-nio). One non-blocking socket per connection, watched by its
// loop (Loop.swift); the extended query protocol with binary parameters and results; pipelines: a request is several
// statements in one write, each ending in its own Sync (so each runs as if alone, autocommitted), answered in one round
// trip. A request's rows are kept as the bytes Postgres sent, copied into one buffer for the whole request, and read in
// place by offset (PGCursor): no object per row or per cell. A connection is confined to its loop: requests are made,
// and their results arrive, on that loop. When the connection closes, every request still waiting on it fails.
import Crypto
import Foundation

struct PGConfig: Sendable {
    var host: String
    var port: Int
    var user: String
    var password: String?
    var database: String
    /// Startup parameters (session settings), sent with the connection's startup message.
    var parameters: [(String, String)]
}

/// An error Postgres sent back for a statement.
struct PGError: Error, Sendable, CustomStringConvertible {
    let sqlState: String
    let message: String

    var isUniqueViolation: Bool { sqlState == "23505" }
    var description: String { "Postgres \(sqlState): \(message)" }
}

enum PGConnectionError: Error, Sendable {
    case closed
    case protocolViolation(String)
    case authentication(String)
}

/// A statement prepared once per connection, by name.
protocol PGPrepared {
    static var name: String { get }
    static var sql: String { get }
}

// ---------- requests ----------

/// The statements of one round trip, as the bytes that go on the wire. Built by one owner, then sent once.
final class PGRequest {
    fileprivate var bytes = Bytes(capacity: 1024)
    fileprivate(set) var count = 0
    /// Statements this request prepares (Parse) before it binds them, by the index of the statement that parses each.
    fileprivate var preparing: [(statement: Int, name: String)] = []
    private let prepared: Set<String>

    fileprivate init(prepared: Set<String>) {
        self.prepared = prepared
    }

    /// A prepared statement (parsed on this connection the first time), bound to the parameters `binds` writes.
    func execute<Q: PGPrepared>(_ statement: Q.Type, _ binds: (inout PGBinds) -> Void) {
        if !prepared.contains(Q.name), !preparing.contains(where: { $0.name == Q.name }) {
            parse(name: Q.name, sql: Q.sql)
            preparing.append((count, Q.name))
        }
        bind(name: Q.name, binds)
    }

    /// A statement parsed for this request only (the unnamed statement).
    func execute(_ sql: String, _ binds: (inout PGBinds) -> Void = { _ in }) {
        parse(name: "", sql: sql)
        bind(name: "", binds)
    }

    private func parse(name: String, sql: String) {
        let at = begin(0x50) // Parse
        bytes.appendNullTerminated(name)
        bytes.appendNullTerminated(sql)
        bytes.append(integer: Int16(0)) // parameter types inferred from the SQL
        end(at)
    }

    private func bind(name: String, _ binds: (inout PGBinds) -> Void) {
        let at = begin(0x42) // Bind
        bytes.append(integer: UInt8(0)) // unnamed portal
        bytes.appendNullTerminated(name)
        bytes.append(integer: Int16(1))
        bytes.append(integer: Int16(1)) // every parameter binary
        let countAt = bytes.count
        bytes.append(integer: Int16(0)) // parameter count, filled in below
        // The binds write straight into the request's bytes: moved in and back out, never copied.
        var params = PGBinds()
        swap(&params.bytes, &bytes)
        binds(&params)
        swap(&params.bytes, &bytes)
        bytes.set(integer: Int16(params.count), at: countAt)
        bytes.append(integer: Int16(1))
        bytes.append(integer: Int16(1)) // every result column binary
        end(at)
        let execute = begin(0x45) // Execute
        bytes.append(integer: UInt8(0))
        bytes.append(integer: Int32(0)) // all rows
        end(execute)
        end(begin(0x53)) // Sync: the statement stands alone
        count += 1
    }

    /// Starts a message: its type, and room for its length; returns where the length goes.
    private func begin(_ type: UInt8) -> Int {
        bytes.append(integer: type)
        let at = bytes.count
        bytes.append(integer: Int32(0))
        return at
    }

    /// Fills in the length of the message `begin` started.
    private func end(_ at: Int) {
        bytes.set(integer: Int32(bytes.count - at), at: at)
    }
}

/// A Bind message's parameters, in binary.
struct PGBinds: ~Copyable {
    fileprivate var bytes = Bytes()
    fileprivate var count = 0

    fileprivate init() {}

    /// Room for a value's length; returns where it goes.
    private mutating func begin() -> Int {
        let at = bytes.count
        bytes.append(integer: Int32(0))
        return at
    }

    private mutating func end(_ at: Int) {
        bytes.set(integer: Int32(bytes.count - at - 4), at: at)
        count += 1
    }

    mutating func null() {
        bytes.append(integer: Int32(-1))
        count += 1
    }

    mutating func int8(_ v: Int64) {
        bytes.append(integer: Int32(8))
        bytes.append(integer: v)
        count += 1
    }

    mutating func int4(_ v: Int32) {
        bytes.append(integer: Int32(4))
        bytes.append(integer: v)
        count += 1
    }

    mutating func text(_ s: String) {
        let at = begin()
        bytes.append(s)
        end(at)
    }

    mutating func int8(_ v: Int64?) { if let v { int8(v) } else { null() } }
    mutating func text(_ s: String?) { if let s { text(s) } else { null() } }

    mutating func int8Array(_ values: borrowing [Int64]) {
        let at = begin()
        arrayHeader(count: values.count, element: 20) // int8
        let elements = values.span
        for i in elements.indices {
            bytes.append(integer: Int32(8))
            bytes.append(integer: elements[i])
        }
        end(at)
    }

    mutating func textArray(_ values: borrowing [String]) {
        let at = begin()
        arrayHeader(count: values.count, element: 25) // text
        let elements = values.span
        for i in elements.indices {
            let lengthAt = bytes.count
            bytes.append(integer: Int32(0))
            bytes.append(elements[i])
            bytes.set(integer: Int32(bytes.count - lengthAt - 4), at: lengthAt)
        }
        end(at)
    }

    /// A one-dimensional array without NULLs: dimensions, has-nulls flag, element type, then its length and lower bound.
    private mutating func arrayHeader(count: Int, element: Int32) {
        if count == 0 {
            bytes.append(integer: Int32(0)) // no dimensions
            bytes.append(integer: Int32(0))
            bytes.append(integer: element)
            return
        }
        bytes.append(integer: Int32(1))
        bytes.append(integer: Int32(0))
        bytes.append(integer: element)
        bytes.append(integer: Int32(count))
        bytes.append(integer: Int32(1))
    }
}

// ---------- results ----------

/// What a request's statements answered: their rows, all in one buffer, or each statement's error.
struct PGResults: Sendable {
    /// Every DataRow of the request, its payload as Postgres sent it (column count, then each column's length and
    /// bytes), one after another; empty when they went to a PGRowSink.
    let rows: PGRows
    fileprivate let statements: [PGStatementResult]

    var count: Int { statements.count }

    /// Statement `i`'s rows, as offsets into `rows` (plus `base`, where `rows` was copied to); throws its error if it
    /// failed.
    func rows(_ i: Int, base: Int = 0) throws(PGError) -> PGRowRanges {
        if let error = statements[i].error { throw error }
        return PGRowRanges(starts: statements[i].rowStarts, ends: statements[i].rowEnds, base: base)
    }

    func error(_ i: Int) -> PGError? { statements[i].error }
}

/// A request's rows once it is answered: its buffer moved in, not copied, and read from here.
final class PGRows: @unchecked Sendable {
    let bytes: Bytes

    init(_ bytes: consuming Bytes) {
        self.bytes = bytes
    }
}

fileprivate struct PGStatementResult: Sendable {
    var rowStarts: [Int32] = []
    var rowEnds: [Int32] = []
    var error: PGError?
}

/// One statement's rows: each a range of `PGResults.rows`, or of the buffer they were copied into at `base`.
struct PGRowRanges: Sendable, RandomAccessCollection {
    let starts: [Int32]
    let ends: [Int32]
    let base: Int
    var startIndex: Int { 0 }
    var endIndex: Int { starts.count }
    subscript(i: Int) -> PGCursor { PGCursor(start: base + Int(starts[i]), end: base + Int(ends[i])) }
}

/// A text value: a range of `PGResults.rows`, still in the bytes Postgres sent.
struct PGTextRef: Sendable, BitwiseCopyable {
    let start: Int32
    let count: Int32
}

/// Reads one DataRow's cells in order, in place in `PGResults.rows`: a column count, then each column's length (-1
/// for NULL) and bytes. Every column's type is fixed by our SQL, so there is no per-cell type dispatch.
struct PGCursor: BitwiseCopyable {
    private var position: Int
    private let end: Int

    init(start: Int, end: Int) {
        position = start + 2 // the column count
        self.end = end
    }

    /// The next cell's bytes, as a range of `rows`, or nil for SQL NULL.
    private mutating func cell(_ rows: borrowing Bytes) throws(PGCursorError) -> Range<Int>? {
        guard position + 4 <= end, let length = rows.integer(at: position, as: Int32.self) else {
            throw .missingColumn
        }
        position += 4
        if length < 0 { return nil }
        let start = position
        position += Int(length)
        guard position <= end else { throw .missingColumn }
        return start..<position
    }

    private mutating func fixed<T: FixedWidthInteger>(_ rows: borrowing Bytes, _: T.Type) throws(PGCursorError) -> T? {
        guard let range = try cell(rows) else { return nil }
        guard range.count == MemoryLayout<T>.size, let value = rows.integer(at: range.lowerBound, as: T.self) else {
            throw .typeMismatch
        }
        return value
    }

    mutating func skip(_ rows: borrowing Bytes) throws(PGCursorError) { _ = try cell(rows) }

    mutating func intOrNull(_ rows: borrowing Bytes) throws(PGCursorError) -> Int64? { try fixed(rows, Int64.self) }
    mutating func int(_ rows: borrowing Bytes) throws(PGCursorError) -> Int64 {
        guard let v = try intOrNull(rows) else { throw .unexpectedNull }
        return v
    }
    mutating func int4(_ rows: borrowing Bytes) throws(PGCursorError) -> Int32 {
        guard let v = try fixed(rows, Int32.self) else { throw .unexpectedNull }
        return v
    }
    mutating func bool(_ rows: borrowing Bytes) throws(PGCursorError) -> Bool {
        guard let v = try fixed(rows, UInt8.self) else { throw .unexpectedNull }
        return v != 0
    }
    /// A timestamptz: microseconds since 2000-01-01 UTC.
    mutating func timestampOrNull(_ rows: borrowing Bytes) throws(PGCursorError) -> PGTimestamp? {
        try fixed(rows, Int64.self).map(PGTimestamp.init(micros:))
    }
    mutating func timestamp(_ rows: borrowing Bytes) throws(PGCursorError) -> PGTimestamp {
        guard let v = try timestampOrNull(rows) else { throw .unexpectedNull }
        return v
    }
    mutating func textOrNull(_ rows: borrowing Bytes) throws(PGCursorError) -> PGTextRef? {
        try cell(rows).map { PGTextRef(start: Int32($0.lowerBound), count: Int32($0.count)) }
    }
    mutating func text(_ rows: borrowing Bytes) throws(PGCursorError) -> PGTextRef {
        guard let v = try textOrNull(rows) else { throw .unexpectedNull }
        return v
    }

    /// A one-dimensional int4[] without NULL elements.
    mutating func int4Array(_ rows: borrowing Bytes) throws(PGCursorError) -> [Int32] {
        guard let range = try cell(rows) else { throw .unexpectedNull }
        var at = range.lowerBound
        let count = try Self.arrayHeader(rows, &at)
        var out = [Int32]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard rows.integer(at: at, as: Int32.self) == 4, let v = rows.integer(at: at + 4, as: Int32.self) else {
                throw .typeMismatch
            }
            out.append(v)
            at += 8
        }
        return out
    }

    /// A one-dimensional text[]; its elements stay ranges of `rows`.
    mutating func textArray(_ rows: borrowing Bytes) throws(PGCursorError) -> [PGTextRef] {
        guard let range = try cell(rows) else { throw .unexpectedNull }
        var at = range.lowerBound
        let count = try Self.arrayHeader(rows, &at)
        var out = [PGTextRef]()
        out.reserveCapacity(count)
        for _ in 0..<count {
            guard let length = rows.integer(at: at, as: Int32.self), length >= 0 else { throw .typeMismatch }
            out.append(PGTextRef(start: Int32(at + 4), count: length))
            at += 4 + Int(length)
        }
        return out
    }

    private static func arrayHeader(_ rows: borrowing Bytes, _ at: inout Int) throws(PGCursorError) -> Int {
        guard let dimensions = rows.integer(at: at, as: Int32.self) else { throw .typeMismatch }
        at += 12 // dimensions, has-nulls flag, element type
        if dimensions == 0 { return 0 }
        guard dimensions == 1, let count = rows.integer(at: at, as: Int32.self), count >= 0 else { throw .typeMismatch }
        at += 8 // length, lower bound
        return Int(count)
    }
}

enum PGCursorError: Error, Sendable {
    case missingColumn
    case unexpectedNull
    case typeMismatch
}

// ---------- the connection ----------

/// Where requests' rows go when the caller wants them in one buffer of its own: a read batch's round moves its buffer
/// in, sends its requests on each of its connections (all on one loop) into it, and moves it back out once all have
/// answered, so the batch's rows are copied once, from the bytes received to where they are read. Moved, never
/// shared, so writing into it never copies it.
final class PGRowSink {
    var rows: Bytes

    init(_ rows: consuming Bytes) {
        self.rows = rows
    }
}

/// A request's answer, on its connection's loop, for the task that sent it to await there.
final class PGReply {
    private var result: Result<PGResults, any Error>?
    private var waiter: CheckedContinuation<PGResults, any Error>?

    fileprivate init(_ result: Result<PGResults, any Error>? = nil) {
        self.result = result
    }

    fileprivate func complete(_ outcome: Result<PGResults, any Error>) {
        if let waiter {
            self.waiter = nil
            waiter.resume(with: outcome)
        } else {
            result = outcome
        }
    }

    /// The results, once every statement has answered; from a task on the connection's loop.
    func value() async throws -> PGResults {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }
}

/// One Postgres connection: a non-blocking socket its loop watches, confined to that loop. It is opened, used and
/// closed from tasks that run there, and its replies are read there, so an answer resumes its task without a hop.
/// Requests are answered in order; when the connection closes, every request still waiting on it fails.
final class PGConnection: LoopSource {
    let loop: Loop
    private let fd: Int32
    private var token: LoopToken?
    private let config: PGConfig
    private var phase = Phase.connecting
    /// The task waiting in `connect`, until the server is ready for queries.
    private var started: CheckedContinuation<Void, any Error>?
    /// Bytes received and not yet decoded: the start of a message.
    private var inbound = Bytes(capacity: 16384)
    /// Bytes the socket hasn't taken yet.
    private var unsent = Bytes()
    private var pending: [Pending] = []
    private var head = 0
    private var prepared = Set<String>()
    private(set) var isClosed = false

    private enum Phase {
        case connecting
        case starting
        case scram(SCRAM)
        case ready
    }

    /// A request sent and not yet fully answered.
    private final class Pending {
        let count: Int
        let parses: [(statement: Int, name: String)]
        let reply: PGReply
        /// Where the rows go instead of `rows`.
        let sink: PGRowSink?
        var rows = Bytes()
        var statements: [PGStatementResult] = []
        var current = PGStatementResult()
        /// The current statement's Parse is done (ParseComplete).
        var parsed = false

        init(count: Int, parses: [(statement: Int, name: String)], reply: PGReply, sink: PGRowSink?) {
            self.count = count
            self.parses = parses
            self.reply = reply
            self.sink = sink
            statements.reserveCapacity(count)
            if sink == nil { rows.reserve(4096) }
        }
    }

    private init(loop: Loop, fd: Int32, config: PGConfig) {
        self.loop = loop
        self.fd = fd
        self.config = config
    }

    /// Connects on `loop`, from a task running there, and returns once authenticated and ready for queries.
    static func connect(_ config: PGConfig, on loop: Loop) async throws -> PGConnection {
        precondition(loop.inLoop, "PGConnection.connect off its loop")
        let connection = PGConnection(loop: loop, fd: try Sockets.connect(host: config.host, port: config.port), config: config)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.started = continuation
            // Writable once connected.
            connection.token = loop.register(connection.fd, connection, readable: true, writable: true)
        }
        return connection
    }

    /// A new, empty request for this connection.
    func request() -> PGRequest {
        PGRequest(prepared: prepared)
    }

    /// Sends the request; its reply completes once every statement has answered. On the connection's loop. Several
    /// connections' requests can be sent before waiting on any, so their backends work at once. With a `sink`, the rows
    /// go there (the results' row ranges are offsets into `sink.rows`), not into the results' own buffer.
    func send(_ request: PGRequest, into sink: PGRowSink? = nil) -> PGReply {
        guard !isClosed else { return PGReply(.failure(PGConnectionError.closed)) }
        if request.count == 0 { return PGReply(.success(PGResults(rows: PGRows(Bytes()), statements: []))) }
        // Counted as prepared from now on, so a request built before this one is answered doesn't parse them again;
        // one whose statement fails before its ParseComplete is taken back out (statementDone).
        for (_, name) in request.preparing { prepared.insert(name) }
        let reply = PGReply()
        pending.append(Pending(count: request.count, parses: request.preparing, reply: reply, sink: sink))
        output(request.bytes)
        return reply
    }

    /// Sends the request and waits for every statement's answer, from a task on the connection's loop.
    func run(_ request: PGRequest) async throws -> PGResults {
        try await send(request).value()
    }

    func close() {
        fail(PGConnectionError.closed)
    }

    // ---------- the socket ----------

    func ready(readable: Bool, writable: Bool) {
        if writable {
            if case .connecting = phase { connected() } else { flush() }
        }
        if readable, !isClosed { receive() }
    }

    private func connected() {
        let error = Sockets.connectError(fd)
        guard error == 0 else { return fail(SystemError("connect \(config.host):\(config.port)", error)) }
        phase = .starting
        loop.watch(fd, token!, readable: true, writable: false)
        var b = Bytes(capacity: 256)
        b.append(integer: Int32(0))
        b.append(integer: Int32(196_608)) // protocol 3.0
        for (key, value) in [("user", config.user), ("database", config.database)] + config.parameters {
            b.appendNullTerminated(key)
            b.appendNullTerminated(value)
        }
        b.append(integer: UInt8(0))
        b.set(integer: Int32(b.count), at: 0)
        output(b)
    }

    /// Reads what has arrived (up to a few reads, while each fills the room it was given) and decodes it.
    private func receive() {
        for _ in 0..<4 {
            let (n, room) = inbound.read(from: fd, minimum: 16384)
            if n < 0 {
                switch errno {
                case EAGAIN, EWOULDBLOCK, EINTR: return
                default: return fail(SystemError("read"))
                }
            }
            if n == 0 { return fail(PGConnectionError.closed) }
            do { try decode() } catch { return fail(error) }
            if isClosed || n < room { return }
        }
    }

    /// Decodes every whole message received, in place.
    private func decode() throws {
        while let type = inbound.integer(at: 0, as: UInt8.self), let length = inbound.integer(at: 1, as: Int32.self) {
            guard length >= 4 else { throw PGConnectionError.protocolViolation("message length \(length)") }
            guard inbound.count >= 1 + Int(length) else { break }
            try message(type, body: 5..<(1 + Int(length)))
            if isClosed { return }
            inbound.consume(1 + Int(length))
        }
    }

    private func output(_ bytes: borrowing Bytes) {
        guard !isClosed else { return }
        if !unsent.isEmpty {
            unsent.append(bytes, from: 0, count: bytes.count)
            return
        }
        guard let written = writeOut(bytes) else { return }
        if written < bytes.count {
            unsent.append(bytes, from: written, count: bytes.count - written)
            loop.watch(fd, token!, readable: true, writable: true)
        }
    }

    private func flush() {
        guard !isClosed, !unsent.isEmpty else { return }
        // Moved out while it is written: a failed write closes the connection, which releases `unsent`.
        var bytes = Bytes()
        swap(&bytes, &unsent)
        guard let written = writeOut(bytes) else { return }
        bytes.consume(written)
        swap(&bytes, &unsent)
        if unsent.isEmpty { loop.watch(fd, token!, readable: true, writable: false) }
    }

    /// Writes as much of `bytes` as the socket takes: how much that was, or nil if writing failed the connection.
    private func writeOut(_ bytes: borrowing Bytes) -> Int? {
        var written = 0
        while written < bytes.count {
            let n = bytes.withUnsafeBytes { all in
                writeDescriptor(fd, UnsafeRawBufferPointer(rebasing: all[written...]))
            }
            if n > 0 {
                written += n
            } else if n < 0, errno == EINTR {
                continue
            } else if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                fail(SystemError("write"))
                return nil
            }
        }
        return written
    }

    private func fail(_ error: any Error) {
        guard !isClosed else { return }
        isClosed = true
        if let token { loop.unregister(token) }
        closeDescriptor(fd)
        unsent.release()
        started?.resume(throwing: error)
        started = nil
        let waiting = pending[head...]
        pending = []
        head = 0
        for p in waiting { p.reply.complete(.failure(error)) }
    }

    // ---------- the backend's messages ----------

    /// One message, its body at `body` (offsets into `inbound`).
    private func message(_ type: UInt8, body: Range<Int>) throws {
        switch type {
        case 0x44: // DataRow: copied into the request's row buffer
            guard head < pending.count else { throw PGConnectionError.protocolViolation("row without a request") }
            let start: Int32
            let end: Int32
            let request = pending[head]
            if let sink = request.sink {
                start = Int32(sink.rows.count)
                sink.rows.append(inbound, from: body.lowerBound, count: body.count)
                end = Int32(sink.rows.count)
            } else {
                start = Int32(request.rows.count)
                request.rows.append(inbound, from: body.lowerBound, count: body.count)
                end = Int32(request.rows.count)
            }
            pending[head].current.rowStarts.append(start)
            pending[head].current.rowEnds.append(end)
        case 0x5A: // ReadyForQuery
            if case .ready = phase {
                try statementDone()
            } else {
                phase = .ready
                started?.resume()
                started = nil
            }
        case 0x45: // ErrorResponse
            let error = Self.error(MessageReader(inbound.array(body)))
            if case .ready = phase, head < pending.count {
                pending[head].current.error = error
            } else {
                throw PGConnectionError.authentication(error.description)
            }
        case 0x52: // Authentication
            try authentication(MessageReader(inbound.array(body)))
        case 0x31: // ParseComplete
            if head < pending.count { pending[head].parsed = true }
        case 0x32, 0x43, 0x6E, 0x73, 0x33, 0x4E, 0x53, 0x4B, 0x41, 0x74, 0x54:
            break // BindComplete, CommandComplete, NoData, PortalSuspended, CloseComplete, Notice, ParameterStatus,
                  // BackendKeyData, Notification, ParameterDescription, RowDescription
        default:
            throw PGConnectionError.protocolViolation("message type \(type)")
        }
    }

    /// A statement's Sync came back: on to the request's next statement, or the request is answered.
    private func statementDone() throws {
        guard head < pending.count else { throw PGConnectionError.protocolViolation("ReadyForQuery without a request") }
        let current = pending[head].current
        if current.error != nil, !pending[head].parsed,
           let parse = pending[head].parses.first(where: { $0.statement == pending[head].statements.count }) {
            // Postgres skipped the Parse (an aborted transaction's statements are skipped up to its Sync).
            prepared.remove(parse.name)
        }
        pending[head].statements.append(current)
        pending[head].current = PGStatementResult()
        pending[head].parsed = false
        guard pending[head].statements.count == pending[head].count else { return }
        let done = pending[head]
        head += 1
        if head == pending.count {
            pending.removeAll(keepingCapacity: true)
            head = 0
        }
        var rows = Bytes()
        swap(&rows, &done.rows)
        done.reply.complete(.success(PGResults(rows: PGRows(rows), statements: done.statements)))
    }

    private static func error(_ body: consuming MessageReader) -> PGError {
        var b = body
        var code = ""
        var text = ""
        while let field = b.byte(), field != 0 {
            guard let value = b.cString() else { break }
            if field == 0x43 { code = value } // C: SQLSTATE
            if field == 0x4D { text = value } // M: message
        }
        return PGError(sqlState: code, message: text)
    }

    // ---------- authentication ----------

    private func authentication(_ body: consuming MessageReader) throws {
        var b = body
        guard let kind = b.int32() else { throw PGConnectionError.protocolViolation("auth") }
        switch kind {
        case 0: // AuthenticationOk
            break
        case 3: // cleartext password
            message(0x70) { $0.appendNullTerminated(self.config.password ?? "") }
        case 5: // MD5: "md5" + md5(md5(password + user) + salt)
            guard let salt = b.bytes(4) else { throw PGConnectionError.protocolViolation("md5 salt") }
            let inner = Self.hex(Insecure.MD5.hash(data: Array(((config.password ?? "") + config.user).utf8)))
            let outer = Self.hex(Insecure.MD5.hash(data: Array(inner.utf8) + salt))
            message(0x70) { $0.appendNullTerminated("md5" + outer) }
        case 10: // SASL: the mechanisms on offer
            var mechanisms: [String] = []
            while let m = b.cString(), !m.isEmpty { mechanisms.append(m) }
            guard mechanisms.contains("SCRAM-SHA-256") else {
                throw PGConnectionError.authentication("no supported SASL mechanism in \(mechanisms)")
            }
            let scram = SCRAM(password: config.password ?? "")
            let first = scram.clientFirst
            phase = .scram(scram)
            message(0x70) { m in
                m.appendNullTerminated("SCRAM-SHA-256")
                m.append(integer: Int32(first.utf8.count))
                m.append(first)
            }
        case 11: // SASL continue: the server's first message
            guard case .scram(var scram) = phase else {
                throw PGConnectionError.protocolViolation("SASL continue")
            }
            let final = try scram.clientFinal(serverFirst: b.rest())
            phase = .scram(scram)
            message(0x70) { $0.append(final) }
        case 12: // SASL final: the server's signature
            guard case .scram(let scram) = phase else {
                throw PGConnectionError.protocolViolation("SASL final")
            }
            try scram.verify(serverFinal: b.rest())
        default:
            throw PGConnectionError.authentication("unsupported authentication method \(kind)")
        }
    }

    /// Sends one message of the startup flow.
    private func message(_ type: UInt8, _ body: (inout Bytes) -> Void) {
        var b = Bytes(capacity: 128)
        b.append(integer: type)
        b.append(integer: Int32(0))
        body(&b)
        b.set(integer: Int32(b.count - 1), at: 1)
        output(b)
    }

    private static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// SCRAM-SHA-256 (RFC 5802, RFC 7677), as Postgres speaks it: no channel binding, the user name left to the startup
/// message.
private struct SCRAM {
    private let password: String
    private let nonce: String
    private var authMessage = ""
    private var saltedPassword: [UInt8] = []

    init(password: String) {
        self.password = password
        var random = SystemRandomNumberGenerator()
        nonce = Data((0..<18).map { _ in UInt8.random(in: 0...255, using: &random) }).base64EncodedString()
    }

    private var clientFirstBare: String { "n=,r=\(nonce)" }
    var clientFirst: String { "n,," + clientFirstBare }

    mutating func clientFinal(serverFirst: String) throws -> String {
        var attributes: [Character: Substring] = [:]
        for part in serverFirst.split(separator: ",") where part.count > 2 {
            attributes[part.first!] = part.dropFirst(2)
        }
        guard let serverNonce = attributes["r"], serverNonce.hasPrefix(nonce),
              let saltText = attributes["s"], let salt = Data(base64Encoded: String(saltText)),
              let iterationsText = attributes["i"], let iterations = Int(iterationsText), iterations > 0 else {
            throw PGConnectionError.authentication("bad SCRAM server-first message")
        }
        saltedPassword = Self.hi(Array(password.utf8), salt: Array(salt), iterations: iterations)
        let withoutProof = "c=biws,r=\(serverNonce)" // biws: base64 of "n,,"
        authMessage = clientFirstBare + "," + serverFirst + "," + withoutProof
        let clientKey = Self.hmac(saltedPassword, "Client Key")
        let storedKey = Array(SHA256.hash(data: clientKey))
        let signature = Self.hmac(storedKey, authMessage)
        let proof = zip(clientKey, signature).map { $0 ^ $1 }
        return withoutProof + ",p=" + Data(proof).base64EncodedString()
    }

    func verify(serverFinal: String) throws {
        let serverKey = Self.hmac(saltedPassword, "Server Key")
        let expected = "v=" + Data(Self.hmac(serverKey, authMessage)).base64EncodedString()
        guard serverFinal.hasPrefix(expected) else { throw PGConnectionError.authentication("SCRAM server signature mismatch") }
    }

    private static func hmac(_ key: [UInt8], _ message: String) -> [UInt8] {
        hmac(key, Array(message.utf8))
    }

    private static func hmac(_ key: [UInt8], _ message: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    /// PBKDF2-HMAC-SHA256 with one 32-byte block, as SCRAM's Hi() is defined.
    private static func hi(_ password: [UInt8], salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: password)
        var u = Array(HMAC<SHA256>.authenticationCode(for: salt + [0, 0, 0, 1], using: key))
        var result = u
        for _ in 1..<iterations {
            u = Array(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for i in result.indices { result[i] ^= u[i] }
        }
        return result
    }
}

/// Reads the fields of a message that is parsed field by field (an error, a step of authentication), from a copy.
private struct MessageReader {
    private let bytes: [UInt8]
    private var at = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func byte() -> UInt8? {
        guard at < bytes.count else { return nil }
        defer { at += 1 }
        return bytes[at]
    }

    mutating func int32() -> Int32? {
        guard at + 4 <= bytes.count else { return nil }
        defer { at += 4 }
        return bytes[at..<(at + 4)].reduce(0) { $0 << 8 | Int32($1) }
    }

    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard at + n <= bytes.count else { return nil }
        defer { at += n }
        return Array(bytes[at..<(at + n)])
    }

    /// A NUL-terminated string.
    mutating func cString() -> String? {
        guard let nul = bytes[at...].firstIndex(of: 0) else { return nil }
        defer { at = nul + 1 }
        return String(decoding: bytes[at..<nul], as: UTF8.self)
    }

    /// Everything left, as text.
    mutating func rest() -> String {
        defer { at = bytes.count }
        return String(decoding: bytes[at...], as: UTF8.self)
    }
}
