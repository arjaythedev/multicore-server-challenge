// Articles, feed, favorites (SPEC.md "Articles", "Favorites"). SQL verbatim from the spec.
import HTTPTypes
import Hummingbird
import Logging
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
let countByTag = "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s"
let listByAuthor = articleListSelect
    + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)"
    + orderPage
let countByAuthor = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s"
let listByFavorite = articleListSelect
    + " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)"
    + " ORDER BY a.id DESC"
let countByFavorite = "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s"
let listFeed = articleListSelect
    + " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)"
    + " ORDER BY a.id DESC"
let countFeed = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"

/// A list and its count as one statement: the count's single row, LEFT JOINed to the page, so an empty page still
/// returns the total (with NULL article columns). One pooled connection and one round trip per list request, and the
/// page and its total come from the same snapshot. The filtered counts take the list's filter as $4.
func articlePage(count: String, list: String) -> String {
    "SELECT cnt.count, l.* FROM (\(count)) cnt LEFT JOIN (\(list)) l ON true ORDER BY l.id DESC"
}

let pageAll = articlePage(count: countAll, list: listAll)
let pageByTag = articlePage(count: countByTag, list: listByTag)
let pageByAuthor = articlePage(count: countByAuthor, list: listByAuthor)
let pageByFavorite = articlePage(count: countByFavorite, list: listByFavorite)
let pageFeed = articlePage(count: countFeed, list: listFeed)

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
    var slug: PGText
    var title: PGText
    var description: PGText
    var body: PGText?
    var tagList: [PGText]
    var createdAt: PGTimestamp
    var updatedAt: PGTimestamp
    var favorited: Bool
    var favoritesCount: Int64
    var author: ProfileRow
}

extension JSONWriter {
    mutating func article(_ a: borrowing ArticleRow, full: Bool) {
        raw("{\"slug\":"); string(a.slug)
        raw(",\"title\":"); string(a.title)
        raw(",\"description\":"); string(a.description)
        if full, a.body != nil { raw(",\"body\":"); string(a.body!) }
        raw(",\"tagList\":[")
        for i in a.tagList.indices {
            if i > 0 { raw(",") }
            string(a.tagList[i])
        }
        raw("],\"createdAt\":"); timestamp(a.createdAt)
        raw(",\"updatedAt\":"); timestamp(a.updatedAt)
        raw(",\"favorited\":"); bool(a.favorited)
        raw(",\"favoritesCount\":"); int(a.favoritesCount)
        raw(",\"author\":"); author(a.author)
        raw("}")
    }
}

/// One row of an article page: the list's total, and the article (nil on the single row of an empty page).
struct ArticlePageRow {
    var total: Int64
    var article: ArticleRow?
}

extension PostgresRow {
    /// `articlePage`'s columns: the total, then ARTICLE_LIST_SELECT's (all NULL when the page is empty).
    func articlePageRow() throws -> ArticlePageRow {
        var cells = RowCursor(self)
        let total = try cells.int()
        guard try cells.intOrNull() != nil else { return ArticlePageRow(total: total, article: nil) } // a.id
        return ArticlePageRow(total: total, article: try cells.article(withBody: false))
    }

    /// The full select's columns: the list's, plus body.
    func fullArticle() throws -> ArticleRow {
        var cells = RowCursor(self)
        try cells.skip() // a.id
        return try cells.article(withBody: true)
    }
}

extension RowCursor {
    /// An article's columns after `a.id`, in select order.
    mutating func article(withBody: Bool) throws -> ArticleRow {
        let slug = try text()
        let title = try text()
        let description = try text()
        let body: PGText? = try withBody ? text() : nil
        let createdAt = try timestamp()
        let updatedAt = try timestamp()
        let tagList = try textArray()
        let favoritesCount = try int()
        let favorited = try bool()
        let username = try text()
        let bio = try textOrNull()
        let image = try textOrNull()
        let following = try bool()
        return ArticleRow(slug: slug, title: title, description: description, body: body, tagList: tagList,
                          createdAt: createdAt, updatedAt: updatedAt, favorited: favorited, favoritesCount: favoritesCount,
                          author: ProfileRow(username: username, bio: bio, image: image, following: following))
    }
}

extension App {
    /// One article as seen by the viewer; 404 if no row.
    func writeFullArticle<Q: ArticleSQL>(status: HTTPResponse.Status, _ statement: ArticleByKey<Q>) async throws -> Response {
        guard let article = try await fetchFirst(statement) else {
            throw ApiError(.notFound, "article not found")
        }
        return articleResponse(status, article)
    }

    func articleResponse(_ status: HTTPResponse.Status, _ article: borrowing ArticleRow) -> Response {
        var out = JSONWriter(capacity: 1024 + (article.body?.bytes.readableBytes ?? 0))
        out.raw("{\"article\":")
        out.article(article, full: true)
        out.raw("}")
        return out.response(status)
    }

    /// A page from the read batcher.
    func pageResponse(total: Int64, articles: [ArticleRow]) -> Response {
        var out = JSONWriter(capacity: 256 + articles.count * 512)
        out.raw("{\"articles\":[")
        for i in articles.indices {
            if i > 0 { out.raw(",") }
            out.article(articles[i], full: false)
        }
        out.raw("],\"articlesCount\":")
        out.int(total)
        out.raw("}")
        return out.response(.ok)
    }

    /// The page's rows stream straight into the response; each carries the list's total.
    func writeList<Q: ArticleSQL>(_ page: ArticlePage<Q>) async throws -> Response {
        var out = JSONWriter(capacity: 256 + Int(page.limit) * 512)
        out.raw("{\"articles\":[")
        var total: Int64 = 0
        var first = true
        for try await row in try await db.execute(page, logger: App.queryLogger) {
            total = row.total
            guard let article = row.article else { continue }
            if !first { out.raw(",") }
            first = false
            out.article(article, full: false)
        }
        out.raw("],\"articlesCount\":")
        out.int(total)
        out.raw("}")
        return out.response(.ok)
    }

    // GET /api/articles
    func listArticles(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, signer)
        let query = QueryParams(request.uri.query)
        let (limit, offset) = try limitOffset(query)
        // The first non-empty filter in the order tag, author, favorited applies; later ones aren't even looked up.
        let kind: PageKind =
            if let tag = query.get("tag"), !tag.isEmpty { .tag(tag) }
            else if let author = query.get("author"), !author.isEmpty { .author(author) }
            else if let favorited = query.get("favorited"), !favorited.isEmpty { .favorited(favorited) }
            else { .all }
        if let reads {
            let page = try await reads.page(kind, limit: limit, offset: offset, viewer: auth.viewer)
            return pageResponse(total: page.total, articles: page.articles)
        }
        switch kind {
        case .all:
            return try await writeList(ArticlePage<PageAllSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: nil))
        case .tag(let tag):
            return try await writeList(ArticlePage<PageByTagSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: tag))
        case .author(let author):
            return try await writeList(ArticlePage<PageByAuthorSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: author))
        case .favorited(let name):
            return try await writeList(ArticlePage<PageByFavoriteSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: name))
        case .feed(let viewer):
            return try await writeList(ArticlePage<PageFeedSQL>(viewer: viewer, limit: limit, offset: offset, filter: nil))
        }
    }

    // GET /api/articles/feed
    func feed(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let (limit, offset) = try limitOffset(QueryParams(request.uri.query))
        if let reads {
            let page = try await reads.page(.feed(auth.viewer), limit: limit, offset: offset, viewer: auth.viewer)
            return pageResponse(total: page.total, articles: page.articles)
        }
        return try await writeList(ArticlePage<PageFeedSQL>(viewer: auth.viewer, limit: limit, offset: offset, filter: nil))
    }

    // GET /api/articles/:slug
    func getArticle(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, signer)
        let slug = ctx.parameters.get("slug") ?? ""
        if let reads {
            guard let article = try await reads.article(slug: slug, viewer: auth.viewer) else {
                throw ApiError(.notFound, "article not found")
            }
            return articleResponse(.ok, article)
        }
        return try await writeFullArticle(status: .ok, ArticleByKey<ArticleBySlugSQL>(viewer: auth.viewer, key: slug))
    }

    // POST /api/articles
    func createArticle(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
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

        let id = try await db.withTransaction(logger: App.queryLogger) { conn -> Int64 in
            let inserted = try await conn.query(makeQuery(insertArticle, [auth.viewer, title, description, body]), logger: App.queryLogger)
            var newId: Int64?
            for try await row in inserted {
                var cells = RowCursor(row)
                newId = try cells.int()
                break
            }
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
        binds.append(id)
        binds.append(title)
        binds.append(description)
        binds.append(body)
        return binds
    }

    /// SELECT id, author_id FROM articles WHERE slug = $1: 404 if missing, 403 if not the viewer's.
    func ownArticle(_ slug: String, viewer: Int64) async throws -> Int64 {
        guard let row = try await queryRow("SELECT id, author_id FROM articles WHERE slug = $1", [slug]) else {
            throw ApiError(.notFound, "article not found")
        }
        var cells = RowCursor(row)
        let id = try cells.int()
        guard try cells.int() == viewer else { throw ApiError(.forbidden, "not the author") }
        return id
    }

    // PUT /api/articles/:slug
    func updateArticleHandler(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
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
        let auth = try Auth.require(request, signer)
        let slug = ctx.parameters.get("slug") ?? ""
        let id = try await ownArticle(slug, viewer: auth.viewer)
        try await exec("DELETE FROM articles WHERE id = $1", [id])
        return emptyResponse(.noContent)
    }

    // POST and DELETE /api/articles/:slug/favorite
    func favorite(_ request: Request, _ ctx: BasicRequestContext, fav: Bool) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let slug = ctx.parameters.get("slug") ?? ""
        // One round trip for the lookup and the toggle; no row means no such article (404).
        let toggle = fav
            ? "WITH a AS (SELECT id FROM articles WHERE slug = $2), ins AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM a ON CONFLICT DO NOTHING) SELECT id FROM a"
            : "WITH a AS (SELECT id FROM articles WHERE slug = $2), del AS (DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM a)) SELECT id FROM a"
        guard let row = try await queryRow(toggle, [auth.viewer, slug]) else {
            throw ApiError(.notFound, "article not found")
        }
        var cells = RowCursor(row)
        let id = try cells.int()
        return try await writeFullArticle(status: .ok, ArticleByKey<ArticleByIDSQL>(viewer: auth.viewer, key: id))
    }
}
