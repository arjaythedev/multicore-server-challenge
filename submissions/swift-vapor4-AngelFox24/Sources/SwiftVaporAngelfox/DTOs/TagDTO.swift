import Vapor

struct TagsResponse: Content, Sendable {
    let tags: [String]
}
