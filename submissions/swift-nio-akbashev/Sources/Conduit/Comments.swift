// Comments (SPEC.md "Comments").
import Logging
import NIOCore
import PostgresNIO

struct CommentRow {
    var id: Int64
    var body: PGText
    var createdAt: PGTimestamp
    var updatedAt: PGTimestamp
    var author: ProfileRow
}

extension JSONWriter {
    mutating func comment(_ c: borrowing CommentRow) {
        commentUpToFollowing(c)
        bool(c.author.following)
        raw("}}")
    }

    /// A comment up to its author's `following` value, which depends on the viewer.
    private mutating func commentUpToFollowing(_ c: borrowing CommentRow) {
        raw("{\"id\":"); int(c.id)
        raw(",\"createdAt\":"); timestamp(c.createdAt)
        raw(",\"updatedAt\":"); timestamp(c.updatedAt)
        raw(",\"body\":"); string(c.body)
        raw(",\"author\":"); authorUpToFollowing(c.author)
    }

    /// The comment once for a whole batch, with `following` left open.
    mutating func commentSplice(_ c: borrowing CommentRow) -> CommentSplice {
        let start = position
        commentUpToFollowing(c)
        return CommentSplice(start: Int32(start), following: Int32(position))
    }

    /// One viewer's copy of a comment written by `commentSplice`.
    mutating func comment(_ view: CommentView, from json: borrowing ByteBuffer) {
        splice(json, view.splice.start..<view.splice.following)
        bool(view.following)
        raw("}}")
    }
}

/// Where a comment's JSON sits in its batch's buffer; the author's `following` value is due at `following`.
struct CommentSplice: Sendable, BitwiseCopyable {
    let start: Int32
    let following: Int32
}

/// A comment of a batch as one viewer sees it.
struct CommentView: Sendable, BitwiseCopyable {
    let splice: CommentSplice
    let following: Bool
}

extension App {
    /// A thread from the read batcher: its comments copied from the batch's JSON.
    func commentsResponse(_ comments: borrowing [CommentView], json: borrowing ByteBuffer) -> Response {
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

    // GET /api/articles/:slug/comments, unbatched
    func listComments(viewer: Int64, slug: String) async throws -> Response {
        var out = JSONWriter(capacity: 2048)
        out.raw("{\"comments\":[")
        var articleFound = false
        var first = true
        for try await row in try await db.execute(CommentsBySlug(viewer: viewer, slug: slug), logger: App.queryLogger) {
            articleFound = true
            guard let comment = row else { continue }
            if !first { out.raw(",") }
            first = false
            out.comment(comment)
        }
        guard articleFound else { throw ApiError(.notFound, "article not found") }
        out.raw("]}")
        return out.response(.ok)
    }

    // POST /api/articles/:slug/comments
    func createComment(viewer: Int64, slug: String, _ body: ByteBuffer) async throws -> WriteOutcome {
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

/// A new comment's response, from its row: id, body, created_at, updated_at, username, bio, image.
func newCommentResponse(_ cells: inout RowCursor) throws -> Response {
    let id = try cells.int()
    let body = try cells.text()
    let createdAt = try cells.timestamp()
    let updatedAt = try cells.timestamp()
    let username = try cells.text()
    let bio = try cells.textOrNull()
    let image = try cells.textOrNull()
    var out = JSONWriter(capacity: 512 + body.bytes.readableBytes)
    out.raw("{\"comment\":")
    out.comment(CommentRow(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt,
                           author: ProfileRow(username: username, bio: bio, image: image, following: false)))
    out.raw("}")
    return out.response(.created)
}
