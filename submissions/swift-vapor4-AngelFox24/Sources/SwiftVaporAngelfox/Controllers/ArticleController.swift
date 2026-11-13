import Fluent
import Foundation
import Vapor

struct ArticleController: RouteCollection {
    private enum Filter {
        case all
        case tag(String)
        case author(String)
        case favorited(String)
        case feed
    }

    private enum ResolvedFilter {
        case all
        case tag(String)
        case author(Int)
        case favorited(Int)
        case feed([Int])
    }

    func boot(routes: any RoutesBuilder) throws {
        let articles = routes.grouped("api", "articles")
        articles.get(use: self.index)
        articles.get("feed", use: self.feed)
        articles.post(use: self.create)

        articles.group(":slug") { article in
            article.get(use: self.show)
            article.put(use: self.update)
            article.delete(use: self.deleteArticle)
            article.post("favorite", use: self.favorite)
            article.delete("favorite", use: self.unfavorite)
        }
    }

    // MARK: - Lists

    @Sendable
    func index(req: Request) async throws -> Response {
        let viewer = try await req.authenticate(required: false)?.id ?? 0
        let query = try req.query.decode(ArticleListQuery.self)
        let (limit, offset) = try parseLimitOffset(query)

        let filter: Filter
        if let tag = query.tag, !tag.isEmpty {
            filter = .tag(tag)
        } else if let author = query.author, !author.isEmpty {
            filter = .author(author)
        } else if let favorited = query.favorited, !favorited.isEmpty {
            filter = .favorited(favorited)
        } else {
            filter = .all
        }

        return try await list(req: req, filter: filter, viewer: viewer, limit: limit, offset: offset)
    }

    @Sendable
    func feed(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let query = try req.query.decode(ArticleListQuery.self)
        let (limit, offset) = try parseLimitOffset(query)
        return try await list(req: req, filter: .feed, viewer: auth.id, limit: limit, offset: offset)
    }

    // MARK: - Single article

    @Sendable
    func show(req: Request) async throws -> Response {
        let viewer = try await req.authenticate(required: false)?.id ?? 0
        let slug = try req.parameters.require("slug")
        let article = try await articleBySlug(slug, on: req.db)
        let dto = try await fullDTO(article, viewer: viewer, on: req.db)
        return try jsonResponse(.ok, ArticleResponse(article: dto))
    }

    @Sendable
    func create(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let payload = try req.content.decode(CreateArticleRequest.self).article
        guard !payload.title.isEmpty, !payload.description.isEmpty, !payload.body.isEmpty else {
            throw APIError(.unprocessableEntity, "title, description and body are required")
        }

        let tags = try validatedTags(payload.tagList)
        let article = Article(
            authorID: auth.id,
            // A unique temporary slug lets Fluent fetch the generated bigint id;
            // the final slug is `SLUGIFY(title) + "-" + id`, as in the reference SQL.
            slug: "pending-\(UUID().uuidString.lowercased())",
            title: payload.title,
            description: payload.description,
            body: payload.body
        )
        let now = Date()
        article.createdAt = now
        article.updatedAt = now

        let articleID: Int = try await req.db.transaction { database in
            try await article.save(on: database)
            let id = try article.requireID()

            // Rename through the query builder rather than `save()` and pin
            // `updated_at` back to `created_at`: Fluent auto-fills the update
            // timestamp, but a newly created article must report equal times.
            let createdAt = article.createdAt ?? Date()
            try await Article.query(on: database)
                .filter(\.$id == id)
                .set(\.$slug, to: "\(slugify(payload.title))-\(id)")
                .set(\.$updatedAt, to: createdAt)
                .update()

            try await self.insertTags(tags, articleID: id, on: database)
            return id
        }

        guard let created = try await Article.query(on: req.db)
            .filter(\.$id == articleID)
            .with(\.$author)
            .first()
        else {
            throw APIError(.internalServerError, "article was not found after creation")
        }

        let dto = try await fullDTO(created, viewer: auth.id, on: req.db)
        return try jsonResponse(.created, ArticleResponse(article: dto))
    }

    @Sendable
    func update(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let slug = try req.parameters.require("slug")
        let payload = try req.content.decode(UpdateArticleRequest.self).article

        // As in the reference implementation, provided string fields must be
        // non-empty; omitted (or null) fields keep their current value.
        if let title = payload.title, title.isEmpty {
            throw APIError(.unprocessableEntity, "title, description and body must be non-empty strings")
        }
        if let description = payload.description, description.isEmpty {
            throw APIError(.unprocessableEntity, "title, description and body must be non-empty strings")
        }
        if let body = payload.body, body.isEmpty {
            throw APIError(.unprocessableEntity, "title, description and body must be non-empty strings")
        }

        let article = try await articleBySlug(slug, on: req.db)
        guard article.$author.id == auth.id else {
            throw APIError(.forbidden, "not the author")
        }

        if let title = payload.title {
            article.title = title
            article.slug = "\(slugify(title))-\(try article.requireID())"
        }
        if let description = payload.description {
            article.description = description
        }
        if let body = payload.body {
            article.body = body
        }

        article.updatedAt = Date()
        try await article.save(on: req.db)

        let dto = try await fullDTO(article, viewer: auth.id, on: req.db)
        return try jsonResponse(.ok, ArticleResponse(article: dto))
    }

    @Sendable
    func deleteArticle(req: Request) async throws -> Response {
        let auth = try await req.requireUser()
        let slug = try req.parameters.require("slug")

        let article = try await articleBySlug(slug, on: req.db)
        guard article.$author.id == auth.id else {
            throw APIError(.forbidden, "not the author")
        }

        try await article.delete(on: req.db)
        return Response(status: .noContent)
    }

    // MARK: - Favorites

    @Sendable
    func favorite(req: Request) async throws -> Response {
        try await self.setFavorite(req: req, favorite: true)
    }

    @Sendable
    func unfavorite(req: Request) async throws -> Response {
        try await self.setFavorite(req: req, favorite: false)
    }

    private func setFavorite(req: Request, favorite: Bool) async throws -> Response {
        let auth = try await req.requireUser()
        let slug = try req.parameters.require("slug")
        let article = try await articleBySlug(slug, on: req.db)
        let articleID = try article.requireID()

        if favorite {
            let existing = try await Favorite.query(on: req.db)
                .filter(\.$id == auth.id)
                .filter(\.$article.$id == articleID)
                .first()

            if existing == nil {
                let favorite = Favorite(userID: auth.id, articleID: articleID)
                do {
                    try await favorite.create(on: req.db)
                } catch let error where error.isConstraintFailure {
                    // A concurrent request already created it.
                }
            }
        } else {
            try await Favorite.query(on: req.db)
                .filter(\.$id == auth.id)
                .filter(\.$article.$id == articleID)
                .delete()
        }

        let dto = try await fullDTO(article, viewer: auth.id, on: req.db)
        return try jsonResponse(.ok, ArticleResponse(article: dto))
    }

    // MARK: - Shared queries

    private func list(
        req: Request,
        filter: Filter,
        viewer: Int,
        limit: Int,
        offset: Int
    ) async throws -> Response {
        guard let resolved = try await resolve(filter, viewer: viewer, on: req.db) else {
            return try jsonResponse(.ok, ArticleListResponse(articles: [], articlesCount: 0))
        }

        let articles = try await query(for: resolved, on: req.db)
            .with(\.$author)
            .sort(\.$id, .descending)
            .range(offset ..< (offset + limit))
            .all()

        // `articlesCount` is capped at 1,000 in the challenge spec.
        let articlesCount = try await query(for: resolved, on: req.db)
            .field(\.$id)
            .limit(1000)
            .all()
            .count

        let dtos = try await listDTOs(articles, viewer: viewer, on: req.db)
        return try jsonResponse(.ok, ArticleListResponse(articles: dtos, articlesCount: articlesCount))
    }

    private func resolve(
        _ filter: Filter,
        viewer: Int,
        on database: any Database
    ) async throws -> ResolvedFilter? {
        switch filter {
        case .all:
            return .all
        case .tag(let tag):
            return .tag(tag)
        case .author(let username):
            guard let user = try await User.query(on: database)
                .filter(\.$username == username)
                .first()
            else {
                return nil
            }
            return .author(try user.requireID())
        case .favorited(let username):
            guard let user = try await User.query(on: database)
                .filter(\.$username == username)
                .first()
            else {
                return nil
            }
            return .favorited(try user.requireID())
        case .feed:
            let followeeIDs = try await Follow.query(on: database)
                .filter(\.$id == viewer)
                .all()
                .map { $0.$followee.id }
            guard !followeeIDs.isEmpty else { return nil }
            return .feed(followeeIDs)
        }
    }

    private func query(for filter: ResolvedFilter, on database: any Database) -> QueryBuilder<Article> {
        let query = Article.query(on: database)

        switch filter {
        case .all:
            break
        case .tag(let name):
            query
                .join(ArticleTag.self, on: \ArticleTag.$id == \Article.$id)
                .join(Tag.self, on: \Tag.$id == \ArticleTag.$tag.$id)
                .filter(Tag.self, \.$name == name)
        case .author(let id):
            query.filter(\.$author.$id == id)
        case .favorited(let id):
            query
                .join(Favorite.self, on: \Favorite.$article.$id == \Article.$id)
                .filter(Favorite.self, \.$id == id)
        case .feed(let ids):
            query.filter(\.$author.$id ~~ ids)
        }

        return query
    }

    private func articleBySlug(_ slug: String, on database: any Database) async throws -> Article {
        guard let article = try await Article.query(on: database)
            .filter(\.$slug == slug)
            .with(\.$author)
            .first()
        else {
            throw APIError(.notFound, "article not found")
        }
        return article
    }

    // MARK: - DTO assembly

    private func listDTOs(
        _ articles: [Article],
        viewer: Int,
        on database: any Database
    ) async throws -> [ArticleDTO] {
        guard !articles.isEmpty else { return [] }
        let articleIDs = try articles.map { try $0.requireID() }

        let tagRows = try await ArticleTag.query(on: database)
            .filter(\.$id ~~ articleIDs)
            .with(\.$tag)
            .all()
        var tagsByArticle: [Int: [String]] = [:]
        for row in tagRows {
            guard let articleID = row.id else { continue }
            tagsByArticle[articleID, default: []].append(row.tag.name)
        }
        tagsByArticle = tagsByArticle.mapValues { $0.sorted() }

        let favoriteRows = try await Favorite.query(on: database)
            .filter(\.$article.$id ~~ articleIDs)
            .all()
        var favoriteCounts: [Int: Int] = [:]
        var favoritedIDs: Set<Int> = []
        for row in favoriteRows {
            let articleID = row.$article.id
            favoriteCounts[articleID, default: 0] += 1
            if row.id == viewer {
                favoritedIDs.insert(articleID)
            }
        }

        var followedIDs: Set<Int> = []
        if viewer > 0 {
            followedIDs = Set(try await Follow.query(on: database)
                .filter(\.$id == viewer)
                .all()
                .map { $0.$followee.id })
        }

        return try articles.map { article in
            let id = try article.requireID()
            return try article.toDTO(
                tags: tagsByArticle[id] ?? [],
                favorited: favoritedIDs.contains(id),
                favoritesCount: favoriteCounts[id] ?? 0,
                following: followedIDs.contains(article.$author.id),
                includeBody: false
            )
        }
    }

    private func fullDTO(
        _ article: Article,
        viewer: Int,
        on database: any Database
    ) async throws -> ArticleDTO {
        let articleID = try article.requireID()

        let tags = try await ArticleTag.query(on: database)
            .filter(\.$id == articleID)
            .with(\.$tag)
            .all()
            .map(\.tag.name)
            .sorted()

        let favoritesCount = try await Favorite.query(on: database)
            .filter(\.$article.$id == articleID)
            .count()

        var favorited = false
        var following = false
        if viewer > 0 {
            favorited = try await Favorite.query(on: database)
                .filter(\.$id == viewer)
                .filter(\.$article.$id == articleID)
                .first() != nil

            following = try await Follow.query(on: database)
                .filter(\.$id == viewer)
                .filter(\.$followee.$id == article.$author.id)
                .first() != nil
        }

        return try article.toDTO(
            tags: tags,
            favorited: favorited,
            favoritesCount: favoritesCount,
            following: following,
            includeBody: true
        )
    }

    // MARK: - Tags and query parameters

    private func validatedTags(_ tags: [String]?) throws -> [String] {
        guard let tags else { return [] }
        for tag in tags where tag.isEmpty {
            throw APIError(.unprocessableEntity, "tagList must contain non-empty strings")
        }
        // The reference SQL uses `SELECT DISTINCT unnest(...)`.
        return Array(Set(tags))
    }

    private func insertTags(_ names: [String], articleID: Int, on database: any Database) async throws {
        for name in names {
            let tag = try await findOrCreateTag(named: name, on: database)

            let link = ArticleTag(articleID: articleID, tagID: try tag.requireID())
            do {
                try await link.create(on: database)
            } catch let error where error.isConstraintFailure {
                // Already linked by a concurrent request.
            }
        }
    }

    private func findOrCreateTag(named name: String, on database: any Database) async throws -> Tag {
        if let existing = try await Tag.query(on: database)
            .filter(\.$name == name)
            .first()
        {
            return existing
        }

        let tag = Tag(name: name)
        do {
            try await tag.create(on: database)
            return tag
        } catch let error where error.isConstraintFailure {
            guard let existing = try await Tag.query(on: database)
                .filter(\.$name == name)
                .first()
            else {
                throw error
            }
            return existing
        }
    }

    private func parseLimitOffset(_ query: ArticleListQuery) throws -> (Int, Int) {
        var limit = 20
        if let rawLimit = query.limit {
            guard let value = parseUnsignedInteger(rawLimit), value >= 1, value <= 100 else {
                throw APIError(.unprocessableEntity, "limit must be 1-100")
            }
            limit = value
        }

        var offset = 0
        if let rawOffset = query.offset {
            guard let value = parseUnsignedInteger(rawOffset) else {
                throw APIError(.unprocessableEntity, "offset must be a non-negative integer")
            }
            offset = value
        }

        return (limit, offset)
    }
}
