import Fluent
import Foundation

final class Comment: Model, @unchecked Sendable {
    static let schema = "comments"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Parent(key: "article_id")
    var article: Article

    @Parent(key: "author_id")
    var author: User

    @Field(key: "body")
    var body: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(articleID: Int, authorID: Int, body: String) {
        self.$article.id = articleID
        self.$author.id = authorID
        self.body = body
    }
}
