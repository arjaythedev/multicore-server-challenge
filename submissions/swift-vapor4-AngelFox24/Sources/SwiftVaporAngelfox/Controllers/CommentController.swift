import Fluent
import Vapor

struct CommentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let comments = routes.grouped("api", "articles", ":slug", "comments")
        comments.get(use: self.index)
        comments.post(use: self.create)
        comments.delete(":id", use: self.deleteComment)
    }

    @Sendable
    func index(req: Request) async throws -> Response {
        let viewer = try await req.authenticate(required: false)?.id ?? 0
        let slug = try req.parameters.require("slug")
        let articleID = try await articleID(for: slug, on: req.db)

        let comments = try await Comment.query(on: req.db)
            .filter(\.$article.$id == articleID)
            .with(\.$author)
            .sort(\.$createdAt, .descending)
            .sort(\.$id, .descending)
            .limit(100)
            .all()

        var followedIDs: Set<Int> = []
        if viewer > 0 {
            followedIDs = Set(try await Follow.query(on: req.db)
                .filter(\.$id == viewer)
                .all()
                .map { $0.$followee.id })
        }

        let dtos = try comments.map { comment in
            try comment.toDTO(following: followedIDs.contains(comment.$author.id))
        }
        return try jsonResponse(.ok, CommentListResponse(comments: dtos))
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let slug = try req.parameters.require("slug")
        let payload = try req.content.decode(CreateCommentRequest.self).comment

        guard !payload.body.isEmpty else {
            throw APIError(.unprocessableEntity, "body is required")
        }

        let articleID = try await articleID(for: slug, on: req.db)
        let comment = Comment(articleID: articleID, authorID: auth.id, body: payload.body)
        let now = Date()
        comment.createdAt = now
        comment.updatedAt = now
        try await comment.create(on: req.db)

        guard let created = try await Comment.query(on: req.db)
            .filter(\.$id == comment.requireID())
            .with(\.$author)
            .first()
        else {
            throw APIError(.internalServerError, "comment was not found after creation")
        }

        // The reference implementation always returns `following: false` here.
        return try jsonResponse(.created, CommentResponse(comment: created.toDTO(following: false)))
    }

    @Sendable
    func deleteComment(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let slug = try req.parameters.require("slug")

        guard let rawID = req.parameters.get("id"),
              let commentID = parseUnsignedInteger(rawID)
        else {
            throw APIError(.notFound, "comment not found")
        }

        let articleID = try await articleID(for: slug, on: req.db)
        guard let comment = try await Comment.query(on: req.db)
            .filter(\.$id == commentID)
            .filter(\.$article.$id == articleID)
            .first()
        else {
            throw APIError(.notFound, "comment not found")
        }

        guard comment.$author.id == auth.id else {
            throw APIError(.forbidden, "not the author")
        }

        try await comment.delete(on: req.db)
        return Response(status: .noContent)
    }

    private func articleID(for slug: String, on database: any Database) async throws -> Int {
        guard let article = try await Article.query(on: database)
            .filter(\.$slug == slug)
            .first()
        else {
            throw APIError(.notFound, "article not found")
        }
        return try article.requireID()
    }
}
