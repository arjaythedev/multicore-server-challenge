import Fluent
import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let users = routes.grouped("api", "users")
        users.post(use: self.register)
        users.post("login", use: self.login)

        let user = routes.grouped("api", "user")
        user.get(use: self.current)
        user.put(use: self.update)
    }

    @Sendable
    func register(req: Request) async throws -> Response {
        let payload = try req.content.decode(RegisterRequest.self).user
        guard !payload.username.isEmpty, !payload.email.isEmpty, !payload.password.isEmpty else {
            throw APIError(.unprocessableEntity, "username, email and password are required")
        }
        guard payload.password.utf8.count <= 72 else {
            throw APIError(.unprocessableEntity, "password is too long")
        }

        let passwordHash = try await req.password.async.hash(payload.password).get()
        let user = User(username: payload.username, email: payload.email, passwordHash: passwordHash)

        do {
            try await user.create(on: req.db)
        } catch let error where error.isConstraintFailure {
            throw APIError(.unprocessableEntity, "username or email is already taken")
        }

        let id = try user.requireID()
        let token = try await issueToken(for: id, on: req)
        return try jsonResponse(.created, UserResponse(user: try user.toDTO(token: token)))
    }

    @Sendable
    func login(req: Request) async throws -> Response {
        let payload = try req.content.decode(LoginRequest.self).user
        guard !payload.email.isEmpty, !payload.password.isEmpty else {
            throw APIError(.unprocessableEntity, "email and password are required")
        }

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == payload.email)
            .first()
        else {
            throw APIError(.unauthorized, "invalid email or password")
        }

        let passwordMatches = try await req.password.async
            .verify(payload.password, created: user.passwordHash)
            .get()
        guard passwordMatches else {
            throw APIError(.unauthorized, "invalid email or password")
        }

        let token = try await issueToken(for: try user.requireID(), on: req)
        return try jsonResponse(.ok, UserResponse(user: try user.toDTO(token: token)))
    }

    @Sendable
    func current(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        guard let user = try await User.find(auth.id, on: req.db) else {
            throw APIError(.unauthorized, "unauthorized")
        }
        return try jsonResponse(.ok, UserResponse(user: try user.toDTO(token: auth.token)))
    }

    @Sendable
    func update(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let payload = try req.content.decode(UpdateUserRequest.self).user

        guard let user = try await User.find(auth.id, on: req.db) else {
            throw APIError(.unauthorized, "unauthorized")
        }

        // As in the reference implementation, `email`, `username` and `password`
        // must be non-empty when present; `bio` and `image` may be cleared.
        if let email = payload.email {
            guard !email.isEmpty else {
                throw APIError(.unprocessableEntity, "invalid user fields")
            }
            user.email = email
        }
        if let username = payload.username {
            guard !username.isEmpty else {
                throw APIError(.unprocessableEntity, "invalid user fields")
            }
            user.username = username
        }
        if let password = payload.password {
            guard !password.isEmpty, password.utf8.count <= 72 else {
                throw APIError(.unprocessableEntity, "invalid user fields")
            }
            user.passwordHash = try await req.password.async.hash(password).get()
        }
        if let bio = payload.bio {
            user.bio = bio
        }
        if let image = payload.image {
            user.image = image
        }

        do {
            try await user.save(on: req.db)
        } catch let error where error.isConstraintFailure {
            throw APIError(.unprocessableEntity, "username or email is already taken")
        }

        return try jsonResponse(.ok, UserResponse(user: try user.toDTO(token: auth.token)))
    }
}
