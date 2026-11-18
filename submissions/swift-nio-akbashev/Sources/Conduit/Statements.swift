// Prepared statements for the hot reads. postgres-nio prepares each statement once per pooled connection, so Postgres
// stops parsing and planning it on every request. Rule 5 is untouched: every row is still read from Postgres for each
// request. Rows are decoded by RowCursor, straight from the cells' bytes.
import Logging
import PostgresNIO

/// One article query. `name` is the prepared statement's name on each connection: postgres-nio reads it on every
/// execution, and its default, String(reflecting:), builds the generic type's name by reflection each time.
protocol ArticleSQL {
    static var name: String { get }
    static var sql: String { get }
}

enum PageAllSQL: ArticleSQL { static var name: String { "page_all" }; static var sql: String { pageAll } }
enum PageByTagSQL: ArticleSQL { static var name: String { "page_by_tag" }; static var sql: String { pageByTag } }
enum PageByAuthorSQL: ArticleSQL { static var name: String { "page_by_author" }; static var sql: String { pageByAuthor } }
enum PageByFavoriteSQL: ArticleSQL { static var name: String { "page_by_favorite" }; static var sql: String { pageByFavorite } }
enum PageFeedSQL: ArticleSQL { static var name: String { "page_feed" }; static var sql: String { pageFeed } }
enum ArticleBySlugSQL: ArticleSQL { static var name: String { "article_by_slug" }; static var sql: String { articleBySlug } }
enum ArticleByIDSQL: ArticleSQL { static var name: String { "article_by_id" }; static var sql: String { articleByID } }

/// A page of the article list together with the list's total (Articles.swift `articlePage`). `filter` is the $4 bind
/// of the tag/author/favorited lists; nil for the global list and the feed.
struct ArticlePage<Q: ArticleSQL>: PostgresPreparedStatement {
    typealias Row = ArticlePageRow
    static var name: String { Q.name }
    static var sql: String { Q.sql }

    let viewer: Int64
    let limit: Int64
    let offset: Int64
    let filter: String?

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 4)
        binds.append(viewer)
        binds.append(limit)
        binds.append(offset)
        if let filter { binds.append(filter) }
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> ArticlePageRow {
        try row.articlePageRow()
    }
}

/// One article by slug or id, as seen by `viewer`.
struct ArticleByKey<Q: ArticleSQL>: PostgresPreparedStatement {
    typealias Row = ArticleRow
    static var name: String { Q.name }
    static var sql: String { Q.sql }

    let viewer: Int64
    let key: any PostgresEncodable & Sendable

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 2)
        binds.append(viewer)
        try binds.append(key)
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> ArticleRow {
        try row.fullArticle()
    }
}

/// GET /api/tags.
struct AllTags: PostgresPreparedStatement {
    typealias Row = PGText
    static let name = "tags"
    static let sql = "SELECT name FROM tags ORDER BY name"

    func makeBindings() throws -> PostgresBindings {
        PostgresBindings()
    }

    func decodeRow(_ row: PostgresRow) throws -> PGText {
        var cells = RowCursor(row)
        return try cells.text()
    }
}

/// GET /api/user: the viewer's own row.
struct UserByID: PostgresPreparedStatement {
    typealias Row = UserRow
    static let name = "user_by_id"
    static let sql = "SELECT id, username, email, bio, image FROM users WHERE id = $1"

    let id: Int64

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 1)
        binds.append(id)
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> UserRow {
        try row.user().user
    }
}

/// GET /api/profiles/:username, as seen by `viewer`.
struct ProfileByName: PostgresPreparedStatement {
    typealias Row = ProfileRow
    static let name = "profile_by_name"
    static let sql = """
        SELECT u.id, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
          FROM users u WHERE u.username = $2
        """

    let viewer: Int64
    let username: String

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 2)
        binds.append(viewer)
        binds.append(username)
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> ProfileRow {
        var cells = RowCursor(row)
        try cells.skip() // id
        let username = try cells.text()
        let bio = try cells.textOrNull()
        let image = try cells.textOrNull()
        return ProfileRow(username: username, bio: bio, image: image, following: try cells.bool())
    }
}

/// GET /api/articles/:slug/comments, article lookup included, in one round trip. No row: no such article (404).
/// A single row with a NULL id: the article has no comments. Otherwise the newest 100, as in the reference SQL.
struct CommentsBySlug: PostgresPreparedStatement {
    typealias Row = CommentRow?
    static let name = "comments_by_slug"
    static let sql = """
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
          FROM (SELECT a.id FROM articles a WHERE a.slug = $2) a
          LEFT JOIN LATERAL (SELECT cm.id, cm.body, cm.created_at, cm.updated_at, cm.author_id
                               FROM comments cm WHERE cm.article_id = a.id
                              ORDER BY cm.created_at DESC, cm.id DESC
                              LIMIT 100) c ON true
          LEFT JOIN users u ON u.id = c.author_id
         ORDER BY c.created_at DESC, c.id DESC
        """

    let viewer: Int64
    let slug: String

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 2)
        binds.append(viewer)
        binds.append(slug)
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> CommentRow? {
        var cells = RowCursor(row)
        guard let id = try cells.intOrNull() else { return nil }
        let body = try cells.text()
        let createdAt = try cells.timestamp()
        let updatedAt = try cells.timestamp()
        let username = try cells.text()
        let bio = try cells.textOrNull()
        let image = try cells.textOrNull()
        return CommentRow(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt,
                          author: ProfileRow(username: username, bio: bio, image: image, following: try cells.bool()))
    }
}

extension App {
    /// Run a prepared statement and return its first row (or nil).
    func fetchFirst<S: PostgresPreparedStatement>(_ statement: S) async throws -> S.Row? {
        for try await row in try await db.execute(statement, logger: App.queryLogger) {
            return row
        }
        return nil
    }
}
