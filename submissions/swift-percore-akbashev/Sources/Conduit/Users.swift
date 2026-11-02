// Users, auth and profiles (SPEC.md "Users and auth" and "Profiles"): the handlers and the responses.
import Foundation

func userResponse(_ status: Status, _ u: borrowing UserRow, token: String, _ rows: borrowing Bytes) -> Response {
    var out = JSONWriter(capacity: 512)
    out.user(u, token: token, rows)
    return out.response(status)
}

func profileResponse(_ p: borrowing ProfileRow, _ rows: borrowing Bytes) -> Response {
    var out = JSONWriter(capacity: 256)
    out.raw("{\"profile\":")
    out.author(p, rows)
    out.raw("}")
    return out.response(.ok)
}

func invalidBody(_ status: Status = .unprocessableContent, _ message: String) -> ApiError {
    ApiError(status, message)
}

extension App {
    /// GET /api/user from the read batcher: the body its batch wrote once, with the token as presented.
    func userResponse(_ user: UserSplice, token: String, json: JSONBytes) -> Response {
        var out = JSONWriter(capacity: user.length + token.utf8.count + 8)
        out.user(user, token: token, from: json)
        return out.response(.ok)
    }

    /// GET /api/profiles/:username from the read batcher.
    func profileResponse(_ view: ProfileView, json: JSONBytes) -> Response {
        var out = JSONWriter(capacity: Int(view.splice.following - view.splice.start) + 8)
        out.profile(view, from: json)
        return out.response(.ok)
    }

    // POST /api/users
    func register(_ body: Data) async throws -> WriteOutcome {
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

    // POST /api/users/login: the user (with its stored hash) read in a batch, then bcrypt in this task.
    func login(_ body: Data) async throws -> Response {
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
        guard case .login(let found, let json) = try await reads.read(.login(email: email), viewer: 0) else {
            throw ApiError(.internalServerError, "unexpected read result")
        }
        guard let found, try await bcrypt.verify(password, hash: found.hash) else {
            throw invalidBody(.unauthorized, "invalid email or password")
        }
        return userResponse(found.user, token: signer.issue(id: found.id), json: json)
    }

    // PUT /api/user
    func updateUser(viewer: Int64, token: String, _ body: Data) async throws -> WriteOutcome {
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

    // POST and DELETE /api/profiles/:username/follow
    func follow(viewer: Int64, username: String, on follow: Bool) async throws -> WriteOutcome {
        try await writes.run(.follow(viewer: viewer, username: username, on: follow))
    }

    /// GET /api/tags from the read batcher: the body its batch wrote once, copied.
    func tagsResponse(_ body: Range<Int32>, json: JSONBytes) -> Response {
        var out = JSONWriter(capacity: body.count)
        out.splice(json, body)
        return out.response(.ok)
    }

}
