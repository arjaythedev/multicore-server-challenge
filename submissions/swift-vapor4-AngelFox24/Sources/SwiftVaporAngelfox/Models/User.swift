import Fluent
import Foundation

/// A RealWorld user. IDs are `bigint` identity columns because the challenge
/// schema stores them that way (the seed data is shared with every submission).
final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Field(key: "username")
    var username: String

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @OptionalField(key: "bio")
    var bio: String?

    @OptionalField(key: "image")
    var image: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: Int? = nil, username: String, email: String, passwordHash: String) {
        self.id = id
        self.username = username
        self.email = email
        self.passwordHash = passwordHash
    }
}
