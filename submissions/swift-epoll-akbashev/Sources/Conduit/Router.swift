// router.rs: what a request asks for, decided on the reactor that parsed it. Reads, writes and bcrypt work become
// value types (Sendable: their strings are byte arrays) that the reactor hands the scheduler once per epoll tick;
// everything that can be answered without Postgres (a bad token, a bad body, a 404) is answered on the spot.

/// Where a reply goes: the reactor, the connection slot, and that slot's epoch, so a reply for a connection that
/// closed in the meantime (and whose slot was reused) is dropped.
struct ReplyAddr: Hashable, Sendable {
    var worker: UInt16
    var slot: UInt32
    var epoch: UInt32
}

struct OutgoingReply: Sendable {
    var addr: ReplyAddr
    var status: UInt16
    /// The body: built once and shared by every reply in a batch that has the same one (an array is reference
    /// counted, so this is the Rust's `Arc<[u8]>` as well as its `Vec<u8>`).
    var body: [UInt8]
}

enum ReadOp: Sendable {
    case tags
    case currentUser(id: Int64, token: [UInt8])
    case login(email: [UInt8], password: [UInt8])
    case profile(username: [UInt8])
    case articleBySlug(slug: [UInt8])
    /// A write's read-back; `knownFav` is the favorited flag when the write just set it (a favorite or unfavorite),
    /// so the lane needn't look it up.
    case articleById(id: Int64, knownFav: Bool?)
    case comments(slug: [UInt8])
    case global(lim: Int64, off: Int64)
    case byTag(tag: [UInt8], lim: Int64, off: Int64)
    case byAuthor(username: [UInt8], lim: Int64, off: Int64)
    case byFavorited(username: [UInt8], lim: Int64, off: Int64)
    case feed(lim: Int64, off: Int64)
}

struct ReadTask: Sendable {
    var op: ReadOp
    var viewer: Int64
    var addr: ReplyAddr
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
    var viewer: Int64
    var addr: ReplyAddr
}

struct UserRecord: Sendable {
    var id: Int64
    var username: [UInt8]
    var email: [UInt8]
    var bio: [UInt8]?
    var image: [UInt8]?
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
}

/// A parsed request, borrowing the bytes it was parsed from (the reactor's read buffer, or a de-chunked body): it
/// can't outlive them, so routing reads them in place.
struct HttpReq: ~Escapable {
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

/// What routing decided: an answer now (its body owned, moved to the connection's write), or work for the lanes.
enum Dispatch: ~Copyable {
    case immediate(UInt16, ByteBuffer)
    case read(ReadTask)
    case readFront(ReadTask)
    case write(WriteTask)
    case crypto(CryptoTask)
}

func makeErrorJSON(_ message: StaticString) -> ByteBuffer {
    var out = ByteBuffer(capacity: 40 + message.utf8CodeUnitCount)
    out.append("{\"errors\":{\"body\":[")
    writeStr(&out, message)
    out.append("]}}")
    return out
}

@inline(__always) private func failNow(_ status: UInt16, _ message: StaticString) -> Dispatch {
    .immediate(status, makeErrorJSON(message))
}

@inline(__always) private func hexNibble(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: b - 0x30
    case 0x61...0x66: b - 0x61 + 10
    case 0x41...0x46: b - 0x41 + 10
    default: nil
    }
}

private func percentDecodeRaw(_ src: Span<UInt8>, plus: Bool) -> [UInt8]? {
    var hasEscape = false
    for i in 0..<src.count where src[i] == 0x25 || (plus && src[i] == 0x2B) {
        hasEscape = true
        break
    }
    if !hasEscape {
        return isValidUTF8(src) ? src.withUnsafeBufferPointer { Array($0) } : nil
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
    return isValidUTF8(out.span) ? out : nil
}

/// Percent-decoded, valid UTF-8 and free of NUL, or nil.
private func percentDecode(_ src: Span<UInt8>, plus: Bool) -> [UInt8]? {
    guard let decoded = percentDecodeRaw(src, plus: plus), !decoded.contains(0) else { return nil }
    return decoded
}

private func parsePosInt(_ raw: Span<UInt8>) -> Int64? {
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
    var tag: [UInt8]?
    var author: [UInt8]?
    var favorited: [UInt8]?
    var impossibleFilter = false
}

@inline(__always) private func hasEscape(_ s: Span<UInt8>) -> Bool {
    for i in 0..<s.count where s[i] == 0x25 || s[i] == 0x2B { return true }
    return false
}

private func scanListQuery(_ raw: Span<UInt8>) -> ListQuery {
    var q = ListQuery()
    var start = 0
    while start <= raw.count, raw.count > 0 {
        let end = findByte(raw, 0x26, from: start) ?? raw.count
        defer { start = end + 1 }
        if end == start { continue }
        let pair = raw.extracting(start..<end)
        let eq = findByte(pair, 0x3D) ?? pair.count
        let k = pair.extracting(0..<eq)
        let v = pair.extracting(min(eq + 1, pair.count)..<pair.count)
        let key: [UInt8]
        if !hasEscape(k) {
            guard isValidUTF8(k) else { continue }
            key = k.withUnsafeBufferPointer { Array($0) }
            if key.contains(0) { continue }
        } else {
            guard let decoded = percentDecode(k, plus: true) else { continue }
            key = decoded
        }
        let decodeInt = { (v: Span<UInt8>) -> Int64? in
            hasEscape(v) ? percentDecode(v, plus: true).flatMap { parsePosInt($0.span) } : parsePosInt(v)
        }
        if bytesEqual(key, "limit") {
            if !q.seenLimit {
                q.seenLimit = true
                q.limit = decodeInt(v)
            }
        } else if bytesEqual(key, "offset") {
            if !q.seenOffset {
                q.seenOffset = true
                q.offset = decodeInt(v)
            }
        } else if bytesEqual(key, "tag") || bytesEqual(key, "author") || bytesEqual(key, "favorited") {
            let current = bytesEqual(key, "tag") ? q.tag : bytesEqual(key, "author") ? q.author : q.favorited
            if current == nil {
                var value = percentDecode(v, plus: true)
                if value == nil {
                    value = []
                    q.impossibleFilter = true
                }
                if bytesEqual(key, "tag") { q.tag = value } else if bytesEqual(key, "author") { q.author = value } else { q.favorited = value }
            }
        }
    }
    return q
}

private func validatePageBounds(_ q: ListQuery) -> (lim: Int64, off: Int64)? {
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

private func unwrapJsonEnvelope(_ body: Span<UInt8>, _ rootKey: StaticString) -> JsonMap? {
    guard case .object(var outer)? = parseJson(body), case .object(let inner)? = outer.remove(rootKey) else { return nil }
    return inner
}

private func containsNul(_ map: JsonMap) -> Bool {
    func check(_ v: JsonVal) -> Bool {
        switch v {
        case .string(let s): s.contains(0)
        case .array(let arr): arr.contains(where: check)
        case .object(let obj): obj.values.contains(where: check)
        default: false
        }
    }
    return map.values.contains(where: check)
}

/// The object under `rootKey`, or the message to fail the request with (422).
private func parseValidEnvelope(_ body: Span<UInt8>, _ rootKey: StaticString) -> (JsonMap?, StaticString) {
    guard let m = unwrapJsonEnvelope(body, rootKey) else { return (nil, "invalid request body") }
    if containsNul(m) { return (nil, "strings must not contain NUL") }
    return (m, "")
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

private func optionalStrField(_ map: JsonMap, _ key: StaticString, nonEmpty: Bool) -> Field {
    switch map.get(key) {
    case nil, .null?: .absent
    case .string(let s)? where nonEmpty && s.isEmpty: .invalid
    case .string(let s)?: .value(s)
    default: .invalid
    }
}

private func requiredStrField(_ map: JsonMap, _ key: StaticString) -> [UInt8]? {
    if case .value(let v) = optionalStrField(map, key, nonEmpty: true) { v } else { nil }
}

private enum AuthState {
    case anonymous
    case rejected
    case verified(Int64)
}

@inline(__always) private func verifyAuthHeader(_ signer: TokenSigner, _ header: Span<UInt8>?) -> AuthState {
    guard let header else { return .anonymous }
    guard header.count >= 6, spanEqual(header.extracting(0..<6), "Token ") else { return .rejected }
    return signer.verify(header.extracting(6..<header.count)).map(AuthState.verified) ?? .rejected
}

/// The token after "Token ", copied (for the replies that echo it).
@inline(__always) private func tokenBytes(_ header: Span<UInt8>?) -> [UInt8] {
    guard let header else { return [] }
    return header.extracting(6..<header.count).withUnsafeBufferPointer { Array($0) }
}

private let bcryptMaxBytes = 72

func routeRequest(_ signer: TokenSigner, _ req: borrowing HttpReq, _ addr: ReplyAddr) -> Dispatch {
    let path = req.path
    guard path.count >= 5, spanEqual(path.extracting(0..<5), "/api/") else { return failNow(404, "not found") }
    let sub = path.extracting(5..<path.count)
    var bounds = InlineArray<5, (Int, Int)>(repeating: (0, 0))
    var n = 0
    var start = 0
    while true {
        let end = findByte(sub, 0x2F, from: start) ?? sub.count
        if n >= 5 { return failNow(404, "not found") }
        bounds[n] = (start, end)
        n += 1
        if end == sub.count { break }
        start = end + 1
    }
    func segIs(_ i: Int, _ s: StaticString) -> Bool {
        spanEqual(sub.extracting(bounds[i].0..<bounds[i].1), s)
    }
    func segEmpty(_ i: Int) -> Bool { bounds[i].0 == bounds[i].1 }
    func decodeSeg(_ i: Int) -> [UInt8]? {
        segEmpty(i) ? nil : percentDecode(sub.extracting(bounds[i].0..<bounds[i].1), plus: false)
    }
    let m = req.method
    let isGet = spanEqual(m, "GET"), isPost = spanEqual(m, "POST"), isPut = spanEqual(m, "PUT"), isDelete = spanEqual(m, "DELETE")

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
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            return optional { read(.articleBySlug(slug: slug), $0) }
        }
        if n == 3 && segIs(0, "articles") && !segEmpty(1) && segIs(2, "comments") {
            guard let slug = decodeSeg(1) else { return failNow(404, "not found") }
            return optional { read(.comments(slug: slug), $0) }
        }
        if n == 2 && segIs(0, "profiles") && !segEmpty(1) {
            guard let username = decodeSeg(1) else { return failNow(404, "not found") }
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
            let (obj, failure) = parseValidEnvelope(req.body, "comment")
            guard let obj else { return failNow(422, failure) }
            guard let body = requiredStrField(obj, "body") else { return failNow(422, "comment body required") }
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

private func routeArticleList(_ rawQuery: Span<UInt8>, _ viewer: Int64, _ addr: ReplyAddr) -> Dispatch {
    let q = scanListQuery(rawQuery)
    guard let (lim, off) = validatePageBounds(q) else { return failNow(422, "invalid pagination parameters") }
    if q.impossibleFilter {
        var body = ByteBuffer(capacity: 34)
        body.append("{\"articles\":[],\"articlesCount\":0}")
        return .immediate(200, body)
    }
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

private func handleRegister(_ body: Span<UInt8>, _ addr: ReplyAddr) -> Dispatch {
    let (obj, failure) = parseValidEnvelope(body, "user")
    guard let obj else { return failNow(422, failure) }
    guard let username = requiredStrField(obj, "username"), let email = requiredStrField(obj, "email"),
          let password = requiredStrField(obj, "password") else {
        return failNow(422, "username, email, and password are required")
    }
    if password.count > bcryptMaxBytes { return failNow(422, "password exceeds maximum length") }
    let task = WriteTask(op: .register(username: username, email: email, hash: []), viewer: 0, addr: addr)
    return .crypto(.hashPassword(password: password, write: task))
}

private func handleLogin(_ body: Span<UInt8>, _ addr: ReplyAddr) -> Dispatch {
    guard let obj = unwrapJsonEnvelope(body, "user") else { return failNow(422, "invalid login payload") }
    guard let email = requiredStrField(obj, "email"), let password = requiredStrField(obj, "password") else {
        return failNow(422, "email and password are required")
    }
    if email.contains(0) || password.count > bcryptMaxBytes { return failNow(401, "invalid credentials") }
    return .readFront(ReadTask(op: .login(email: email, password: password), viewer: 0, addr: addr))
}

private func handleUpdateUser(_ body: Span<UInt8>, _ uid: Int64, _ token: [UInt8], _ addr: ReplyAddr) -> Dispatch {
    let (obj, failure) = parseValidEnvelope(body, "user")
    guard let obj else { return failNow(422, failure) }
    guard let email = optionalStrField(obj, "email", nonEmpty: true).optional,
          let username = optionalStrField(obj, "username", nonEmpty: true).optional,
          let password = optionalStrField(obj, "password", nonEmpty: true).optional,
          let bio = optionalStrField(obj, "bio", nonEmpty: false).optional,
          let image = optionalStrField(obj, "image", nonEmpty: false).optional else {
        return failNow(422, "invalid user fields")
    }
    let op = WriteOp.updateUser(token: token, email: email, username: username, hash: nil, bio: bio, image: image)
    guard let password else { return .write(WriteTask(op: op, viewer: uid, addr: addr)) }
    if password.count > bcryptMaxBytes { return failNow(422, "password exceeds maximum length") }
    return .crypto(.hashPassword(password: password, write: WriteTask(op: op, viewer: uid, addr: addr)))
}

private func handleCreateArticle(_ body: Span<UInt8>, _ viewer: Int64, _ addr: ReplyAddr) -> Dispatch {
    let (obj, failure) = parseValidEnvelope(body, "article")
    guard let obj else { return failNow(422, failure) }
    guard let title = requiredStrField(obj, "title"), let description = requiredStrField(obj, "description"),
          let articleBody = requiredStrField(obj, "body") else {
        return failNow(422, "title, description, and body are required")
    }
    var tags: [[UInt8]] = []
    switch obj.get("tagList") {
    case nil, .null?:
        break
    case .array(let arr)?:
        for item in arr {
            guard case .string(let s) = item, !s.isEmpty else { return failNow(422, "tagList must contain non-empty strings") }
            tags.append(s)
        }
        tags.sort { $0.lexicographicallyPrecedes($1) }
        var unique: [[UInt8]] = []
        for t in tags where unique.last != t { unique.append(t) }
        tags = unique
    default:
        return failNow(422, "tagList must be an array")
    }
    return .write(WriteTask(op: .createArticle(title: title, description: description, body: articleBody, tags: tags),
                            viewer: viewer, addr: addr))
}

private func handleUpdateArticle(_ body: Span<UInt8>, _ slug: [UInt8], _ viewer: Int64, _ addr: ReplyAddr) -> Dispatch {
    let (obj, failure) = parseValidEnvelope(body, "article")
    guard let obj else { return failNow(422, failure) }
    guard let title = optionalStrField(obj, "title", nonEmpty: true).optional,
          let description = optionalStrField(obj, "description", nonEmpty: true).optional,
          let articleBody = optionalStrField(obj, "body", nonEmpty: true).optional else {
        return failNow(422, "article fields must be non-empty strings")
    }
    return .write(WriteTask(op: .updateArticle(slug: slug, title: title, description: description, body: articleBody),
                            viewer: viewer, addr: addr))
}
