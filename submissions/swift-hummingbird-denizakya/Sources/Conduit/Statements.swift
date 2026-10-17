// Prepared statements for the hot article reads (Articles.swift). The SQL is the same text as before; postgres-nio
// prepares each statement once per pooled connection, so Postgres stops parsing and planning it on every request.
// Rule 5 is untouched: every row is still read from Postgres for each request.
import PostgresNIO

protocol ArticleSQL {
    static var sql: String { get }
}

enum ListAllSQL: ArticleSQL { static var sql: String { listAll } }
enum CountAllSQL: ArticleSQL { static var sql: String { countAll } }
enum ListByTagSQL: ArticleSQL { static var sql: String { listByTag } }
enum CountByTagSQL: ArticleSQL { static var sql: String { countByTag } }
enum ListByAuthorSQL: ArticleSQL { static var sql: String { listByAuthor } }
enum CountByAuthorSQL: ArticleSQL { static var sql: String { countByAuthor } }
enum ListByFavoriteSQL: ArticleSQL { static var sql: String { listByFavorite } }
enum CountByFavoriteSQL: ArticleSQL { static var sql: String { countByFavorite } }
enum ListFeedSQL: ArticleSQL { static var sql: String { listFeed } }
enum CountFeedSQL: ArticleSQL { static var sql: String { countFeed } }
enum ArticleBySlugSQL: ArticleSQL { static var sql: String { articleBySlug } }
enum ArticleByIDSQL: ArticleSQL { static var sql: String { articleByID } }

/// A page of article list rows. `filter` is the $4 bind of the tag/author/favorited lists; nil for the global list and the feed.
struct ArticleList<Q: ArticleSQL>: PostgresPreparedStatement {
    typealias Row = ArticleRow
    static var sql: String { Q.sql }

    let viewer: Int64
    let limit: Int64
    let offset: Int64
    let filter: String?

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 4)
        try binds.append(viewer)
        try binds.append(limit)
        try binds.append(offset)
        if let filter { try binds.append(filter) }
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> ArticleRow {
        try row.listArticle()
    }
}

/// The count that goes with a list. `bind` is nil for the unfiltered count.
struct ArticleCount<Q: ArticleSQL>: PostgresPreparedStatement {
    typealias Row = Int64
    static var sql: String { Q.sql }

    let bind: (any PostgresEncodable)?

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 1)
        if let bind { try binds.append(bind) }
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> Int64 {
        try row.cell(0).int()
    }
}

/// One article by slug or id, as seen by `viewer`.
struct ArticleByKey<Q: ArticleSQL>: PostgresPreparedStatement {
    typealias Row = ArticleRow
    static var sql: String { Q.sql }

    let viewer: Int64
    let key: any PostgresEncodable

    func makeBindings() throws -> PostgresBindings {
        var binds = PostgresBindings(capacity: 2)
        try binds.append(viewer)
        try binds.append(key)
        return binds
    }

    func decodeRow(_ row: PostgresRow) throws -> ArticleRow {
        try row.fullArticle()
    }
}

extension App {
    /// Run a prepared statement and collect every row.
    func fetchAll<S: PostgresPreparedStatement>(_ statement: S) async throws -> [S.Row] {
        let rows = try await db.execute(statement, logger: App.queryLogger)
        var out = [S.Row]()
        for try await row in rows { out.append(row) }
        return out
    }
}
