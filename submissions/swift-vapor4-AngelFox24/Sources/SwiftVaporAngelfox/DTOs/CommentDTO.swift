import Fluent
import Vapor

struct CommentDTO: Content, Sendable {
    let id: Int
    let createdAt: String
    let updatedAt: String
    let body: String
    let author: ProfileDTO
}

struct CommentResponse: Content, Sendable {
    let comment: CommentDTO
}

struct CommentListResponse: Content, Sendable {
    let comments: [CommentDTO]
}

extension Comment {
    func toDTO(following: Bool) throws -> CommentDTO {
        CommentDTO(
            id: try self.requireID(),
            createdAt: rfc3339ms(self.createdAt ?? Date()),
            updatedAt: rfc3339ms(self.updatedAt ?? self.createdAt ?? Date()),
            body: self.body,
            author: self.author.toProfile(following: following)
        )
    }
}
