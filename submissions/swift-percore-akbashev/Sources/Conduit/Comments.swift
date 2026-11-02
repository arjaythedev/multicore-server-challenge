// Comments (SPEC.md "Comments"): the write handlers and the responses.
import Foundation

extension App {
    /// A thread from the read batcher: its comments copied from the batch's JSON.
    func commentsResponse(_ comments: borrowing [CommentView], json: JSONBytes) -> Response {
        var size = 32
        for i in comments.indices { size += Int(comments[i].splice.following - comments[i].splice.start) + 8 }
        var out = JSONWriter(capacity: size)
        out.raw("{\"comments\":[")
        for i in comments.indices {
            if i > 0 { out.raw(",") }
            out.comment(comments[i], from: json)
        }
        out.raw("]}")
        return out.response(.ok)
    }

    // POST /api/articles/:slug/comments
    func createComment(viewer: Int64, slug: String, _ body: Data) async throws -> WriteOutcome {
        let m: [String: Any]
        do { m = try readWrapper(body, "comment") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let text: String
        do { text = try reqString(m, "body") } catch { throw ApiError(.unprocessableContent, "body is required") }
        return try await writes.run(.createComment(viewer: viewer, slug: slug, body: text))
    }

    // DELETE /api/articles/:slug/comments/:id
    func deleteComment(viewer: Int64, slug: String, id: Int64) async throws -> WriteOutcome {
        try await writes.run(.deleteComment(viewer: viewer, slug: slug, id: id))
    }
}

/// A new comment's response.
func newCommentResponse(_ c: borrowing CommentRow, _ rows: borrowing Bytes) -> Response {
    var out = JSONWriter(capacity: 512 + Int(c.body.count))
    out.raw("{\"comment\":")
    out.comment(c, rows)
    out.raw("}")
    return out.response(.created)
}
