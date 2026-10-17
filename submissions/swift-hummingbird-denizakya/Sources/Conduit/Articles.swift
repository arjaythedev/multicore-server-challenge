// Articles, feed, favorites (SPEC.md "Articles", "Favorites"). SQL verbatim from the spec.
import Foundation
import Hummingbird
import HummingbirdCore
import PostgresNIO

let articleListSelect = """
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

let articleFullSelect = """
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
"""

let orderPage = " ORDER BY a.id DESC LIMIT $2 OFFSET $3"

let listAll = articleListSelect + orderPage
let countAll = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"
let listByTag = articleListSelect
    + " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)"
    + " ORDER BY a.id DESC"
let countByTag = "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"
let listByAuthor = articleListSelect
    + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)"
    + orderPage
let countByAuthor = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"
let listByFavorite = articleListSelect
    + " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)"
    + " ORDER BY a.id DESC"
let countByFavorite = "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"
let listFeed = articleListSelect
    + " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)"
    + " ORDER BY a.id DESC"
let countFeed = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"

let articleBySlug = articleFullSelect + " WHERE a.slug = $2"
let articleByID = articleFullSelect + " WHERE a.id = $2"

let insertArticle = """
INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id
"""
let insertTags = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
let insertArticleTags = "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"

let updateArticle = """
UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1
"""

struct ArticleRow {
    var slug: String
    var title: String
    var description: String
    var body: String?
    var tagList: [String]
    var createdAt: Date
    var updatedAt: Date
    var favorited: Bool
    var favoritesCount: Int64
    var author: ProfileRow

    func json(full: Bool) -> String {
        var out = "{\"slug\":\(jsonEscape(slug)),\"title\":\(jsonEscape(title)),\"description\":\(jsonEscape(description)),"
        if full, let body { out += "\"body\":\(jsonEscape(body))," }
        out += "\"tagList\":["
        var first = true
        for t in tagList {
            if !first { out += "," }
            first = false
            out += jsonEscape(t)
        }
        out += "],\"createdAt\":\"\(rfc3339ms(createdAt))\",\"updatedAt\":\"\(rfc3339ms(updatedAt))\""
        out += ",\"favorited\":\(favorited ? "true" : "false"),\"favoritesCount\":\(favoritesCount)"
        out += ",\"author\":{\"username\":\(jsonEscape(author.username))"
        if let bio = author.bio { out += ",\"bio\":\(jsonEscape(bio))" } else { out += ",\"bio\":null" }
        if let image = author.image { out += ",\"image\":\(jsonEscape(image))" } else { out += ",\"image\":null" }
        out += ",\"following\":\(author.following ? "true" : "false")}}"
        return out
    }
}

extension PostgresRow {
    func listArticle() throws -> ArticleRow {
        ArticleRow(
            slug: try self.cell(1).text(),
            title: try self.cell(2).text(),
            description: try self.cell(3).text(),
            body: nil,
            tagList: try self.cell(6).textArray(),
            createdAt: try self.cell(4).date(),
            updatedAt: try self.cell(5).date(),
            favorited: try self.cell(8).bool(),
            favoritesCount: try self.cell(7).int(),
            author: ProfileRow(username: try self.cell(9).text(), bio: try self.cell(10).textOrNull(),
                               image: try self.cell(11).textOrNull(), following: try self.cell(12).bool())
        )
    }

    func fullArticle() throws -> ArticleRow {
        ArticleRow(
            slug: try self.cell(1).text(),
            title: try self.cell(2).text(),
            description: try self.cell(3).text(),
            body: try self.cell(4).text(),
            tagList: try self.cell(7).textArray(),
            createdAt: try self.cell(5).date(),
            updatedAt: try self.cell(6).date(),
            favorited: try self.cell(9).bool(),
            favoritesCount: try self.cell(8).int(),
            author: ProfileRow(username: try self.cell(10).text(), bio: try self.cell(11).textOrNull(),
                               image: try self.cell(12).textOrNull(), following: try self.cell(13).bool())
        )
    }
}

extension App {
    /// One article as seen by the viewer; 404 if no row.
    func writeFullArticle<Q: ArticleSQL>(status: HTTPResponse.Status, _ statement: ArticleByKey<Q>) async throws -> Response {
        guard let article = try await fetchAll(statement).first else {
            throw ApiError(.notFound, "article not found")
        }
        return jsonResponse(status, "{\"article\":\(article.json(full: true))}")
    }

    /// The page and its count run at the same time, on two pooled connections.
    func writeList<L: ArticleSQL, C: ArticleSQL>(list: ArticleList<L>, count: ArticleCount<C>) async throws -> Response {
        async let rows = fetchAll(list)
        async let total = fetchAll(count)
        var out = "{\"articles\":["
        var first = true
        for article in try await rows {
            if !first { out += "," }
            first = false
            out += article.json(full: false)
        }
        let n = try await total.first ?? 0
        out += "],\"articlesCount\":\(n)}"
        return jsonResponse(.ok, out)
    }

    // GET /api/articles
    func listArticles(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, secret: secret)
        let query = QueryParams(request.uri.query)
        let (limit, offset) = try limitOffset(query)
        // The first non-empty filter in the order tag, author, favorited applies.
        if let tag = query.get("tag"), !tag.isEmpty {
            return try await writeList(
                list: ArticleList<ListByTagSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: tag),
                count: ArticleCount<CountByTagSQL>(bind: tag))
        }
        if let author = query.get("author"), !author.isEmpty {
            return try await writeList(
                list: ArticleList<ListByAuthorSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: author),
                count: ArticleCount<CountByAuthorSQL>(bind: author))
        }
        if let favorited = query.get("favorited"), !favorited.isEmpty {
            return try await writeList(
                list: ArticleList<ListByFavoriteSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: favorited),
                count: ArticleCount<CountByFavoriteSQL>(bind: favorited))
        }
        return try await writeList(
            list: ArticleList<ListAllSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: nil),
            count: ArticleCount<CountAllSQL>(bind: nil))
    }

    // GET /api/articles/feed
    func feed(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let (limit, offset) = try limitOffset(QueryParams(request.uri.query))
        return try await writeList(
            list: ArticleList<ListFeedSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: nil),
            count: ArticleCount<CountFeedSQL>(bind: auth.viewer))
    }

    // GET /api/articles/:slug
    func getArticle(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, secret: secret)
        let slug = ctx.parameters.get("slug") ?? ""
        return try await writeFullArticle(status: .ok, ArticleByKey<ArticleBySlugSQL>(viewer: auth.viewer, key: slug))
    }

    // POST /api/articles
    func createArticle(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let m: [String: Any]
        do { m = try await readWrapper(request, "article") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let title: String
        let description: String
        let body: String
        let tagList: [String]
        do {
            title = try reqString(m, "title")
            description = try reqString(m, "description")
            body = try reqString(m, "body")
            tagList = try optTagList(m)
        } catch {
            throw ApiError(.unprocessableContent, "title, description and body are required")
        }

        let id = try await transaction { conn -> Int64 in
            let inserted = try await conn.query(makeQuery(insertArticle, [auth.viewer, title, description, body]), logger: App.queryLogger)
            var newId: Int64?
            for try await row in inserted { newId = try row.cell(0).int(); break }
            guard let newId else { throw ApiError(.internalServerError, "insert returned no row") }
            if !tagList.isEmpty {
                _ = try await conn.query(makeQuery(insertTags, [tagList]), logger: App.queryLogger)
                _ = try await conn.query(makeQuery(insertArticleTags, [newId, tagList]), logger: App.queryLogger)
            }
            return newId
        }
        return try await writeFullArticle(status: .created, ArticleByKey<ArticleByIDSQL>(viewer: auth.viewer, key: id))
    }

    private func updateArticleBinds(id: Int64, title: String?, description: String?, body: String?) -> PostgresBindings {
        var binds = PostgresBindings(capacity: 4)
        try? binds.append(id)
        try? binds.append(title)
        try? binds.append(description)
        try? binds.append(body)
        return binds
    }

    /// SELECT id, author_id FROM articles WHERE slug = $1: 404 if missing, 403 if not the viewer's.
    func ownArticle(_ slug: String, viewer: Int64) async throws -> Int64 {
        guard let row = try await queryRow("SELECT id, author_id FROM articles WHERE slug = $1", [slug]) else {
            throw ApiError(.notFound, "article not found")
        }
        let id = try row.cell(0).int()
        let author = try row.cell(1).int()
        guard author == viewer else { throw ApiError(.forbidden, "not the author") }
        return id
    }

    // PUT /api/articles/:slug
    func updateArticleHandler(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let slug = ctx.parameters.get("slug") ?? ""
        let m: [String: Any]
        do { m = try await readWrapper(request, "article") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let title: String?
        let description: String?
        let body: String?
        do {
            title = try optString(m, "title", nonEmpty: true)
            description = try optString(m, "description", nonEmpty: true)
            body = try optString(m, "body", nonEmpty: true)
        } catch {
            throw ApiError(.unprocessableContent, "title, description and body must be non-empty strings")
        }
        let id = try await ownArticle(slug, viewer: auth.viewer)
        try await exec(updateArticle, binds: updateArticleBinds(id: id, title: title, description: description, body: body))
        return try await writeFullArticle(status: .ok, ArticleByKey<ArticleByIDSQL>(viewer: auth.viewer, key: id))
    }

    // DELETE /api/articles/:slug
    func deleteArticle(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let slug = ctx.parameters.get("slug") ?? ""
        let id = try await ownArticle(slug, viewer: auth.viewer)
        try await exec("DELETE FROM articles WHERE id = $1", [id])
        return jsonResponse(.noContent, "")
    }

    /// SELECT id FROM articles WHERE slug = $1 -> 404.
    func articleID(_ slug: String) async throws -> Int64 {
        guard let row = try await queryRow("SELECT id FROM articles WHERE slug = $1", [slug]) else {
            throw ApiError(.notFound, "article not found")
        }
        return try row.cell(0).int()
    }

    // POST and DELETE /api/articles/:slug/favorite
    func favorite(_ request: Request, _ ctx: BasicRequestContext, fav: Bool) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let slug = ctx.parameters.get("slug") ?? ""
        // One round trip for the lookup and the toggle; no row means no such article (404).
        let toggle = fav
            ? "WITH a AS (SELECT id FROM articles WHERE slug = $2), ins AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM a ON CONFLICT DO NOTHING) SELECT id FROM a"
            : "WITH a AS (SELECT id FROM articles WHERE slug = $2), del AS (DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM a)) SELECT id FROM a"
        guard let row = try await queryRow(toggle, [auth.viewer, slug]) else {
            throw ApiError(.notFound, "article not found")
        }
        let id = try row.cell(0).int()
        return try await writeFullArticle(status: .ok, ArticleByKey<ArticleByIDSQL>(viewer: auth.viewer, key: id))
    }
}
