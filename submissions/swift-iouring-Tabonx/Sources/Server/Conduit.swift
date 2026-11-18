// Routing and validation for the 19 endpoints. Everything here runs on a reactor and never blocks:
// a request either answers at once or goes to a lane, and the planner takes it from there.

#if os(Linux)
import CShim

public enum Method: UInt8 {
    case get, post, put, delete, other
}

/// A parsed request. Every view points into the receive buffer.
public struct Request {
    public var method: Method
    /// Path without the query string.
    public var path: ByteView
    public var query: ByteView
    public var authorization: ByteView?
    public var body: ByteView
    public var keepAlive: Bool
}

/// Who waits for an answer.
struct Waiter {
    var reactor: Int32
    var ring: Int32
    var slot: UInt32
    var generation: UInt16
    var close: Bool
}

/// The status of an answered request, or `waiting` when it went to a lane.
let waiting = 0

let fastLane = 0
let commentsLane = 1
let listsLane = 2
let laneCount = 3

/// An offset no table reaches; keeps `limit + offset` far from overflowing in SQL.
let largestOffset: Int64 = 1 << 50

struct BodyField {
    /// 0 absent or null, 1 a usable string, 2 anything else.
    var state: UInt8 = 0
    var span = Span()
}

extension Server {
    /// Writes the JSON body into `body` and returns the status, or `waiting`.
    func respond(_ r: Request, _ waiter: Waiter) -> Int {
        guard r.path.hasPrefix("/api/") else { return notFound() }
        let path = r.path.slice(5, r.path.count)
        if path.hasPrefix("articles") {
            if path.count == 8 {
                switch r.method {
                case .get: return listArticles(r, waiter)
                case .post: return createArticle(r, waiter)
                default: return notFound()
                }
            }
            guard path[8] == UInt8(ascii: "/") else { return notFound() }
            let rest = path.slice(9, path.count)
            if rest.equals("feed") && r.method == .get { return feed(r, waiter) }
            var slash = -1
            for i in 0..<rest.count where rest[i] == UInt8(ascii: "/") {
                slash = i
                break
            }
            if slash < 0 {
                guard rest.count > 0 else { return notFound() }
                switch r.method {
                case .get: return article(r, rest, waiter)
                case .put: return updateArticle(r, rest, waiter)
                case .delete: return deleteArticle(r, rest, waiter)
                default: return notFound()
                }
            }
            let slug = rest.slice(0, slash)
            let tail = rest.slice(slash &+ 1, rest.count)
            guard slug.count > 0 else { return notFound() }
            if tail.equals("favorite") {
                switch r.method {
                case .post: return favorite(r, slug, waiter, .favorite)
                case .delete: return favorite(r, slug, waiter, .unfavorite)
                default: return notFound()
                }
            }
            if tail.equals("comments") {
                switch r.method {
                case .get: return comments(r, slug, waiter)
                case .post: return createComment(r, slug, waiter)
                default: return notFound()
                }
            }
            if tail.hasPrefix("comments/"), r.method == .delete {
                return deleteComment(r, slug, tail.slice(9, tail.count), waiter)
            }
            return notFound()
        }
        if path.equals("tags") {
            guard r.method == .get else { return notFound() }
            enqueue(fastLane, req(.tags, waiter))
            return waiting
        }
        if path.hasPrefix("profiles/") {
            let rest = path.slice(9, path.count)
            var slash = -1
            for i in 0..<rest.count where rest[i] == UInt8(ascii: "/") {
                slash = i
                break
            }
            if slash < 0 {
                return r.method == .get && rest.count > 0 ? profile(r, rest, waiter) : notFound()
            }
            guard rest.slice(slash, rest.count).equals("/follow") else { return notFound() }
            switch r.method {
            case .post: return follow(r, rest.slice(0, slash), waiter, .follow)
            case .delete: return follow(r, rest.slice(0, slash), waiter, .unfollow)
            default: return notFound()
            }
        }
        if path.equals("user") {
            switch r.method {
            case .get: return currentUser(r, waiter)
            case .put: return updateUser(r, waiter)
            default: return notFound()
            }
        }
        if path.equals("users") { return r.method == .post ? register(r, waiter) : notFound() }
        if path.equals("users/login") { return r.method == .post ? login(r, waiter) : notFound() }
        return notFound()
    }

    @inline(__always)
    func errors(_ status: Int, _ message: StaticString) -> Int {
        body.truncate(0)
        body.append("{\"errors\":{\"body\":[\"")
        body.append(message)
        body.append("\"]}}")
        return status
    }

    func notFound() -> Int { errors(404, "not found") }

    @inline(__always)
    func enqueue(_ lane: Int, _ r: Req) { stage[lane].push(r, now: passStart) }

    /// Copies `text` and `secret` into the lane and queues the request.
    @inline(__always)
    func enqueue(_ lane: Int, _ request: Req, text: ByteView, secret: ByteView = .empty) {
        var r = request
        let l = stage[lane]
        r.textStart = Int32(truncatingIfNeeded: l.text.count)
        r.textCount = Int32(truncatingIfNeeded: text.count)
        l.text.append(text)
        r.secretStart = Int32(truncatingIfNeeded: l.text.count)
        r.secretCount = Int32(truncatingIfNeeded: secret.count)
        l.text.append(secret)
        l.push(r, now: passStart)
    }

    @inline(__always)
    func req(_ kind: ReqKind, _ waiter: Waiter, viewer: Int64 = 0) -> Req {
        var r = Req(kind: kind, close: waiter.close, generation: waiter.generation, ring: waiter.ring, slot: waiter.slot)
        r.reactor = waiter.reactor
        r.viewer = viewer
        return r
    }

    /// A write, staged until the end of the pass.
    @inline(__always)
    func enqueueWrite(_ kind: WriteKind, _ waiter: Waiter, viewer: Int64, token: ByteView = .empty, solo: Bool = false,
                      bind: (inout OutBuffer) -> Void) {
        writeStage.add(kind, waiter, viewer: viewer, token: token, solo: solo, bind: bind)
    }

    // MARK: Authentication

    /// The token's user, or nil with the 401 body written.
    @inline(__always)
    func requireUser(_ r: Request) -> (id: Int64, token: ByteView)? {
        if case .user(let id, let token) = jwt.verify(authorization: r.authorization, nowMs: passMillis) { return (id, token) }
        _ = errors(401, "unauthorized")
        return nil
    }

    /// The viewer: 0 without a header, nil with the 401 body written if the header is bad.
    @inline(__always)
    func optionalViewer(_ r: Request) -> Int64? {
        switch jwt.verify(authorization: r.authorization, nowMs: passMillis) {
        case .absent: return 0
        case .user(let id, _): return id
        case .invalid:
            _ = errors(401, "unauthorized")
            return nil
        }
    }

    // MARK: Text

    /// Decodes %XX (and + in a query) into `decoded`, or returns `v` itself if there is nothing to do.
    func percentDecoded(_ v: ByteView, plus: Bool) -> ByteView {
        var needed = false
        for i in 0..<v.count where v[i] == UInt8(ascii: "%") || (plus && v[i] == UInt8(ascii: "+")) {
            needed = true
            break
        }
        guard needed else { return v }
        decoded.truncate(0)
        var i = 0
        while i < v.count {
            let b = v[i]
            if b == UInt8(ascii: "%"), i &+ 2 < v.count {
                let hi = hexValue(v[i &+ 1])
                let lo = hexValue(v[i &+ 2])
                if hi >= 0 && lo >= 0 {
                    decoded.append(UInt8(hi &* 16 &+ lo))
                    i &+= 3
                    continue
                }
            }
            decoded.append(plus && b == UInt8(ascii: "+") ? 0x20 : b)
            i &+= 1
        }
        return decoded.view
    }

    /// The value of `name` in the query string, decoded. Present but empty returns an empty view.
    func queryValue(_ query: ByteView, _ name: StaticString) -> ByteView? {
        var i = 0
        let n = query.count
        var found: ByteView? = nil
        while i < n {
            var end = i
            while end < n && query[end] != UInt8(ascii: "&") { end &+= 1 }
            var eq = i
            while eq < end && query[eq] != UInt8(ascii: "=") { eq &+= 1 }
            if found == nil, query.slice(i, eq).equals(name) {
                found = eq < end ? query.slice(eq &+ 1, end) : ByteView.empty
            }
            i = end &+ 1
        }
        return found
    }

    /// limit and offset, or nil with the 422 written.
    func paging(_ query: ByteView) -> (limit: Int32, offset: Int64)? {
        var limit: Int32 = 20
        var offset: Int64 = 0
        if let raw = queryValue(query, "limit") {
            let v = percentDecoded(raw, plus: true)
            guard let n = parseDigits(v), n >= 1, n <= 100 else {
                _ = errors(422, "limit must be 1-100")
                return nil
            }
            limit = Int32(n)
        }
        if let raw = queryValue(query, "offset") {
            let v = percentDecoded(raw, plus: true)
            guard let n = parseDigits(v) else {
                _ = errors(422, "offset must be 0 or more")
                return nil
            }
            offset = min(n, largestOffset)
        }
        return (limit, offset)
    }

    // MARK: Reads

    func listArticles(_ r: Request, _ waiter: Waiter) -> Int {
        guard let viewer = optionalViewer(r) else { return 401 }
        guard let page = paging(r.query) else { return 422 }
        var kind = ReqKind.global
        var filter = ByteView.empty
        for (name, candidate) in [("tag" as StaticString, ReqKind.tag), ("author", .author), ("favorited", .favorited)] {
            if let raw = queryValue(r.query, name), raw.count > 0 {
                kind = candidate
                filter = percentDecoded(raw, plus: true)
                break
            }
        }
        if kind != .global && (filter.count == 0 || !isValidText(filter)) {
            body.truncate(0)
            body.append("{\"articles\":[],\"articlesCount\":0}")
            return 200
        }
        var q = req(kind, waiter, viewer: viewer)
        q.limit = page.limit
        q.offset = page.offset
        enqueue(listsLane, q, text: filter)
        return waiting
    }

    func feed(_ r: Request, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        guard let page = paging(r.query) else { return 422 }
        var q = req(.feed, waiter, viewer: user.id)
        q.limit = page.limit
        q.offset = page.offset
        enqueue(listsLane, q)
        return waiting
    }

    func article(_ r: Request, _ rawSlug: ByteView, _ waiter: Waiter) -> Int {
        guard let viewer = optionalViewer(r) else { return 401 }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueue(listsLane, req(.article, waiter, viewer: viewer), text: slug)
        return waiting
    }

    func comments(_ r: Request, _ rawSlug: ByteView, _ waiter: Waiter) -> Int {
        guard let viewer = optionalViewer(r) else { return 401 }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueue(commentsLane, req(.comments, waiter, viewer: viewer), text: slug)
        return waiting
    }

    func profile(_ r: Request, _ rawName: ByteView, _ waiter: Waiter) -> Int {
        guard let viewer = optionalViewer(r) else { return 401 }
        let name = percentDecoded(rawName, plus: false)
        guard isValidText(name) else { return notFound() }
        enqueue(fastLane, req(.profile, waiter, viewer: viewer), text: name)
        return waiting
    }

    func currentUser(_ r: Request, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        enqueue(fastLane, req(.user, waiter, viewer: user.id), text: .empty, secret: user.token)
        return waiting
    }

    // MARK: Request bodies

    /// Reads a member into `fieldBytes`. Text Postgres can't store counts as invalid.
    func readField(_ m: JSONMember, _ f: inout BodyField) {
        switch m.kind {
        case .null:
            f = BodyField()
        case .string:
            let start = fieldBytes.count
            if m.escaped {
                unescapeJSONString(m.value, into: &fieldBytes)
            } else {
                fieldBytes.append(m.value)
            }
            f.span = Span(start: Int32(truncatingIfNeeded: start), count: Int32(truncatingIfNeeded: fieldBytes.count &- start))
            f.state = isValidText(fieldView(f)) ? 1 : 2
        default:
            f.state = 2
        }
    }

    @inline(__always)
    func fieldView(_ f: BodyField) -> ByteView {
        ByteView(base: UnsafePointer(fieldBytes.base + Int(f.span.start)), count: Int(f.span.count))
    }

    @inline(__always)
    func optionalField(_ f: BodyField) -> ByteView? { f.state == 1 ? fieldView(f) : nil }

    /// The object under `key`, or nil if the body isn't `{"key": {...}}`.
    func wrapped(_ r: Request, _ key: StaticString) -> ByteView? {
        var inner: ByteView? = nil
        let doc = scanJSONObject(r.body) { m in
            if keyIs(m, key) { inner = m.kind == .object ? m.value : nil }
        }
        return doc == .object ? inner : nil
    }

    func register(_ r: Request, _ waiter: Waiter) -> Int {
        guard let inner = wrapped(r, "user") else { return errors(422, "invalid body") }
        fieldBytes.truncate(0)
        var username = BodyField(), email = BodyField(), password = BodyField()
        _ = scanJSONObject(inner) { m in
            if keyIs(m, "username") { readField(m, &username) }
            else if keyIs(m, "email") { readField(m, &email) }
            else if keyIs(m, "password") { readField(m, &password) }
        }
        guard username.state == 1, email.state == 1, password.state == 1,
              username.span.count > 0, email.span.count > 0, password.span.count > 0, password.span.count <= 72
        else { return errors(422, "username, email and password are required") }
        let work = CryptoWork(kind: .register, waiter: waiter)
        work.fields = [fieldArray(username), fieldArray(email)]
        submitCrypto(work, password: fieldView(password), hash: nil)
        return waiting
    }

    func fieldArray(_ f: BodyField) -> [UInt8]? {
        guard f.state == 1 else { return nil }
        return Array(UnsafeBufferPointer(start: UnsafePointer(fieldBytes.base + Int(f.span.start)), count: Int(f.span.count)))
    }

    func login(_ r: Request, _ waiter: Waiter) -> Int {
        guard let inner = wrapped(r, "user") else { return errors(422, "invalid body") }
        fieldBytes.truncate(0)
        var email = BodyField(), password = BodyField()
        _ = scanJSONObject(inner) { m in
            if keyIs(m, "email") { readField(m, &email) }
            else if keyIs(m, "password") { readField(m, &password) }
        }
        guard email.state == 1, password.state == 1, email.span.count > 0, password.span.count > 0 else {
            return errors(422, "email and password are required")
        }
        enqueue(fastLane, req(.login, waiter), text: fieldView(email), secret: fieldView(password))
        return waiting
    }

    func updateUser(_ r: Request, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        guard let inner = wrapped(r, "user") else { return errors(422, "invalid body") }
        fieldBytes.truncate(0)
        var email = BodyField(), username = BodyField(), password = BodyField(), bio = BodyField(), image = BodyField()
        _ = scanJSONObject(inner) { m in
            if keyIs(m, "email") { readField(m, &email) }
            else if keyIs(m, "username") { readField(m, &username) }
            else if keyIs(m, "password") { readField(m, &password) }
            else if keyIs(m, "bio") { readField(m, &bio) }
            else if keyIs(m, "image") { readField(m, &image) }
        }
        let invalid = email.state == 2 || username.state == 2 || password.state == 2 || bio.state == 2 || image.state == 2
        if invalid || (email.state == 1 && email.span.count == 0) || (username.state == 1 && username.span.count == 0)
            || (password.state == 1 && (password.span.count == 0 || password.span.count > 72)) {
            return errors(422, "invalid fields")
        }
        if password.state == 1 {
            let work = CryptoWork(kind: .updateUser, waiter: waiter)
            work.id = user.id
            work.fields = [fieldArray(email), fieldArray(username), fieldArray(bio), fieldArray(image)]
            work.token = Array(UnsafeBufferPointer(start: user.token.base, count: user.token.count))
            submitCrypto(work, password: fieldView(password), hash: nil)
            return waiting
        }
        enqueueWrite(.updateUser, waiter, viewer: user.id, token: user.token, solo: true) { out in
            out.appendBindExecute("upduser", parameterCount: 6) { p in
                p.appendInt8Parameter(user.id)
                p.appendTextParameter(optionalField(email))
                p.appendTextParameter(optionalField(username))
                p.appendTextParameter(nil as ByteView?)
                p.appendTextParameter(optionalField(bio))
                p.appendTextParameter(optionalField(image))
            }
        }
        return waiting
    }

    // MARK: Writes

    func follow(_ r: Request, _ rawName: ByteView, _ waiter: Waiter, _ kind: WriteKind) -> Int {
        guard let user = requireUser(r) else { return 401 }
        let name = percentDecoded(rawName, plus: false)
        guard name.count > 0, isValidText(name) else { return notFound() }
        enqueueWrite(kind, waiter, viewer: user.id) { out in
            out.appendBindExecute(kind == .follow ? "follow" : "unfollow", parameterCount: 2) { p in
                p.appendInt8Parameter(user.id)
                p.appendTextParameter(name)
            }
        }
        return waiting
    }

    func favorite(_ r: Request, _ rawSlug: ByteView, _ waiter: Waiter, _ kind: WriteKind) -> Int {
        guard let user = requireUser(r) else { return 401 }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueueWrite(kind, waiter, viewer: user.id) { out in
            out.appendBindExecute(kind == .favorite ? "fav" : "unfav", parameterCount: 2) { p in
                p.appendInt8Parameter(user.id)
                p.appendTextParameter(slug)
            }
        }
        return waiting
    }

    func createComment(_ r: Request, _ rawSlug: ByteView, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        guard let inner = wrapped(r, "comment") else { return errors(422, "invalid body") }
        fieldBytes.truncate(0)
        var text = BodyField()
        _ = scanJSONObject(inner) { m in
            if keyIs(m, "body") { readField(m, &text) }
        }
        guard text.state == 1, text.span.count > 0 else { return errors(422, "body is required") }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueueWrite(.createComment, waiter, viewer: user.id) { out in
            out.appendBindExecute("newcmt", parameterCount: 3) { p in
                p.appendTextParameter(slug)
                p.appendInt8Parameter(user.id)
                p.appendTextParameter(fieldView(text))
            }
        }
        return waiting
    }

    func deleteComment(_ r: Request, _ rawSlug: ByteView, _ rawID: ByteView, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        guard let id = parsePositiveInt(rawID) else { return notFound() }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueueWrite(.deleteComment, waiter, viewer: user.id) { out in
            out.appendBindExecute("delcmt", parameterCount: 3) { p in
                p.appendInt8Parameter(id)
                p.appendTextParameter(slug)
                p.appendInt8Parameter(user.id)
            }
        }
        return waiting
    }

    func createArticle(_ r: Request, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        guard let inner = wrapped(r, "article") else { return errors(422, "invalid body") }
        fieldBytes.truncate(0)
        var title = BodyField(), description = BodyField(), text = BodyField()
        var tags: ByteView? = nil
        var tagsInvalid = false
        _ = scanJSONObject(inner) { m in
            if keyIs(m, "title") { readField(m, &title) }
            else if keyIs(m, "description") { readField(m, &description) }
            else if keyIs(m, "body") { readField(m, &text) }
            else if keyIs(m, "tagList") {
                tags = nil
                tagsInvalid = false
                if m.kind == .array { tags = m.value } else if m.kind != .null { tagsInvalid = true }
            }
        }
        guard title.state == 1, description.state == 1, text.state == 1,
              title.span.count > 0, description.span.count > 0, text.span.count > 0, !tagsInvalid
        else { return errors(422, "title, description and body are required") }
        var tagFields: [BodyField] = []
        if let tags {
            let ok = scanStringArray(tags) { value, escaped in
                let start = fieldBytes.count
                if escaped { unescapeJSONString(value, into: &fieldBytes) } else { fieldBytes.append(value) }
                let field = BodyField(state: 1, span: Span(start: Int32(truncatingIfNeeded: start), count: Int32(truncatingIfNeeded: fieldBytes.count &- start)))
                if field.span.count == 0 || !isValidText(fieldView(field)) { return false }
                tagFields.append(field)
                return true
            }
            guard ok else { return errors(422, "tagList must be an array of non-empty strings") }
        }
        enqueueWrite(.createArticle, waiter, viewer: user.id) { out in
            out.appendBindExecute("newart", parameterCount: 5) { p in
                p.appendInt8Parameter(user.id)
                p.appendTextParameter(fieldView(title))
                p.appendTextParameter(fieldView(description))
                p.appendTextParameter(fieldView(text))
                let at = p.beginArray(oid: oidText, count: tagFields.count)
                for f in tagFields { p.appendTextParameter(fieldView(f)) }
                p.endArray(at)
            }
        }
        return waiting
    }

    func updateArticle(_ r: Request, _ rawSlug: ByteView, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        guard let inner = wrapped(r, "article") else { return errors(422, "invalid body") }
        fieldBytes.truncate(0)
        var title = BodyField(), description = BodyField(), text = BodyField()
        _ = scanJSONObject(inner) { m in
            if keyIs(m, "title") { readField(m, &title) }
            else if keyIs(m, "description") { readField(m, &description) }
            else if keyIs(m, "body") { readField(m, &text) }
        }
        let empty = (title.state == 1 && title.span.count == 0) || (description.state == 1 && description.span.count == 0)
            || (text.state == 1 && text.span.count == 0)
        if title.state == 2 || description.state == 2 || text.state == 2 || empty {
            return errors(422, "title, description and body must be non-empty strings")
        }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueueWrite(.updateArticle, waiter, viewer: user.id) { out in
            out.appendBindExecute("updart", parameterCount: 5) { p in
                p.appendTextParameter(slug)
                p.appendTextParameter(optionalField(title))
                p.appendTextParameter(optionalField(description))
                p.appendTextParameter(optionalField(text))
                p.appendInt8Parameter(user.id)
            }
        }
        return waiting
    }

    func deleteArticle(_ r: Request, _ rawSlug: ByteView, _ waiter: Waiter) -> Int {
        guard let user = requireUser(r) else { return 401 }
        let slug = percentDecoded(rawSlug, plus: false)
        guard isValidText(slug) else { return notFound() }
        enqueueWrite(.deleteArticle, waiter, viewer: user.id) { out in
            out.appendBindExecute("delart", parameterCount: 2) { p in
                p.appendTextParameter(slug)
                p.appendInt8Parameter(user.id)
            }
        }
        return waiting
    }
}

/// ASCII digits only, no sign, fits in Int64. Zero is allowed.
func parseDigits(_ v: ByteView) -> Int64? {
    guard v.count > 0, v.count <= 19 else { return nil }
    var value: Int64 = 0
    for i in 0..<v.count {
        let d = v[i] &- 48
        guard d < 10 else { return nil }
        let (m, o1) = value.multipliedReportingOverflow(by: 10)
        let (s, o2) = m.addingReportingOverflow(Int64(d))
        guard !o1, !o2 else { return nil }
        value = s
    }
    return value
}

/// Valid UTF-8 without NUL: what Postgres accepts in a text value. One bad value in an array
/// parameter would fail its whole batch, so nothing else gets that far.
func isValidText(_ v: ByteView) -> Bool {
    var i = 0
    let n = v.count
    while i < n {
        let b = v[i]
        if b != 0 && b < 0x80 {
            i &+= 1
            continue
        }
        if b == 0 { return false }
        var extra = 0
        var minimum: UInt32 = 0
        var cp: UInt32 = 0
        if b & 0xE0 == 0xC0 {
            extra = 1
            minimum = 0x80
            cp = UInt32(b & 0x1F)
        } else if b & 0xF0 == 0xE0 {
            extra = 2
            minimum = 0x800
            cp = UInt32(b & 0x0F)
        } else if b & 0xF8 == 0xF0 {
            extra = 3
            minimum = 0x10000
            cp = UInt32(b & 0x07)
        } else {
            return false
        }
        guard i &+ extra < n else { return false }
        for k in 1...extra {
            let c = v[i &+ k]
            guard c & 0xC0 == 0x80 else { return false }
            cp = cp << 6 | UInt32(c & 0x3F)
        }
        guard cp >= minimum, cp <= 0x10FFFF, !(cp >= 0xD800 && cp <= 0xDFFF) else { return false }
        i &+= extra &+ 1
    }
    return true
}

/// Walks a JSON array (`[...]`, already validated). False if an element isn't a string or `each` says no.
func scanStringArray(_ array: ByteView, _ each: (ByteView, Bool) -> Bool) -> Bool {
    var parser = JSONParser(array)
    parser.i = 1
    parser.skipWhitespace()
    if parser.i < parser.end && parser.p[parser.i] == 0x5D { return true }
    while true {
        parser.skipWhitespace()
        var escaped = false
        guard let value = parser.string(&escaped), each(value, escaped) else { return false }
        parser.skipWhitespace()
        guard parser.i < parser.end else { return false }
        if parser.p[parser.i] == 0x2C {
            parser.i &+= 1
            continue
        }
        return parser.p[parser.i] == 0x5D
    }
}
#endif
