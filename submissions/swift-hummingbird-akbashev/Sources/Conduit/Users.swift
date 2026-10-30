// Users, auth and profiles (SPEC.md "Users and auth" and "Profiles").
import HTTPTypes
import Hummingbird
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
    mutating func user(_ u: borrowing UserRow, token: Substring) {
        raw("{\"user\":{\"email\":"); string(u.email)
        raw(",\"token\":"); string(token)
        raw(",\"username\":"); string(u.username)
        raw(",\"bio\":"); stringOrNull(u.bio)
        raw(",\"image\":"); stringOrNull(u.image)
        raw("}}")
    }

    /// {"username":..,"bio":..,"image":..,"following":..}: a profile, or an article's or comment's author.
    mutating func author(_ p: borrowing ProfileRow) {
        raw("{\"username\":"); string(p.username)
        raw(",\"bio\":"); stringOrNull(p.bio)
        raw(",\"image\":"); stringOrNull(p.image)
        raw(",\"following\":"); bool(p.following)
        raw("}")
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

func userResponse(_ status: HTTPResponse.Status, _ u: borrowing UserRow, token: Substring) -> Response {
    var out = JSONWriter(capacity: 512)
    out.user(u, token: token)
    return out.response(status)
}

func invalidBody(_ status: HTTPResponse.Status = .unprocessableContent, _ message: String) -> ApiError {
    ApiError(status, message)
}

extension App {
    // POST /api/users
    func register(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let m: [String: Any]
        do {
            m = try await readWrapper(request, "user")
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
        let hash = try await bcryptHash(password)

        let row: PostgresRow
        do {
            row = try await queryRow(
                """
                INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
                RETURNING id, username, email, bio, image
                """,
                [username, email, hash]
            )!
        } catch let e where isUniqueViolation(e) {
            throw invalidBody(.unprocessableContent, "username or email is already taken")
        }
        let (id, u) = try row.user()
        return userResponse(.created, u, token: signer.issue(id: id)[...])
    }

    // POST /api/users/login
    func login(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let m: [String: Any]
        do { m = try await readWrapper(request, "user") } catch { throw invalidBody(.unprocessableContent, "invalid body") }
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
        guard try await bcryptVerify(password, hash: hash) else {
            throw invalidBody(.unauthorized, "invalid email or password")
        }
        return userResponse(.ok, u, token: signer.issue(id: id)[...])
    }

    // GET /api/user
    func currentUser(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let found = if let reads { try await reads.user(id: auth.viewer) } else { try await fetchFirst(UserByID(id: auth.viewer)) }
        guard let u = found else {
            throw invalidBody(.unauthorized, "unauthorized")
        }
        return userResponse(.ok, u, token: auth.token)
    }

    // PUT /api/user
    func updateUser(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let m: [String: Any]
        do { m = try await readWrapper(request, "user") } catch { throw invalidBody(.unprocessableContent, "invalid body") }
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

        let row: PostgresRow
        do {
            guard let updated = try await queryRow(
                """
                UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
                 WHERE id = $1
                RETURNING id, username, email, bio, image
                """,
                binds: updateUserBinds(viewer: auth.viewer, email: email, username: username, hash: hash, bio: bio, image: image)
            ) else {
                throw invalidBody(.unauthorized, "unauthorized")
            }
            row = updated
        } catch let e where isUniqueViolation(e) {
            throw invalidBody(.unprocessableContent, "username or email is already taken")
        }
        return userResponse(.ok, try row.user().user, token: auth.token)
    }

    private func updateUserBinds(viewer: Int64, email: String?, username: String?, hash: String?,
                                 bio: String?, image: String?) -> PostgresBindings {
        var binds = PostgresBindings(capacity: 6)
        binds.append(viewer)
        binds.append(email)
        binds.append(username)
        binds.append(hash)
        binds.append(bio)
        binds.append(image)
        return binds
    }

    private func bcryptHashOpt(_ password: String?) async throws -> String? {
        guard let password else { return nil }
        return try await bcryptHash(password)
    }

    // GET /api/profiles/:username
    func getProfile(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, signer)
        let username = ctx.parameters.get("username") ?? ""
        let found = if let reads {
            try await reads.profile(username: username, viewer: auth.viewer)
        } else {
            try await fetchFirst(ProfileByName(viewer: auth.viewer, username: username))
        }
        guard let p = found else {
            throw invalidBody(.notFound, "profile not found")
        }
        return profileResponse(p)
    }

    // POST and DELETE /api/profiles/:username/follow
    func follow(_ request: Request, _ ctx: BasicRequestContext, follow: Bool) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let username = ctx.parameters.get("username") ?? ""
        // One round trip for the lookup and the toggle; no row means no such user (404).
        let toggle = follow
            ? "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING) SELECT id, username, bio, image FROM u"
            : "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), del AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u)) SELECT id, username, bio, image FROM u"
        guard let row = try await queryRow(toggle, [auth.viewer, username]) else {
            throw invalidBody(.notFound, "profile not found")
        }
        var cells = RowCursor(row)
        try cells.skip() // id
        let name = try cells.text()
        let bio = try cells.textOrNull()
        let image = try cells.textOrNull()
        return profileResponse(ProfileRow(username: name, bio: bio, image: image, following: follow))
    }

    private func profileResponse(_ p: borrowing ProfileRow) -> Response {
        var out = JSONWriter(capacity: 256)
        out.raw("{\"profile\":")
        out.author(p)
        out.raw("}")
        return out.response(.ok)
    }

    // GET /api/tags
    func tags(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        var out = JSONWriter(capacity: 4096)
        out.raw("{\"tags\":[")
        if let reads {
            let tags = try await reads.tags()
            for i in tags.indices {
                if i > 0 { out.raw(",") }
                out.string(tags[i])
            }
            out.raw("]}")
            return out.response(.ok)
        }
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
