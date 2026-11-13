import Fluent
import Vapor

struct ProfileController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let profiles = routes.grouped("api", "profiles", ":username")
        profiles.get(use: self.show)
        profiles.post("follow", use: self.follow)
        profiles.delete("follow", use: self.unfollow)
    }

    @Sendable
    func show(req: Request) async throws -> Response {
        let viewer = try await req.authenticate(required: false)?.id ?? 0
        let username = try req.parameters.require("username")

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == username)
            .first()
        else {
            throw APIError(.notFound, "profile not found")
        }

        let following = try await self.isFollowing(
            viewer: viewer,
            userID: try user.requireID(),
            on: req.db
        )
        return try jsonResponse(.ok, ProfileResponse(profile: user.toProfile(following: following)))
    }

    @Sendable
    func follow(req: Request) async throws -> Response {
        try await self.setFollowing(req: req, follow: true)
    }

    @Sendable
    func unfollow(req: Request) async throws -> Response {
        try await self.setFollowing(req: req, follow: false)
    }

    private func setFollowing(req: Request, follow: Bool) async throws -> Response {
        let auth = try await req.requireUser()
        let username = try req.parameters.require("username")

        guard let user = try await User.query(on: req.db)
            .filter(\.$username == username)
            .first()
        else {
            throw APIError(.notFound, "profile not found")
        }
        let followeeID = try user.requireID()

        if follow {
            let existing = try await Follow.query(on: req.db)
                .filter(\.$id == auth.id)
                .filter(\.$followee.$id == followeeID)
                .first()

            if existing == nil {
                let relationship = Follow(followerID: auth.id, followeeID: followeeID)
                do {
                    try await relationship.create(on: req.db)
                } catch let error where error.isConstraintFailure {
                    // Another request inserted the same follow concurrently.
                }
            }
        } else {
            try await Follow.query(on: req.db)
                .filter(\.$id == auth.id)
                .filter(\.$followee.$id == followeeID)
                .delete()
        }

        return try jsonResponse(
            .ok,
            ProfileResponse(profile: user.toProfile(following: follow))
        )
    }

    private func isFollowing(viewer: Int, userID: Int, on database: any Database) async throws -> Bool {
        guard viewer > 0 else { return false }
        let relationship = try await Follow.query(on: database)
            .filter(\.$id == viewer)
            .filter(\.$followee.$id == userID)
            .first()
        return relationship != nil
    }
}
