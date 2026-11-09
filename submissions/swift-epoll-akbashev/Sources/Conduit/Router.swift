// router.rs: what a request asks for, decided on the reactor that parsed it. Reads, writes and bcrypt work become
// value types (Sendable: their strings are byte arrays) that the reactor hands the scheduler once per epoll tick;
// everything that can be answered without Postgres (a bad token, a bad body, a 404) is answered on the spot.

/// Where a reply goes: the reactor, the connection slot, and that slot's epoch, so a reply for a connection that
/// closed in the meantime (and whose slot was reused) is dropped.
struct ReplyAddr: Hashable, Sendable {
    let worker: UInt16
    let slot: UInt32
    let epoch: UInt32
}

struct OutgoingReply: Sendable {
    let addr: ReplyAddr
    let status: UInt16
    let body: Body

    enum Body: Sendable {
        /// Built once and shared by every reply in a batch that has the same one (an array is reference counted, so
        /// this is the Rust's `Arc<[u8]>` as well as its `Vec<u8>`).
        case bytes([UInt8])
        /// These bytes of the buffer its delivery lends along: a read lane writes a batch's bodies into one buffer of
        /// its own, and replies that come out identical share their bytes.
        case slice(Range<Int32>)
        /// An error's message: the reactor writes the body.
        case error(StaticString)
    }

    init(addr: ReplyAddr, status: UInt16, body: [UInt8]) {
        self.addr = addr
        self.status = status
        self.body = .bytes(body)
    }

    init(addr: ReplyAddr, status: UInt16, slice: Range<Int32>) {
        self.addr = addr
        self.status = status
        body = .slice(slice)
    }

    init(addr: ReplyAddr, status: UInt16, error message: StaticString) {
        self.addr = addr
        self.status = status
        body = .error(message)
    }
}

enum ReadOp: Sendable {
    case tags
    case currentUser(id: Int64, token: [UInt8])
    case login(email: SmallBytes, password: [UInt8])
    case profile(username: SmallBytes)
    case articleBySlug(slug: SmallBytes)
    /// A write's read-back; `knownFav` is the favorited flag when the write just set it (a favorite or unfavorite),
    /// so the lane needn't look it up.
    case articleById(id: Int64, knownFav: Bool?)
    case comments(slug: SmallBytes)
    case global(lim: Int64, off: Int64)
    case byTag(tag: SmallBytes, lim: Int64, off: Int64)
    case byAuthor(username: SmallBytes, lim: Int64, off: Int64)
    case byFavorited(username: SmallBytes, lim: Int64, off: Int64)
    case feed(lim: Int64, off: Int64)
}

struct ReadTask: Sendable {
    let op: ReadOp
    let viewer: Int64
    let addr: ReplyAddr
}

enum WriteOp: Sendable {
    case register(username: [UInt8], email: [UInt8], hash: [UInt8])
    case updateUser(token: [UInt8], email: [UInt8]?, username: [UInt8]?, hash: [UInt8]?, bio: [UInt8]?, image: [UInt8]?)
    case follow(username: [UInt8], on: Bool)
    case favorite(slug: [UInt8], on: Bool)
    case createArticle(title: [UInt8], description: [UInt8], body: [UInt8], tags: [[UInt8]])
    case updateArticle(slug: [UInt8], title: [UInt8]?, description: [UInt8]?, body: [UInt8]?)
    case deleteArticle(slug: [UInt8])
    case createComment(slug: [UInt8], body: [UInt8])
    case deleteComment(slug: [UInt8], id: Int64)
}

struct WriteTask: Sendable {
    var op: WriteOp
    let viewer: Int64
    let addr: ReplyAddr
}

struct UserRecord: Sendable {
    let id: Int64
    let username: [UInt8]
    let email: [UInt8]
    let bio: [UInt8]?
    let image: [UInt8]?
}

enum CryptoTask: Sendable {
    case verifyLogin(password: [UInt8], hash: [UInt8], user: UserRecord, addr: ReplyAddr)
    case hashPassword(password: [UInt8], write: WriteTask)

    var addr: ReplyAddr {
        switch self {
        case .verifyLogin(_, _, _, let addr): addr
        case .hashPassword(_, let write): write.addr
        }
    }
}

/// What a reactor sends the scheduler after an epoll tick.
struct Submission: Sendable {
    var reads: [ReadTask] = []
    var readsFront: [ReadTask] = []
    var writes: [WriteTask] = []
    var writesFront: [WriteTask] = []
    var crypto: [CryptoTask] = []
    /// Connections that closed with a request queued: the scheduler drops their reads and bcrypt work.
    var cancelled: [ReplyAddr] = []

    var isEmpty: Bool {
        reads.isEmpty && readsFront.isEmpty && writes.isEmpty && writesFront.isEmpty && crypto.isEmpty && cancelled.isEmpty
    }

    /// Empties every list, keeping their memory.
    mutating func removeAll() {
        reads.removeAll(keepingCapacity: true)
        readsFront.removeAll(keepingCapacity: true)
        writes.removeAll(keepingCapacity: true)
        writesFront.removeAll(keepingCapacity: true)
        crypto.removeAll(keepingCapacity: true)
        cancelled.removeAll(keepingCapacity: true)
    }
}

extension HTTP {
    /// A parsed request, borrowing the bytes it was parsed from (the reactor's read buffer, or a de-chunked body): it
    /// can't outlive them, so routing reads them in place.
    struct Request: ~Escapable {
        let method: Span<UInt8>
        let path: Span<UInt8>
        let query: Span<UInt8>
        let auth: Span<UInt8>?
        let body: Span<UInt8>

        @_lifetime(copy method, copy path, copy query, copy auth, copy body)
        init(method: Span<UInt8>, path: Span<UInt8>, query: Span<UInt8>, auth: Span<UInt8>?, body: Span<UInt8>) {
            self.method = method
            self.path = path
            self.query = query
            self.auth = auth
            self.body = body
        }
    }
}

extension JSON {
    /// The RealWorld error body, `{"errors":{"body":["<message>"]}}`.
    static func writeError(_ out: inout ByteBuffer, _ message: StaticString) {
        out.append("{\"errors\":{\"body\":[")
        writeString(&out, message)
        out.append("]}}")
    }
}

/// Requests to their work (router.rs): what needs no database is answered here.
enum Router {
    /// What routing decided, used once: an answer now (an error, whose body the reactor writes, or a constant one), or
    /// work for the lanes.
    enum Dispatch: ~Copyable {
        case error(UInt16, StaticString)
        case constant(UInt16, StaticString)
        case read(ReadTask)
        case readFront(ReadTask)
        case write(WriteTask)
        case crypto(CryptoTask)
    }

    @inline(__always) private static func failNow(_ status: UInt16, _ message: StaticString) -> Dispatch {
        .error(status, message)
    }

    @inline(__always) private static func hexNibble(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: b - 0x30
        case 0x61...0x66: b - 0x61 + 10
        case 0x41...0x46: b - 0x41 + 10
        default: nil
        }
    }

    private static func percentDecodeRaw(_ src: Span<UInt8>, plus: Bool) -> [UInt8]? {
        var hasEscape = false
        for i in 0..<src.count where src[i] == 0x25 || (plus && src[i] == 0x2B) {
            hasEscape = true
            break
        }
        if !hasEscape {
            return Bytes.isValidUTF8(src) ? src.withUnsafeBufferPointer { Array($0) } : nil
        }
        var out: [UInt8] = []
        out.reserveCapacity(src.count)
        var i = 0
        while i < src.count {
            switch src[i] {
            case 0x25:
                guard i + 2 < src.count, let hi = hexNibble(src[i + 1]), let lo = hexNibble(src[i + 2]) else { return nil }
                out.append(hi << 4 | lo)
                i += 3
            case 0x2B where plus:
                out.append(0x20)
                i += 1
            case let b:
                out.append(b)
                i += 1
            }
        }
        return Bytes.isValidUTF8(out.span) ? out : nil
    }

    /// Percent-decoded, valid UTF-8 and free of NUL, or nil.
    private static func percentDecode(_ src: Span<UInt8>, plus: Bool) -> [UInt8]? {
        guard let decoded = percentDecodeRaw(src, plus: plus), !decoded.contains(0) else { return nil }
        return decoded
    }

    /// `percentDecode` for a read's key: copied straight into a `SmallBytes` when nothing is escaped.
    private static func percentDecodeKey(_ src: Span<UInt8>, plus: Bool) -> SmallBytes? {
        for i in 0..<src.count where src[i] == 0x25 || (plus && src[i] == 0x2B) || src[i] == 0 {
            return percentDecode(src, plus: plus).map { SmallBytes($0.span) }
        }
        return Bytes.isValidUTF8(src) ? SmallBytes(src) : nil
    }

    private static func parsePosInt(_ raw: Span<UInt8>) -> Int64? {
        guard raw.count > 0 else { return nil }
        var value: Int64 = 0
        for i in 0..<raw.count {
            let b = raw[i]
            guard (0x30...0x39).contains(b) else { return nil }
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (s, o2) = m.addingReportingOverflow(Int64(b - 0x30))
            if o1 || o2 { return nil }
            value = s
        }
        return value
    }

    private struct ListQuery {
        var seenLimit = false
        var limit: Int64?
        var seenOffset = false
        var offset: Int64?
        var tag: SmallBytes?
        var author: SmallBytes?
        var favorited: SmallBytes?
        var impossibleFilter = false
    }

    @inline(__always) private static func hasEscape(_ s: Span<UInt8>) -> Bool {
        for i in 0..<s.count where s[i] == 0x25 || s[i] == 0x2B { return true }
        return false
    }

    /// The list query parameters routing reads.
    private enum QueryName {
        case limit, offset, tag, author, favorited, other

        init(_ s: Span<UInt8>) {
            self = Bytes.equal(s, "limit") ? .limit : Bytes.equal(s, "offset") ? .offset : Bytes.equal(s, "tag") ? .tag
                : Bytes.equal(s, "author") ? .author : Bytes.equal(s, "favorited") ? .favorited : .other
        }
    }

    private static func scanListQuery(_ raw: Span<UInt8>) -> ListQuery {
        var q = ListQuery()
        var start = 0
        while start <= raw.count, raw.count > 0 {
            let end = Bytes.find(raw, 0x26, from: start) ?? raw.count
            defer { start = end + 1 }
            if end == start { continue }
            let pair = raw.extracting(start..<end)
            let eq = Bytes.find(pair, 0x3D) ?? pair.count
            let k = pair.extracting(0..<eq)
            let v = pair.extracting(min(eq + 1, pair.count)..<pair.count)
            // The name is compared where it lies; only an escaped one (practically never) is decoded first.
            let name: QueryName
            if !hasEscape(k) {
                name = QueryName(k)
            } else {
                guard let decoded = percentDecode(k, plus: true) else { continue }
                name = QueryName(decoded.span)
            }
            let decodeInt = { (v: Span<UInt8>) -> Int64? in
                hasEscape(v) ? percentDecode(v, plus: true).flatMap { parsePosInt($0.span) } : parsePosInt(v)
            }
            switch name {
            case .limit:
                if !q.seenLimit {
                    q.seenLimit = true
                    q.limit = decodeInt(v)
                }
            case .offset:
                if !q.seenOffset {
                    q.seenOffset = true
                    q.offset = decodeInt(v)
                }
            case .tag, .author, .favorited:
                let current = name == .tag ? q.tag : name == .author ? q.author : q.favorited
                if current == nil {
                    var value = percentDecodeKey(v, plus: true)
                    if value == nil {
                        value = SmallBytes(Span())
                        q.impossibleFilter = true
                    }
                    switch name {
                    case .tag: q.tag = value
                    case .author: q.author = value
                    default: q.favorited = value
                    }
                }
            case .other:
                continue
            }
        }
        return q
    }

    private static func validatePageBounds(_ q: ListQuery) -> (lim: Int64, off: Int64)? {
        let lim: Int64
        if q.seenLimit {
            guard let l = q.limit, (1...100).contains(l) else { return nil }
            lim = l
        } else {
            lim = 20
        }
        let off: Int64
        if q.seenOffset {
            guard let o = q.offset else { return nil }
            off = min(o, Int64.max / 2)
        } else {
            off = 0
        }
        return (lim, off)
    }

    /// A request body's envelope, `{"<rootKey>":{...}}`, read in place: where the inner object is in the body, and
    /// where in it the fields asked for are (by their keys' positions).
    private struct Envelope<let n: Int> {
        let range: Range<Int>
        let fields: JSON.Found<n>
    }

    private static func unwrapJsonEnvelope<let n: Int>(_ body: Span<UInt8>, _ rootKey: StaticString,
                                                       _ keys: InlineArray<n, StaticString>) -> Envelope<n>? {
        guard let outer = JSON.scan(body, keys: [rootKey]), let root = outer[0], root.kind == .object,
              let fields = JSON.scan(body.extracting(root.value), keys: keys) else { return nil }
        return Envelope(range: root.value, fields: fields)
    }

    /// The fields `keys` of the object under `rootKey`, or the message to fail the request with (422).
    private static func parseValidEnvelope<let n: Int>(_ body: Span<UInt8>, _ rootKey: StaticString,
                                                       _ keys: InlineArray<n, StaticString>) -> (Envelope<n>?, StaticString) {
        guard let envelope = unwrapJsonEnvelope(body, rootKey, keys) else { return (nil, "invalid request body") }
        if envelope.fields.hasNul { return (nil, "strings must not contain NUL") }
        return (envelope, "")
    }

    private enum Field {
        case absent
        case value([UInt8])
        case invalid

        var optional: [UInt8]?? {
            switch self {
            case .absent: .some(nil)
            case .value(let v): .some(v)
            case .invalid: nil
            }
        }
    }

    /// The envelope's `i`th field asked for, a string, copied (it travels to a lane); absent or null, or something else
    /// (invalid).
    private static func optionalStrField<let n: Int>(_ body: Span<UInt8>, _ envelope: Envelope<n>, _ i: Int, nonEmpty: Bool) -> Field {
        let src = body.extracting(envelope.range)
        guard let field = envelope.fields[i] else { return .absent }
        switch field.kind {
        case .null:
            return .absent
        case .string:
            let value = JSON.ownedString(src, field)
            return nonEmpty && value.isEmpty ? .invalid : .value(value)
        default:
            return .invalid
        }
    }

    private static func requiredStrField<let n: Int>(_ body: Span<UInt8>, _ envelope: Envelope<n>, _ i: Int) -> [UInt8]? {
        if case .value(let v) = optionalStrField(body, envelope, i, nonEmpty: true) { v } else { nil }
    }

    private enum AuthState {
        case anonymous
        case rejected
        case verified(Int64)
    }

    @inline(__always) private static func verifyAuthHeader(_ signer: TokenSigner, _ header: Span<UInt8>?) -> AuthState {
        guard let header else { return .anonymous }
        guard header.count >= 6, Bytes.equal(header.extracting(0..<6), "Token ") else { return .rejected }
        return signer.verify(header.extracting(6..<header.count)).map(AuthState.verified) ?? .rejected
    }

    /// The token after "Token ", copied (for the replies that echo it).
    @inline(__always) private static func tokenBytes(_ header: Span<UInt8>?) -> [UInt8] {
        guard let header else { return [] }
        return header.extracting(6..<header.count).withUnsafeBufferPointer { Array($0) }
    }

    private static let bcryptMaxBytes = 72

    static func route(_ signer: TokenSigner, _ req: borrowing HTTP.Request, _ addr: ReplyAddr) -> Dispatch {
        let path = req.path
        guard path.count >= 5, Bytes.equal(path.extracting(0..<5), "/api/") else { return failNow(404, "not found") }
        let sub = path.extracting(5..<path.count)
        var bounds = InlineArray<5, (Int, Int)>(repeating: (0, 0))
        var n = 0
        var start = 0
        while true {
            let end = Bytes.find(sub, 0x2F, from: start) ?? sub.count
            if n >= 5 { return failNow(404, "not found") }
            bounds[n] = (start, end)
            n += 1
            if end == sub.count { break }
            start = end + 1
        }
        func segIs(_ i: Int, _ s: StaticString) -> Bool {
            Bytes.equal(sub.extracting(bounds[i].0..<bounds[i].1), s)
        }
        func segEmpty(_ i: Int) -> Bool { bounds[i].0 == bounds[i].1 }
        func decodeSeg(_ i: Int) -> [UInt8]? {
            segEmpty(i) ? nil : percentDecode(sub.extracting(bounds[i].0..<bounds[i].1), plus: false)
        }
        func decodeKey(_ i: Int) -> SmallBytes? {
            segEmpty(i) ? nil : percentDecodeKey(sub.extracting(bounds[i].0..<bounds[i].1), plus: false)
        }
        let m = req.method
        let isGet = Bytes.equal(m, "GET"), isPost = Bytes.equal(m, "POST"), isPut = Bytes.equal(m, "PUT"), isDelete = Bytes.equal(m, "DELETE")

        func read(_ op: ReadOp, _ viewer: Int64) -> Dispatch { .read(ReadTask(op: op, viewer: viewer, addr: addr)) }
        func write(_ op: WriteOp, _ viewer: Int64) -> Dispatch { .write(WriteTask(op: op, viewer: viewer, addr: addr)) }
        func optional(_ make: (Int64) -> Dispatch) -> Dispatch {
            switch verifyAuthHeader(signer, req.auth) {
            case .verified(let v): make(v)
            case .anonymous: make(0)
            case .rejected: failNow(401, "unauthorized")
            }
        }
        func required(_ make: (Int64) -> Dispatch) -> Dispatch {
            if case .verified(let v) = verifyAuthHeader(signer, req.auth) { make(v) } else { failNow(401, "unauthorized") }
        }

        if isGet {
            if n == 1 && segIs(0, "tags") { return read(.tags, 0) }
            if n == 1 && segIs(0, "articles") { return optional { routeArticleList(req.query, $0, addr) } }
            if n == 2 && segIs(0, "articles") && segIs(1, "feed") {
                return required { v in
                    guard let (lim, off) = validatePageBounds(scanListQuery(req.query)) else {
                        return failNow(422, "invalid pagination parameters")
                    }
                    return read(.feed(lim: lim, off: off), v)
                }
            }
            if n == 2 && segIs(0, "articles") && !segEmpty(1) {
                guard let slug = decodeKey(1) else { return failNow(404, "not found") }
                return optional { read(.articleBySlug(slug: slug), $0) }
            }
            if n == 3 && segIs(0, "articles") && !segEmpty(1) && segIs(2, "comments") {
                guard let slug = decodeKey(1) else { return failNow(404, "not found") }
                return optional { read(.comments(slug: slug), $0) }
            }
            if n == 2 && segIs(0, "profiles") && !segEmpty(1) {
                guard let username = decodeKey(1) else { return failNow(404, "not found") }
                return optional { read(.profile(username: username), $0) }
            }
            if n == 1 && segIs(0, "user") {
                return required { uid in read(.currentUser(id: uid, token: tokenBytes(req.auth)), uid) }
            }
        }
        if (isPost || isDelete) && n == 3 && segIs(0, "articles") && !segEmpty(1) && segIs(2, "favorite") {
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            return required { write(.favorite(slug: slug, on: isPost), $0) }
        }
        if isPost && n == 3 && segIs(0, "articles") && !segEmpty(1) && segIs(2, "comments") {
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            return required { v in
                let (obj, failure) = parseValidEnvelope(req.body, "comment", ["body"])
                guard let obj else { return failNow(422, failure) }
                guard let body = requiredStrField(req.body, obj, 0) else { return failNow(422, "comment body required") }
                return write(.createComment(slug: slug, body: body), v)
            }
        }
        if (isPost || isDelete) && n == 3 && segIs(0, "profiles") && !segEmpty(1) && segIs(2, "follow") {
            guard let username = decodeSeg(1) else { return failNow(404, "not found") }
            return required { write(.follow(username: username, on: isPost), $0) }
        }
        if isPost && n == 1 && segIs(0, "articles") {
            return required { handleCreateArticle(req.body, $0, addr) }
        }
        if isPut && n == 2 && segIs(0, "articles") && !segEmpty(1) {
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            return required { handleUpdateArticle(req.body, slug, $0, addr) }
        }
        if isDelete && n == 2 && segIs(0, "articles") && !segEmpty(1) {
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            return required { write(.deleteArticle(slug: slug), $0) }
        }
        if isDelete && n == 4 && segIs(0, "articles") && !segEmpty(1) && segIs(2, "comments") && !segEmpty(3) {
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            let id = decodeSeg(3).flatMap { parsePosInt($0.span) }
            return required { v in
                guard let id else { return failNow(404, "comment not found") }
                return write(.deleteComment(slug: slug, id: id), v)
            }
        }
        if isPost && n == 2 && segIs(0, "users") && segIs(1, "login") { return handleLogin(req.body, addr) }
        if isPost && n == 1 && segIs(0, "users") { return handleRegister(req.body, addr) }
        if isPut && n == 1 && segIs(0, "user") {
            return required { uid in handleUpdateUser(req.body, uid, tokenBytes(req.auth), addr) }
        }
        return failNow(404, "not found")
    }

    private static func routeArticleList(_ rawQuery: Span<UInt8>, _ viewer: Int64, _ addr: ReplyAddr) -> Dispatch {
        let q = scanListQuery(rawQuery)
        guard let (lim, off) = validatePageBounds(q) else { return failNow(422, "invalid pagination parameters") }
        if q.impossibleFilter { return .constant(200, "{\"articles\":[],\"articlesCount\":0}") }
        let op: ReadOp
        if let tag = q.tag, !tag.isEmpty {
            op = .byTag(tag: tag, lim: lim, off: off)
        } else if let username = q.author, !username.isEmpty {
            op = .byAuthor(username: username, lim: lim, off: off)
        } else if let username = q.favorited, !username.isEmpty {
            op = .byFavorited(username: username, lim: lim, off: off)
        } else {
            op = .global(lim: lim, off: off)
        }
        return .read(ReadTask(op: op, viewer: viewer, addr: addr))
    }

    private static func handleRegister(_ body: Span<UInt8>, _ addr: ReplyAddr) -> Dispatch {
        let (obj, failure) = parseValidEnvelope(body, "user", ["username", "email", "password"])
        guard let obj else { return failNow(422, failure) }
        guard let username = requiredStrField(body, obj, 0), let email = requiredStrField(body, obj, 1),
              let password = requiredStrField(body, obj, 2) else {
            return failNow(422, "username, email, and password are required")
        }
        if password.count > bcryptMaxBytes { return failNow(422, "password exceeds maximum length") }
        let task = WriteTask(op: .register(username: username, email: email, hash: []), viewer: 0, addr: addr)
        return .crypto(.hashPassword(password: password, write: task))
    }

    private static func handleLogin(_ body: Span<UInt8>, _ addr: ReplyAddr) -> Dispatch {
        guard let obj = unwrapJsonEnvelope(body, "user", ["email", "password"]) else { return failNow(422, "invalid login payload") }
        guard let email = requiredStrField(body, obj, 0), let password = requiredStrField(body, obj, 1) else {
            return failNow(422, "email and password are required")
        }
        if email.contains(0) || password.count > bcryptMaxBytes { return failNow(401, "invalid credentials") }
        return .readFront(ReadTask(op: .login(email: SmallBytes(email.span), password: password), viewer: 0, addr: addr))
    }

    private static func handleUpdateUser(_ body: Span<UInt8>, _ uid: Int64, _ token: [UInt8], _ addr: ReplyAddr) -> Dispatch {
        let (obj, failure) = parseValidEnvelope(body, "user", ["email", "username", "password", "bio", "image"])
        guard let obj else { return failNow(422, failure) }
        guard let email = optionalStrField(body, obj, 0, nonEmpty: true).optional,
              let username = optionalStrField(body, obj, 1, nonEmpty: true).optional,
              let password = optionalStrField(body, obj, 2, nonEmpty: true).optional,
              let bio = optionalStrField(body, obj, 3, nonEmpty: false).optional,
              let image = optionalStrField(body, obj, 4, nonEmpty: false).optional else {
            return failNow(422, "invalid user fields")
        }
        let op = WriteOp.updateUser(token: token, email: email, username: username, hash: nil, bio: bio, image: image)
        guard let password else { return .write(WriteTask(op: op, viewer: uid, addr: addr)) }
        if password.count > bcryptMaxBytes { return failNow(422, "password exceeds maximum length") }
        return .crypto(.hashPassword(password: password, write: WriteTask(op: op, viewer: uid, addr: addr)))
    }

    private static func handleCreateArticle(_ body: Span<UInt8>, _ viewer: Int64, _ addr: ReplyAddr) -> Dispatch {
        let (obj, failure) = parseValidEnvelope(body, "article", ["title", "description", "body", "tagList"])
        guard let obj else { return failNow(422, failure) }
        guard let title = requiredStrField(body, obj, 0), let description = requiredStrField(body, obj, 1),
              let articleBody = requiredStrField(body, obj, 2) else {
            return failNow(422, "title, description, and body are required")
        }
        var tags: [[UInt8]] = []
        let src = body.extracting(obj.range)
        if let tagList = obj.fields[3] {
            switch tagList.kind {
            case .null:
                break
            case .array:
                let allStrings = JSON.forEachElement(src, tagList) { item in
                    guard item.kind == .string else { return false }
                    let tag = JSON.ownedString(src, item)
                    guard !tag.isEmpty else { return false }
                    tags.append(tag)
                    return true
                }
                guard allStrings else { return failNow(422, "tagList must contain non-empty strings") }
                tags.sortUnstable { $0.lexicographicallyPrecedes($1) }
                var unique: [[UInt8]] = []
                for t in tags where unique.last != t { unique.append(t) }
                tags = unique
            default:
                return failNow(422, "tagList must be an array")
            }
        }
        return .write(WriteTask(op: .createArticle(title: title, description: description, body: articleBody, tags: tags),
                                viewer: viewer, addr: addr))
    }

    private static func handleUpdateArticle(_ body: Span<UInt8>, _ slug: [UInt8], _ viewer: Int64, _ addr: ReplyAddr) -> Dispatch {
        let (obj, failure) = parseValidEnvelope(body, "article", ["title", "description", "body"])
        guard let obj else { return failNow(422, failure) }
        guard let title = optionalStrField(body, obj, 0, nonEmpty: true).optional,
              let description = optionalStrField(body, obj, 1, nonEmpty: true).optional,
              let articleBody = optionalStrField(body, obj, 2, nonEmpty: true).optional else {
            return failNow(422, "article fields must be non-empty strings")
        }
        return .write(WriteTask(op: .updateArticle(slug: slug, title: title, description: description, body: articleBody),
                                viewer: viewer, addr: addr))
    }
}
