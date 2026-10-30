// Comments (SPEC.md "Comments").
import HTTPTypes
import Hummingbird
import Logging
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
        raw("{\"id\":"); int(c.id)
        raw(",\"createdAt\":"); timestamp(c.createdAt)
        raw(",\"updatedAt\":"); timestamp(c.updatedAt)
        raw(",\"body\":"); string(c.body)
        raw(",\"author\":"); author(c.author)
        raw("}")
    }
}

extension App {
    // GET /api/articles/:slug/comments
    func listComments(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, signer)
        let slug = ctx.parameters.get("slug") ?? ""
        var out = JSONWriter(capacity: 2048)
        out.raw("{\"comments\":[")
        if let reads {
            guard let comments = try await reads.comments(slug: slug, viewer: auth.viewer) else {
                throw ApiError(.notFound, "article not found")
            }
            for i in comments.indices {
                if i > 0 { out.raw(",") }
                out.comment(comments[i])
            }
            out.raw("]}")
            return out.response(.ok)
        }
        var articleFound = false
        var first = true
        for try await row in try await db.execute(CommentsBySlug(viewer: auth.viewer, slug: slug), logger: App.queryLogger) {
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
    func createComment(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let slug = ctx.parameters.get("slug") ?? ""
        let m: [String: Any]
        do { m = try await readWrapper(request, "comment") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let body: String
        do { body = try reqString(m, "body") } catch { throw ApiError(.unprocessableContent, "body is required") }
        // One round trip for the article lookup and the insert; no row means no such article (404).
        guard let row = try await queryRow(
            """
            WITH a AS (SELECT id FROM articles WHERE slug = $1),
                 c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a
                       RETURNING id, body, created_at, updated_at, author_id)
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
              FROM c JOIN users u ON u.id = c.author_id
            """,
            [slug, auth.viewer, body]
        ) else {
            throw ApiError(.notFound, "article not found")
        }
        var cells = RowCursor(row)
        let id = try cells.int()
        let text = try cells.text()
        let createdAt = try cells.timestamp()
        let updatedAt = try cells.timestamp()
        let username = try cells.text()
        let bio = try cells.textOrNull()
        let image = try cells.textOrNull()
        var out = JSONWriter(capacity: 512 + text.bytes.readableBytes)
        out.raw("{\"comment\":")
        out.comment(CommentRow(id: id, body: text, createdAt: createdAt, updatedAt: updatedAt,
                               author: ProfileRow(username: username, bio: bio, image: image, following: false)))
        out.raw("}")
        return out.response(.created)
    }

    // DELETE /api/articles/:slug/comments/:id
    func deleteComment(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, signer)
        let slug = ctx.parameters.get("slug") ?? ""
        guard let cid = parseUint(ctx.parameters.get("id") ?? "") else {
            throw ApiError(.notFound, "comment not found")
        }
        guard let row = try await queryRow(
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
            [cid, slug]
        ) else {
            throw ApiError(.notFound, "comment not found")
        }
        var cells = RowCursor(row)
        guard try cells.int() == auth.viewer else { throw ApiError(.forbidden, "not the author") }
        try await exec("DELETE FROM comments WHERE id = $1", [cid])
        return emptyResponse(.noContent)
    }
}
