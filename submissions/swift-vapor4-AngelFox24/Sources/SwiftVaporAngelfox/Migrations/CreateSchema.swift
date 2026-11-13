import Fluent

struct CreateUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("id", .int64, .identifier(auto: true))
            .field("username", .string, .required)
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("bio", .string)
            .field("image", .string)
            .field("created_at", .datetime, .required)
            .unique(on: "username")
            .unique(on: "email")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema).delete()
    }
}

struct CreateTag: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Tag.schema)
            .field("id", .int32, .identifier(auto: true))
            .field("name", .string, .required)
            .unique(on: "name")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Tag.schema).delete()
    }
}

struct CreateArticle: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Article.schema)
            .field("id", .int64, .identifier(auto: true))
            .field("slug", .string, .required)
            .field("author_id", .int64, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("description", .string, .required)
            .field("body", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "slug")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Article.schema).delete()
    }
}

struct CreateFollow: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Follow.schema)
            .field("follower_id", .int64, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("followee_id", .int64, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "follower_id", "followee_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Follow.schema).delete()
    }
}

struct CreateArticleTag: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ArticleTag.schema)
            .field("article_id", .int64, .required, .references(Article.schema, "id", onDelete: .cascade))
            .field("tag_id", .int32, .required, .references(Tag.schema, "id", onDelete: .cascade))
            .unique(on: "article_id", "tag_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ArticleTag.schema).delete()
    }
}

struct CreateFavorite: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Favorite.schema)
            .field("user_id", .int64, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("article_id", .int64, .required, .references(Article.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .unique(on: "user_id", "article_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Favorite.schema).delete()
    }
}

struct CreateComment: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Comment.schema)
            .field("id", .int64, .identifier(auto: true))
            .field("article_id", .int64, .required, .references(Article.schema, "id", onDelete: .cascade))
            .field("author_id", .int64, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("body", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Comment.schema).delete()
    }
}
