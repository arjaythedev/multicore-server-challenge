// wire.rs: a Postgres v3 client on a blocking socket (each lane's thread is its own, so a lane waits for Postgres in
// `read`, as the Rust's does). SCRAM-SHA-256 or cleartext password authentication, the extended protocol with binary
// parameters and results, and pipelines: many Bind/Execute pairs before one Sync, read back into one reusable arena.
import Glibc

let OID_INT8: UInt32 = 20
let OID_INT4: UInt32 = 23
let OID_TEXT: UInt32 = 25
let OID_INT4_ARR: UInt32 = 1007
let OID_INT8_ARR: UInt32 = 1016
let OID_TEXT_ARR: UInt32 = 1009

struct SqlStateErr: Error, CustomStringConvertible, Sendable {
    var code: String
    var message: String
    var description: String { "\(code): \(message)" }
}

enum PgError: Error, CustomStringConvertible {
    case io(String)
    case server(SqlStateErr)
    case wire(String)

    var description: String {
        switch self {
        case .io(let e): "io: \(e)"
        case .server(let e): "db: \(e)"
        case .wire(let s): "wire: \(s)"
        }
    }
}

struct DbEndpoint: Sendable {
    var host: String
    var port: UInt16
    var user: String
    var password: String
    var database: String

    private static func decodeURLPart(_ s: Substring) -> String {
        let raw = Array(s.utf8)
        var out: [UInt8] = []
        var i = 0
        while i < raw.count {
            if raw[i] == 0x25, i + 2 < raw.count, let b = UInt8(String(decoding: raw[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(b)
                i += 3
                continue
            }
            out.append(raw[i])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    init?(url: String) {
        var rest = Substring(url)
        if rest.hasPrefix("postgres://") {
            rest = rest.dropFirst("postgres://".count)
        } else if rest.hasPrefix("postgresql://") {
            rest = rest.dropFirst("postgresql://".count)
        } else {
            return nil
        }
        guard let at = rest.lastIndex(of: "@") else { return nil }
        let creds = rest[..<at]
        let target = rest[rest.index(after: at)...]
        let (user, pass) = creds.firstIndex(of: ":").map { (creds[..<$0], creds[creds.index(after: $0)...]) } ?? (creds, "")
        let (addr, dbPart) = target.firstIndex(of: "/").map { (target[..<$0], target[target.index(after: $0)...]) } ?? (target, "")
        let db = dbPart.split(separator: "?", omittingEmptySubsequences: false).first ?? ""
        if let colon = addr.lastIndex(of: ":") {
            guard let p = UInt16(addr[addr.index(after: colon)...]) else { return nil }
            host = String(addr[..<colon])
            port = p
        } else {
            host = String(addr)
            port = 5432
        }
        self.user = Self.decodeURLPart(user)
        password = Self.decodeURLPart(pass)
        database = Self.decodeURLPart(db.isEmpty ? user : db)
    }
}

/// A parameter of a Bind: what the Rust's `BindParam` borrows, here values (arrays are reference-counted, not copied).
enum BindParam {
    case null
    case i64(Int64)
    case text([UInt8])
    case i64Array([Int64])
    case i32Array([Int32])
    case textArray([[UInt8]])
}

/// The outgoing messages of one pipeline.
struct TxBuf: ~Copyable {
    var buf = ByteBuffer(capacity: 16 * 1024)

    @inline(__always) private mutating func startMessage(_ tag: UInt8) -> Int {
        buf.append(tag)
        let at = buf.count
        buf.append(repeating: 0, count: 4)
        return at
    }

    @inline(__always) private mutating func finishMessage(_ at: Int) {
        buf.storeBigEndian(UInt32(buf.count - at), at: at)
    }

    @inline(__always) private mutating func cstr(_ s: String) {
        var s = s
        s.withUTF8 { buf.append(UnsafeRawBufferPointer($0)) }
        buf.append(0)
    }

    @inline(__always) private mutating func i16(_ v: Int16) {
        withUnsafeBytes(of: v.bigEndian) { buf.append($0) }
    }

    @inline(__always) private mutating func i32(_ v: Int32) {
        withUnsafeBytes(of: v.bigEndian) { buf.append($0) }
    }

    @inline(__always) private mutating func i64(_ v: Int64) {
        withUnsafeBytes(of: v.bigEndian) { buf.append($0) }
    }

    mutating func writeParse(_ name: String, _ sql: String, _ oids: [UInt32]) {
        let at = startMessage(0x50)
        cstr(name)
        cstr(sql)
        i16(Int16(oids.count))
        for oid in oids { i32(Int32(bitPattern: oid)) }
        finishMessage(at)
    }

    private mutating func arrayHeader(byteLength: Int, elemOID: UInt32, count: Int) {
        i32(Int32(byteLength))
        i32(1)
        i32(0)
        i32(Int32(bitPattern: elemOID))
        i32(Int32(count))
        i32(1)
    }

    private mutating func encode(_ p: BindParam) {
        switch p {
        case .null:
            i32(-1)
        case .i64(let v):
            i32(8)
            i64(v)
        case .text(let s):
            i32(Int32(s.count))
            buf.append(s)
        case .i64Array(let items):
            arrayHeader(byteLength: 20 + items.count * 12, elemOID: OID_INT8, count: items.count)
            for v in items {
                i32(8)
                i64(v)
            }
        case .i32Array(let items):
            arrayHeader(byteLength: 20 + items.count * 8, elemOID: OID_INT4, count: items.count)
            for v in items {
                i32(4)
                i32(v)
            }
        case .textArray(let items):
            let payload = items.reduce(0) { $0 + 4 + $1.count }
            arrayHeader(byteLength: 20 + payload, elemOID: OID_TEXT, count: items.count)
            for s in items {
                i32(Int32(s.count))
                buf.append(s)
            }
        }
    }

    /// Bind (binary parameters and results) and Execute of a prepared statement, on the unnamed portal.
    mutating func bindAndExec(_ statement: String, _ params: [BindParam]) {
        let at = startMessage(0x42)
        buf.append(0)
        cstr(statement)
        i16(1)
        i16(1)
        i16(Int16(params.count))
        for p in params { encode(p) }
        i16(1)
        i16(1)
        finishMessage(at)
        let exec = startMessage(0x45)
        buf.append(0)
        i32(0)
        finishMessage(exec)
    }

    mutating func writeSync() {
        let at = startMessage(0x53)
        finishMessage(at)
    }

    mutating func clear() {
        buf.removeAll(shrinkingAbove: 1024 * 1024, to: 128 * 1024)
    }
}

struct Cell: Sendable {
    var offset: UInt32
    var len: Int32
    static let null = Cell(offset: 0, len: -1)
    @inline(__always) var isNull: Bool { len < 0 }
}

struct RowSpan: Sendable {
    var start: UInt32
    var count: UInt16
}

struct ExecOutcome {
    var rowStart: UInt32
    var rowCount: UInt32
    var error: SqlStateErr?
}

/// Every DataRow of one pipelined round trip: the cells' bytes in one arena, cells and rows as offsets into it.
struct PipelineBuf: ~Copyable {
    var data = ByteBuffer(capacity: 128 * 1024)
    var cols: [Cell] = []
    var rows: [RowSpan] = []
    var results: [ExecOutcome] = []

    init() {
        cols.reserveCapacity(4096)
        rows.reserveCapacity(1024)
        results.reserveCapacity(32)
    }

    mutating func clear() {
        data.removeAll(shrinkingAbove: 4 * 1024 * 1024, to: 512 * 1024)
        cols.removeAll(keepingCapacity: true)
        rows.removeAll(keepingCapacity: true)
        results.removeAll(keepingCapacity: true)
    }

    /// The indices into `rows` of statement `i`'s rows.
    @inline(__always) func resultRows(_ i: Int) -> Range<Int> {
        let r = results[i]
        return Int(r.rowStart)..<Int(r.rowStart + r.rowCount)
    }

    @inline(__always) func cell(_ row: RowSpan, _ k: Int) -> Cell { cols[Int(row.start) + k] }

    /// A cell's bytes; empty for NULL (the Rust's `bytes(c).unwrap_or(b"")`).
    @_lifetime(borrow self)
    func text(_ c: Cell) -> Span<UInt8> {
        data.span.extracting(Int(c.offset)..<(Int(c.offset) + max(Int(c.len), 0)))
    }

    /// A cell's bytes; nil for NULL.
    @_lifetime(borrow self)
    func bytes(_ c: Cell) -> Span<UInt8>? {
        c.isNull ? nil : data.span.extracting(Int(c.offset)..<(Int(c.offset) + Int(c.len)))
    }

    @inline(__always) func i64(_ c: Cell) -> Int64 {
        data.withBytes { raw in
            switch c.len {
            case 8: Int64(bigEndian: raw.loadUnaligned(fromByteOffset: Int(c.offset), as: Int64.self))
            case 4: Int64(Int32(bigEndian: raw.loadUnaligned(fromByteOffset: Int(c.offset), as: Int32.self)))
            default: 0
            }
        }
    }

    @inline(__always) func i64(_ row: RowSpan, _ k: Int) -> Int64 { i64(cell(row, k)) }

    /// A copy of a cell's bytes; nil for NULL.
    func copy(_ c: Cell) -> [UInt8]? {
        c.isNull ? nil : data.withBytes { Array($0[Int(c.offset)..<(Int(c.offset) + Int(c.len))]) }
    }
}

/// Calls `body` with each element of a one-dimensional binary array (`iter_binary_array`).
func forEachArrayElement(_ raw: Span<UInt8>, _ body: (Span<UInt8>) -> Void) {
    guard raw.count >= 12 else { return }
    raw.withUnsafeBytes { bytes in
        let ndim = Int32(bigEndian: bytes.loadUnaligned(fromByteOffset: 0, as: Int32.self))
        guard ndim > 0, bytes.count >= 16 else { return }
        var remaining = max(Int(Int32(bigEndian: bytes.loadUnaligned(fromByteOffset: 12, as: Int32.self))), 0)
        var pos = 12 + 8 * Int(ndim)
        while remaining > 0 {
            remaining -= 1
            guard pos + 4 <= bytes.count else { return }
            let len = Int32(bigEndian: bytes.loadUnaligned(fromByteOffset: pos, as: Int32.self))
            pos += 4
            if len < 0 { continue }
            guard pos + Int(len) <= bytes.count else { return }
            body(raw.extracting(pos..<(pos + Int(len))))
            pos += Int(len)
        }
    }
}

private func decodeError(_ body: Span<UInt8>) -> SqlStateErr {
    var code = ""
    var message = ""
    var start = 0
    while start < body.count {
        let end = findByte(body, 0, from: start) ?? body.count
        if end > start {
            let field = body.extracting((start + 1)..<end).withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
            switch body[start] {
            case 0x43: code = field
            case 0x4D: message = field
            default: break
            }
        }
        start = end + 1
    }
    return SqlStateErr(code: code, message: message)
}

/// One Postgres connection. It owns its socket: noncopyable, closed in `deinit`, never shared.
struct PgConn: ~Copyable {
    private let fd: Int32
    private var rx = ByteBuffer()
    private var rpos = 0
    var tx = TxBuf()

    deinit { _ = sys_close(fd) }

    private init(fd: Int32) {
        self.fd = fd
        rx = ByteBuffer(capacity: 64 * 1024)
    }

    static func connect(_ ep: DbEndpoint) throws(PgError) -> PgConn {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Sys.SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(ep.host, String(ep.port), &hints, &list)
        guard rc == 0, let first = list else { throw .io("getaddrinfo \(ep.host): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(list) }
        var fd: Int32 = -1
        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate, fd < 0 {
            candidate = info.pointee.ai_next
            let s = sys_socket(info.pointee.ai_family, Sys.SOCK_STREAM | Sys.SOCK_CLOEXEC, 0)
            if s < 0 { continue }
            if Glibc.connect(s, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
                fd = s
            } else {
                _ = sys_close(s)
            }
        }
        guard fd >= 0 else { throw .io("connect \(ep.host):\(ep.port): \(String(cString: strerror(errno)))") }
        setNoDelay(fd)
        var conn = PgConn(fd: fd)

        var startup: [UInt8] = [0, 0, 0, 0]
        withUnsafeBytes(of: Int32(196_608).bigEndian) { startup.append(contentsOf: $0) }
        let params: [(String, String)] = [
            ("user", ep.user), ("database", ep.database), ("client_encoding", "UTF8"), ("DateStyle", "ISO"),
            ("plan_cache_mode", "force_generic_plan"), ("jit", "off"), ("max_parallel_workers_per_gather", "0"),
            ("work_mem", "32MB"), ("random_page_cost", "1.1"), ("effective_io_concurrency", "200"),
        ]
        for (k, v) in params {
            startup.append(contentsOf: k.utf8)
            startup.append(0)
            startup.append(contentsOf: v.utf8)
            startup.append(0)
        }
        startup.append(0)
        withUnsafeBytes(of: Int32(startup.count).bigEndian) { b in for i in 0..<4 { startup[i] = b[i] } }
        try conn.send(startup)
        try conn.authenticate(ep)
        return conn
    }

    private func send(_ bytes: [UInt8]) throws(PgError) {
        let fd = self.fd
        // The error comes back as a value: a typed-throws closure through `rethrows` crashes Swift 6.4's SILGen.
        let failure = bytes.withUnsafeBytes { raw -> SystemError? in
            do throws(SystemError) { try writeAll(fd, raw) } catch { return error }
            return nil
        }
        if let failure { throw .io("\(failure)") }
    }

    private func sendPacket(_ tag: UInt8, _ payload: [UInt8]) throws(PgError) {
        var pkt: [UInt8] = [tag]
        withUnsafeBytes(of: Int32(payload.count + 4).bigEndian) { pkt.append(contentsOf: $0) }
        pkt.append(contentsOf: payload)
        try send(pkt)
    }

    /// The next message: its tag and the range of its payload in `rx` (valid until the next call).
    private mutating func nextFrame() throws(PgError) -> (tag: UInt8, payload: Range<Int>) {
        try ensure(5)
        let tag = rx[rpos]
        let len = rx.withBytes { Int(Int32(bigEndian: $0.loadUnaligned(fromByteOffset: rpos + 1, as: Int32.self))) }
        try ensure(1 + len)
        let start = rpos + 5
        rpos += 1 + len
        return (tag, start..<(start + len - 4))
    }

    private mutating func ensure(_ needed: Int) throws(PgError) {
        if rx.count - rpos >= needed { return }
        if rpos == rx.count {
            rx.removeAll()
        } else if rpos > 0 {
            rx.removeFirst(rpos)
        }
        rpos = 0
        while rx.count < needed {
            let fd = self.fd
            let n = rx.appendSpare(maximum: max(64 * 1024, needed - rx.count)) { spare in
                sys_read(fd, spare.baseAddress, spare.count)
            }
            if n == 0 { throw .io("postgres connection closed") }
            if n < 0 {
                if errno == Sys.EINTR { continue }
                throw .io("read: \(String(cString: strerror(errno)))")
            }
        }
    }

    private func payload(_ r: Range<Int>) -> [UInt8] { rx.withBytes { Array($0[r]) } }

    private mutating func authenticate(_ ep: DbEndpoint) throws(PgError) {
        var scram: (bare: String, nonce: String)?
        var expectedServerSignature: [UInt8]?
        let password = Array(ep.password.utf8)
        while true {
            let (tag, range) = try nextFrame()
            let body = payload(range)
            switch tag {
            case 0x52:
                let method = Int32(bigEndian: body.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
                switch method {
                case 0:
                    break
                case 3:
                    try sendPacket(0x70, password + [0])
                case 10:
                    let mechanisms = String(decoding: body[4...], as: UTF8.self)
                    guard mechanisms.split(separator: "\0").contains("SCRAM-SHA-256") else {
                        throw .wire("unsupported SASL mechanisms: \(mechanisms)")
                    }
                    var raw = [UInt8](repeating: 0, count: 18)
                    guard raw.withUnsafeMutableBytes({ fillRandom($0) }) else { throw .wire("getrandom failed") }
                    let nonce = String(decoding: b64StdEncode(raw), as: UTF8.self)
                    let bare = "n=,r=\(nonce)"
                    let first = Array("n,,\(bare)".utf8)
                    var msg = Array("SCRAM-SHA-256\0".utf8)
                    withUnsafeBytes(of: Int32(first.count).bigEndian) { msg.append(contentsOf: $0) }
                    msg.append(contentsOf: first)
                    try sendPacket(0x70, msg)
                    scram = (bare, nonce)
                case 11:
                    guard let (bare, nonce) = scram else { throw .wire("SASL state") }
                    let serverFirst = String(decoding: body[4...], as: UTF8.self)
                    var rToken: String?
                    var salt: [UInt8]?
                    var iterations: UInt32?
                    for part in serverFirst.split(separator: ",", omittingEmptySubsequences: false) {
                        if part.hasPrefix("r=") {
                            rToken = String(part.dropFirst(2))
                        } else if part.hasPrefix("s=") {
                            salt = Array(part.dropFirst(2).utf8).withUnsafeBufferPointer { b64StdDecode(Span(_unsafeElements: $0)) }
                        } else if part.hasPrefix("i=") {
                            iterations = UInt32(part.dropFirst(2))
                        }
                    }
                    guard let rToken, let salt, let iterations, rToken.hasPrefix(nonce) else {
                        throw .wire("invalid SCRAM server-first")
                    }
                    var u = (salt + [0, 0, 0, 1]).withUnsafeBytes { hmacSHA256(key: password, $0) }
                    var salted = u
                    for _ in 1..<max(iterations, 1) {
                        u = u.span.withUnsafeBytes { hmacSHA256(key: password, $0) }
                        for b in 0..<32 { salted[b] ^= u[b] }
                    }
                    let saltedKey = Array(salted.span.withUnsafeBufferPointer { $0 })
                    let clientKey = Array("Client Key".utf8).withUnsafeBytes { hmacSHA256(key: saltedKey, $0) }
                    let storedKey = clientKey.span.withUnsafeBytes { sha256Digest($0) }
                    let noProof = "c=biws,r=\(rToken)"
                    let authMessage = Array("\(bare),\(serverFirst),\(noProof)".utf8)
                    let clientSignature = authMessage.withUnsafeBytes {
                        hmacSHA256(key: Array(storedKey.span.withUnsafeBufferPointer { $0 }), $0)
                    }
                    var proof = Array(clientKey.span.withUnsafeBufferPointer { $0 })
                    for b in 0..<32 { proof[b] ^= clientSignature[b] }
                    let serverKey = Array("Server Key".utf8).withUnsafeBytes { hmacSHA256(key: saltedKey, $0) }
                    let serverSignature = authMessage.withUnsafeBytes {
                        hmacSHA256(key: Array(serverKey.span.withUnsafeBufferPointer { $0 }), $0)
                    }
                    expectedServerSignature = Array(serverSignature.span.withUnsafeBufferPointer { $0 })
                    let finalMessage = noProof + ",p=" + String(decoding: b64StdEncode(proof), as: UTF8.self)
                    try sendPacket(0x70, Array(finalMessage.utf8))
                case 12:
                    let serverFinal = String(decoding: body[4...], as: UTF8.self)
                    let verifier = serverFinal.hasPrefix("v=")
                        ? Array(serverFinal.dropFirst(2).utf8).withUnsafeBufferPointer { b64StdDecode(Span(_unsafeElements: $0)) }
                        : nil
                    guard let verifier, verifier == expectedServerSignature else {
                        throw .wire("SCRAM server signature mismatch")
                    }
                default:
                    throw .wire("unsupported auth code \(method)")
                }
            case 0x45:
                throw .server(body.withUnsafeBufferPointer { decodeError(Span(_unsafeElements: $0)) })
            case 0x5A:
                return
            default:
                break
            }
        }
    }

    mutating func flush() throws(PgError) {
        let fd = self.fd
        let failure = tx.buf.withBytes { raw -> SystemError? in
            do throws(SystemError) { try writeAll(fd, raw) } catch { return error }
            return nil
        }
        if let failure { throw .io("\(failure)") }
        tx.clear()
    }

    /// Reads one pipeline's replies, up to its ReadyForQuery, into `out`; statements an earlier error skipped are
    /// filled in as errors so every one of the `expected` has an outcome.
    mutating func readPipeline(into out: inout PipelineBuf, expected: Int) throws(PgError) {
        out.clear()
        var rowStart: UInt32 = 0
        loop: while true {
            let (tag, range) = try nextFrame()
            switch tag {
            case 0x44:
                rx.withBytes { raw in
                    var p = range.lowerBound
                    let ncols = UInt16(bigEndian: raw.loadUnaligned(fromByteOffset: p, as: UInt16.self))
                    p += 2
                    let colStart = UInt32(out.cols.count)
                    for _ in 0..<ncols {
                        let len = Int32(bigEndian: raw.loadUnaligned(fromByteOffset: p, as: Int32.self))
                        p += 4
                        if len < 0 {
                            out.cols.append(.null)
                        } else {
                            let offset = UInt32(out.data.count)
                            out.data.append(UnsafeRawBufferPointer(rebasing: raw[p..<(p + Int(len))]))
                            p += Int(len)
                            out.cols.append(Cell(offset: offset, len: len))
                        }
                    }
                    out.rows.append(RowSpan(start: colStart, count: ncols))
                }
            case 0x43:
                let total = UInt32(out.rows.count)
                out.results.append(ExecOutcome(rowStart: rowStart, rowCount: total - rowStart, error: nil))
                rowStart = total
            case 0x45:
                let total = UInt32(out.rows.count)
                let err = rx.withBytes { decodeError(Span(_unsafeElements: UnsafeBufferPointer(rebasing: $0.bindMemory(to: UInt8.self)[range]))) }
                out.results.append(ExecOutcome(rowStart: rowStart, rowCount: total - rowStart, error: err))
                rowStart = total
            case 0x49:
                out.results.append(ExecOutcome(rowStart: rowStart, rowCount: 0, error: nil))
            case 0x5A:
                break loop
            case 0x31, 0x32, 0x33, 0x6E, 0x74, 0x54, 0x4E, 0x53, 0x41, 0x73:
                break
            default:
                throw .wire("unexpected frame \(Character(Unicode.Scalar(tag)))")
            }
        }
        while out.results.count < expected {
            out.results.append(ExecOutcome(rowStart: rowStart, rowCount: 0,
                                           error: SqlStateErr(code: "skipped", message: "aborted by earlier pipeline error")))
        }
    }

    mutating func prepareBatch(_ statements: [PreparedDef]) throws(PgError) {
        for s in statements { tx.writeParse(s.name, s.sql, s.oids) }
        tx.writeSync()
        try flush()
        while true {
            let (tag, range) = try nextFrame()
            switch tag {
            case 0x45:
                let err = payload(range).withUnsafeBufferPointer { decodeError(Span(_unsafeElements: $0)) }
                while try nextFrame().tag != 0x5A {}
                throw .server(err)
            case 0x5A:
                return
            default:
                break
            }
        }
    }
}
