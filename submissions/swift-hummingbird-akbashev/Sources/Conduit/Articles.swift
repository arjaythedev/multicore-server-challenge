// Articles, feed, favorites (SPEC.md "Articles", "Favorites"). SQL verbatim from the spec.
import HTTPTypes
import Hummingbird
import Logging
import NIOCore
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
RETURNING id, slug
"""
let insertTags = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
let insertArticleTags = "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"

let updateArticleSQL = """
UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1
RETURNING slug
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
        articleUpToFavorited(a, full: full)
        bool(a.favorited)
        articleUpToFollowing(a)
        bool(a.author.following)
        raw("}}")
    }

    /// An article up to its `favorited` value: the part that is the same for every viewer.
    private mutating func articleUpToFavorited(_ a: borrowing ArticleRow, full: Bool) {
        raw("{\"slug\":"); string(a.slug)
        raw(",\"title\":"); string(a.title)
        raw(",\"description\":"); string(a.description)
        if full, let body = a.body { raw(",\"body\":"); string(body) }
        raw(",\"tagList\":[")
        for i in a.tagList.indices {
            if i > 0 { raw(",") }
            string(a.tagList[i])
        }
        raw("],\"createdAt\":"); timestamp(a.createdAt)
        raw(",\"updatedAt\":"); timestamp(a.updatedAt)
        raw(",\"favorited\":")
    }

    /// From after `favorited` up to the author's `following` value.
    private mutating func articleUpToFollowing(_ a: borrowing ArticleRow) {
        raw(",\"favoritesCount\":"); int(a.favoritesCount)
        raw(",\"author\":"); authorUpToFollowing(a.author)
    }

    /// The article once for a whole batch, with its two viewer-dependent values left open.
    mutating func articleSplice(_ a: borrowing ArticleRow, full: Bool) -> ArticleSplice {
        let start = position
        articleUpToFavorited(a, full: full)
        let favorited = position
        articleUpToFollowing(a)
        return ArticleSplice(start: Int32(start), favorited: Int32(favorited), following: Int32(position))
    }

    /// One viewer's copy of an article written by `articleSplice`.
    mutating func article(_ view: ArticleView, from json: borrowing ByteBuffer) {
        let s = view.splice
        splice(json, s.start..<s.favorited)
        bool(view.favorited)
        splice(json, s.favorited..<s.following)
        bool(view.following)
        raw("}}")
    }
}

/// Where an article's JSON sits in its batch's buffer: from `start`, with the `favorited` value due at `favorited` and
/// the author's `following` value at `following`; the object then ends with `}}`.
struct ArticleSplice: Sendable, BitwiseCopyable {
    let start: Int32
    let favorited: Int32
    let following: Int32

    var length: Int { Int(following - start) + 16 }
}

/// An article of a batch as one viewer sees it.
struct ArticleView: Sendable, BitwiseCopyable {
    let splice: ArticleSplice
    let favorited: Bool
    let following: Bool
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
    func writeFullArticle<Q: ArticleSQL>(status: Status, _ statement: ArticleByKey<Q>) async throws -> Response {
        guard let article = try await fetchFirst(statement) else {
            throw ApiError(.notFound, "article not found")
        }
        return articleResponse(status, article)
    }

    func articleResponse(_ status: Status, _ article: borrowing ArticleRow) -> Response {
        var out = JSONWriter(capacity: 1024 + (article.body?.bytes.readableBytes ?? 0))
        out.raw("{\"article\":")
        out.article(article, full: true)
        out.raw("}")
        return out.response(status)
    }

    /// A page from the read batcher: its articles copied from the batch's JSON.
    func pageResponse(total: Int64, articles: borrowing [ArticleView], json: borrowing ByteBuffer) -> Response {
        var size = 64
        for i in articles.indices { size += articles[i].splice.length }
        var out = JSONWriter(capacity: size)
        out.raw("{\"articles\":[")
        for i in articles.indices {
            if i > 0 { out.raw(",") }
            out.article(articles[i], from: json)
        }
        out.raw("],\"articlesCount\":")
        out.int(total)
        out.raw("}")
        return out.response(.ok)
    }

    func emptyPage() -> Response {
        var out = JSONWriter(capacity: 40)
        out.raw("{\"articles\":[],\"articlesCount\":0}")
        return out.response(.ok)
    }

    /// A single article from the read batcher.
    func articleResponse(_ view: ArticleView, json: borrowing ByteBuffer, status: Status) -> Response {
        var out = JSONWriter(capacity: view.splice.length + 16)
        out.raw("{\"article\":")
        out.article(view, from: json)
        out.raw("}")
        return out.response(status)
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

    // GET /api/articles and /api/articles/feed, unbatched
    func listArticles(_ kind: PageKind, limit: Int64, offset: Int64, viewer: Int64) async throws -> Response {
        switch kind {
        case .all:
            try await writeList(ArticlePage<PageAllSQL>(viewer: viewer, limit: limit, offset: offset, filter: nil))
        case .tag(let tag):
            try await writeList(ArticlePage<PageByTagSQL>(viewer: viewer, limit: limit, offset: offset, filter: tag))
        case .author(let author):
            try await writeList(ArticlePage<PageByAuthorSQL>(viewer: viewer, limit: limit, offset: offset, filter: author))
        case .favorited(let name):
            try await writeList(ArticlePage<PageByFavoriteSQL>(viewer: viewer, limit: limit, offset: offset, filter: name))
        case .feed(let viewer):
            try await writeList(ArticlePage<PageFeedSQL>(viewer: viewer, limit: limit, offset: offset, filter: nil))
        }
    }

    // GET /api/articles/:slug, unbatched
    func getArticle(viewer: Int64, slug: String) async throws -> Response {
        try await writeFullArticle(status: .ok, ArticleByKey<ArticleBySlugSQL>(viewer: viewer, key: slug))
    }

    // POST /api/articles
    func createArticle(viewer: Int64, _ body: ByteBuffer) async throws -> WriteOutcome {
        let m: [String: Any]
        do { m = try readWrapper(body, "article") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let title: String
        let description: String
        let text: String
        let tagList: [String]
        do {
            title = try reqString(m, "title")
            description = try reqString(m, "description")
            text = try reqString(m, "body")
            tagList = try optTagList(m)
        } catch {
            throw ApiError(.unprocessableContent, "title, description and body are required")
        }
        return try await writes.run(.createArticle(viewer: viewer, title: title, description: description, body: text, tags: tagList))
    }

    // PUT /api/articles/:slug
    func updateArticle(viewer: Int64, slug: String, _ body: ByteBuffer) async throws -> WriteOutcome {
        let m: [String: Any]
        do { m = try readWrapper(body, "article") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let title: String?
        let description: String?
        let text: String?
        do {
            title = try optString(m, "title", nonEmpty: true)
            description = try optString(m, "description", nonEmpty: true)
            text = try optString(m, "body", nonEmpty: true)
        } catch {
            throw ApiError(.unprocessableContent, "title, description and body must be non-empty strings")
        }
        return try await writes.run(.updateArticle(viewer: viewer, slug: slug, title: title, description: description, body: text))
    }

    // DELETE /api/articles/:slug
    func deleteArticle(viewer: Int64, slug: String) async throws -> WriteOutcome {
        try await writes.run(.deleteArticle(viewer: viewer, slug: slug))
    }

    // POST and DELETE /api/articles/:slug/favorite
    func favorite(viewer: Int64, slug: String, on: Bool) async throws -> WriteOutcome {
        try await writes.run(.favorite(viewer: viewer, slug: slug, on: on))
    }
}
