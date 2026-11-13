import Fluent
import Foundation

final class Article: Model, @unchecked Sendable {
    static let schema = "articles"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Field(key: "slug")
    var slug: String

    @Parent(key: "author_id")
    var author: User

    @Field(key: "title")
    var title: String

    @Field(key: "description")
    var description: String

    @Field(key: "body")
    var body: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(authorID: Int, slug: String, title: String, description: String, body: String) {
        self.$author.id = authorID
        self.slug = slug
        self.title = title
        self.description = description
        self.body = body
    }
}
