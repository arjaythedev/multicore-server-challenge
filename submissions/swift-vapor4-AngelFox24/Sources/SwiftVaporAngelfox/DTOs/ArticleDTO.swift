import Fluent
import Vapor

struct ArticleDTO: Content, Sendable {
    let slug: String
    let title: String
    let description: String
    let body: String?
    let tagList: [String]
    let createdAt: String
    let updatedAt: String
    let favorited: Bool
    let favoritesCount: Int
    let author: ProfileDTO

    enum CodingKeys: String, CodingKey {
        case slug, title, description, body, tagList, createdAt, updatedAt
        case favorited, favoritesCount, author
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(slug, forKey: .slug)
        try container.encode(title, forKey: .title)
        try container.encode(description, forKey: .description)
        if let body {
            try container.encode(body, forKey: .body)
        }
        try container.encode(tagList, forKey: .tagList)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(favorited, forKey: .favorited)
        try container.encode(favoritesCount, forKey: .favoritesCount)
        try container.encode(author, forKey: .author)
    }
}

struct ArticleResponse: Content, Sendable {
    let article: ArticleDTO
}

struct ArticleListResponse: Content, Sendable {
    let articles: [ArticleDTO]
    let articlesCount: Int
}

extension Article {
    func toDTO(
        tags: [String],
        favorited: Bool,
        favoritesCount: Int,
        following: Bool,
        includeBody: Bool
    ) throws -> ArticleDTO {
        ArticleDTO(
            slug: self.slug,
            title: self.title,
            description: self.description,
            body: includeBody ? self.body : nil,
            tagList: tags,
            createdAt: rfc3339ms(self.createdAt ?? Date()),
            updatedAt: rfc3339ms(self.updatedAt ?? self.createdAt ?? Date()),
            favorited: favorited,
            favoritesCount: favoritesCount,
            author: self.author.toProfile(following: following)
        )
    }
}
