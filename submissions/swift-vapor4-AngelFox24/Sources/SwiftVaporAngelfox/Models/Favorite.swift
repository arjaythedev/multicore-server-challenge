import Fluent
import Foundation

/// Same composite-key situation as `Follow`: `user_id` is the model id and
/// `article_id` is the parent. Only used for reads and existence checks.
final class Favorite: Model, @unchecked Sendable {
    static let schema = "favorites"

    @ID(custom: "user_id", generatedBy: .user)
    var id: Int?

    @Parent(key: "article_id")
    var article: Article

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(userID: Int, articleID: Int) {
        self.id = userID
        self.$article.id = articleID
    }
}
