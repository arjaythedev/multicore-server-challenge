// Users, auth and profiles (SPEC.md "Users and auth" and "Profiles").
import Foundation
import Hummingbird
import HummingbirdCore
import PostgresNIO

struct UserRow {
    var username: String
    var email: String
    var bio: String?
    var image: String?

    func json(id: Int64, token: String) -> String {
        var out = "{\"user\":{\"email\":\(jsonEscape(email)),\"token\":\(jsonEscape(token)),\"username\":\(jsonEscape(username))"
        if let bio { out += ",\"bio\":\(jsonEscape(bio))" } else { out += ",\"bio\":null" }
        if let image { out += ",\"image\":\(jsonEscape(image))" } else { out += ",\"image\":null" }
        out += "}}"
        return out
    }
}

struct ProfileRow {
    var username: String
    var bio: String?
    var image: String?
    var following: Bool

    func json() -> String {
        var out = "{\"profile\":{\"username\":\(jsonEscape(username))"
        if let bio { out += ",\"bio\":\(jsonEscape(bio))" } else { out += ",\"bio\":null" }
        if let image { out += ",\"image\":\(jsonEscape(image))" } else { out += ",\"image\":null" }
        out += ",\"following\":\(following ? "true" : "false")}}"
        return out
    }
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
        let id = try row.cell(0).int()
        let u = UserRow(username: try row.cell(1).text(), email: try row.cell(2).text(),
                        bio: try row.cell(3).textOrNull(), image: try row.cell(4).textOrNull())
        return jsonResponse(.created, u.json(id: id, token: issueToken(id: id, secret: secret)))
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
        let id = try row.cell(0).int()
        let u = UserRow(username: try row.cell(1).text(), email: try row.cell(2).text(),
                        bio: try row.cell(3).textOrNull(), image: try row.cell(4).textOrNull())
        let hash = try row.cell(5).text()
        guard await bcryptVerify(password, hash: hash) else {
            throw invalidBody(.unauthorized, "invalid email or password")
        }
        return jsonResponse(.ok, u.json(id: id, token: issueToken(id: id, secret: secret)))
    }

    // GET /api/user
    func currentUser(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        guard let row = try await queryRow(
            "SELECT id, username, email, bio, image FROM users WHERE id = $1", [auth.viewer]
        ) else {
            throw invalidBody(.unauthorized, "unauthorized")
        }
        let u = UserRow(username: try row.cell(1).text(), email: try row.cell(2).text(),
                        bio: try row.cell(3).textOrNull(), image: try row.cell(4).textOrNull())
        return jsonResponse(.ok, u.json(id: auth.viewer, token: auth.token))
    }

    // PUT /api/user
    func updateUser(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
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
        let u = UserRow(username: try row.cell(1).text(), email: try row.cell(2).text(),
                        bio: try row.cell(3).textOrNull(), image: try row.cell(4).textOrNull())
        return jsonResponse(.ok, u.json(id: auth.viewer, token: auth.token))
    }

    private func updateUserBinds(viewer: Int64, email: String?, username: String?, hash: String?,
                                 bio: String?, image: String?) -> PostgresBindings {
        var binds = PostgresBindings(capacity: 6)
        try? binds.append(viewer)
        try? binds.append(email)
        try? binds.append(username)
        try? binds.append(hash)
        try? binds.append(bio)
        try? binds.append(image)
        return binds
    }

    private func bcryptHashOpt(_ password: String?) async throws -> String? {
        guard let password else { return nil }
        return try await bcryptHash(password)
    }

    // GET /api/profiles/:username
    func getProfile(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, secret: secret)
        let username = ctx.parameters.get("username") ?? ""
        guard let row = try await queryRow(
            """
            SELECT u.id, u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
              FROM users u WHERE u.username = $2
            """,
            [auth.viewer, username]
        ) else {
            throw invalidBody(.notFound, "profile not found")
        }
        let p = ProfileRow(username: try row.cell(1).text(), bio: try row.cell(2).textOrNull(),
                           image: try row.cell(3).textOrNull(), following: try row.cell(4).bool())
        return jsonResponse(.ok, p.json())
    }

    // POST and DELETE /api/profiles/:username/follow
    func follow(_ request: Request, _ ctx: BasicRequestContext, follow: Bool) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let username = ctx.parameters.get("username") ?? ""
        guard let row = try await queryRow(
            "SELECT id, username, bio, image FROM users WHERE username = $1", [username]
        ) else {
            throw invalidBody(.notFound, "profile not found")
        }
        let followee = try row.cell(0).int()
        if follow {
            try await exec(
                "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                [auth.viewer, followee]
            )
        } else {
            try await exec("DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2", [auth.viewer, followee])
        }
        let p = ProfileRow(username: try row.cell(1).text(), bio: try row.cell(2).textOrNull(),
                           image: try row.cell(3).textOrNull(), following: follow)
        return jsonResponse(.ok, p.json())
    }

    // GET /api/tags
    func tags(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let rows = try await queryAll("SELECT name FROM tags ORDER BY name")
        var out = "{\"tags\":["
        var first = true
        for row in rows {
            if !first { out += "," }
            first = false
            out += jsonEscape(try row.cell(0).text())
        }
        out += "]}"
        return jsonResponse(.ok, out)
    }
}
