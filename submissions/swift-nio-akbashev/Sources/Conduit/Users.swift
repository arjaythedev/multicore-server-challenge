// Users, auth and profiles (SPEC.md "Users and auth" and "Profiles").
import Logging
import NIOCore
import PostgresNIO

struct UserRow {
    var username: PGText
    var email: PGText
    var bio: PGText?
    var image: PGText?
}

struct ProfileRow {
    var username: PGText
    var bio: PGText?
    var image: PGText?
    var following: Bool
}

extension JSONWriter {
    /// {"user":{...}} with the token as presented or as just issued.
    mutating func user(_ u: borrowing UserRow, token: String) {
        raw("{\"user\":{\"email\":"); string(u.email)
        raw(",\"token\":"); string(token)
        raw(",\"username\":"); string(u.username)
        raw(",\"bio\":"); stringOrNull(u.bio)
        raw(",\"image\":"); stringOrNull(u.image)
        raw("}}")
    }

    /// {"username":..,"bio":..,"image":..,"following":..}: a profile, or an article's or comment's author.
    mutating func author(_ p: borrowing ProfileRow) {
        authorUpToFollowing(p)
        bool(p.following)
        raw("}")
    }

    /// An author up to its `following` value, which depends on the viewer.
    mutating func authorUpToFollowing(_ p: borrowing ProfileRow) {
        raw("{\"username\":"); string(p.username)
        raw(",\"bio\":"); stringOrNull(p.bio)
        raw(",\"image\":"); stringOrNull(p.image)
        raw(",\"following\":")
    }
}

extension PostgresRow {
    /// id, username, email, bio, image.
    func user() throws -> (id: Int64, user: UserRow) {
        var cells = RowCursor(self)
        return try cells.user()
    }
}

extension RowCursor {
    /// id, username, email, bio, image.
    mutating func user() throws -> (id: Int64, user: UserRow) {
        let id = try int()
        let username = try text()
        let email = try text()
        let bio = try textOrNull()
        let image = try textOrNull()
        return (id, UserRow(username: username, email: email, bio: bio, image: image))
    }
}

func userResponse(_ status: Status, _ u: borrowing UserRow, token: String) -> Response {
    var out = JSONWriter(capacity: 512)
    out.user(u, token: token)
    return out.response(status)
}

func profileResponse(_ p: borrowing ProfileRow) -> Response {
    var out = JSONWriter(capacity: 256)
    out.raw("{\"profile\":")
    out.author(p)
    out.raw("}")
    return out.response(.ok)
}

let updateUserSQL = """
UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image
"""

func invalidBody(_ status: Status = .unprocessableContent, _ message: String) -> ApiError {
    ApiError(status, message)
}

extension App {
    // POST /api/users
    func register(_ body: ByteBuffer) async throws -> WriteOutcome {
        let m: [String: Any]
        do {
            m = try readWrapper(body, "user")
        } catch {
            throw invalidBody(.unprocessableContent, "invalid body")
        }
        let username: String
        let email: String
        let password: String
        do {
            username = try reqString(m, "username")
            email = try reqString(m, "email")
            password = try reqString(m, "password")
        } catch {
            throw invalidBody(.unprocessableContent, "username, email and password are required")
        }
        let hash = try await bcrypt.hash(password)
        return try await writes.run(.register(username: username, email: email, hash: hash))
    }

    // POST /api/users/login
    func login(_ body: ByteBuffer) async throws -> Response {
        let m: [String: Any]
        do { m = try readWrapper(body, "user") } catch { throw invalidBody(.unprocessableContent, "invalid body") }
        let email: String
        let password: String
        do {
            email = try reqString(m, "email")
            password = try reqString(m, "password")
        } catch {
            throw invalidBody(.unprocessableContent, "email and password are required")
        }
        guard let row = try await queryRow(
            "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", [email]
        ) else {
            throw invalidBody(.unauthorized, "invalid email or password")
        }
        var cells = RowCursor(row)
        let (id, u) = try cells.user()
        let hash = String(buffer: try cells.text().bytes)
        guard try await bcrypt.verify(password, hash: hash) else {
            throw invalidBody(.unauthorized, "invalid email or password")
        }
        return userResponse(.ok, u, token: signer.issue(id: id))
    }

    // GET /api/user, unbatched
    func currentUser(viewer: Int64, token: String) async throws -> Response {
        guard let u = try await fetchFirst(UserByID(id: viewer)) else {
            throw invalidBody(.unauthorized, "unauthorized")
        }
        return userResponse(.ok, u, token: token)
    }

    // PUT /api/user
    func updateUser(viewer: Int64, token: String, _ body: ByteBuffer) async throws -> WriteOutcome {
        let m: [String: Any]
        do { m = try readWrapper(body, "user") } catch { throw invalidBody(.unprocessableContent, "invalid body") }
        let email: String?
        let username: String?
        let password: String?
        let bio: String?
        let image: String?
        do {
            email = try optString(m, "email", nonEmpty: true)
            username = try optString(m, "username", nonEmpty: true)
            password = try optString(m, "password", nonEmpty: true)
            bio = try optString(m, "bio")
            image = try optString(m, "image")
        } catch {
            throw invalidBody(.unprocessableContent, "invalid user fields")
        }
        let hash = try await bcryptHashOpt(password)
        return try await writes.run(.updateUser(viewer: viewer, token: token, email: email, username: username, hash: hash,
                                                bio: bio, image: image))
    }

    private func bcryptHashOpt(_ password: String?) async throws -> String? {
        guard let password else { return nil }
        return try await bcrypt.hash(password)
    }

    // GET /api/profiles/:username, unbatched
    func getProfile(viewer: Int64, username: String) async throws -> Response {
        guard let p = try await fetchFirst(ProfileByName(viewer: viewer, username: username)) else {
            throw invalidBody(.notFound, "profile not found")
        }
        return profileResponse(p)
    }

    // POST and DELETE /api/profiles/:username/follow
    func follow(viewer: Int64, username: String, on follow: Bool) async throws -> WriteOutcome {
        try await writes.run(.follow(viewer: viewer, username: username, on: follow))
    }

    /// GET /api/tags from the read batcher: the body its batch wrote once, copied.
    func tagsResponse(_ body: Range<Int32>, json: borrowing ByteBuffer) -> Response {
        var out = JSONWriter(capacity: body.count)
        out.splice(json, body)
        return out.response(.ok)
    }

    // GET /api/tags, unbatched
    func tags() async throws -> Response {
        var out = JSONWriter(capacity: 4096)
        out.raw("{\"tags\":[")
        var first = true
        for try await tag in try await db.execute(AllTags(), logger: App.queryLogger) {
            if !first { out.raw(",") }
            first = false
            out.string(tag)
        }
        out.raw("]}")
        return out.response(.ok)
    }
}
