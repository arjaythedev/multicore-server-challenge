import Fluent
import Foundation

/// The `follows` table has a composite primary key, but Fluent models need one
/// identifier. We use `follower_id` as the model id and keep `followee_id` as
/// the parent relationship. Reads only; writes go through query filters so a
/// delete can never touch more than the intended pair.
final class Follow: Model, @unchecked Sendable {
    static let schema = "follows"

    @ID(custom: "follower_id", generatedBy: .user)
    var id: Int?

    @Parent(key: "followee_id")
    var followee: User

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(followerID: Int, followeeID: Int) {
        self.id = followerID
        self.$followee.id = followeeID
    }
}
