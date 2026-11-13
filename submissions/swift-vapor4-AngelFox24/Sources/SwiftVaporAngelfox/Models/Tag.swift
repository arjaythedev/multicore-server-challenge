import Fluent

final class Tag: Model, @unchecked Sendable {
    static let schema = "tags"

    @ID(custom: "id", generatedBy: .database)
    var id: Int?

    @Field(key: "name")
    var name: String

    init() {}

    init(id: Int? = nil, name: String) {
        self.id = id
        self.name = name
    }
}
