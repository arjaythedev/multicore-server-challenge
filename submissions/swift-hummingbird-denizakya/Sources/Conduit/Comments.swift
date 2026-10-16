// Comments (SPEC.md "Comments").
import Foundation
import Hummingbird
import HummingbirdCore
import PostgresNIO

extension App {
    // GET /api/articles/:slug/comments
    func listComments(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.optional(request, secret: secret)
        let slug = ctx.parameters.get("slug") ?? ""
        let id = try await articleID(slug)
        let rows = try await queryAll(
            """
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
              FROM comments c JOIN users u ON u.id = c.author_id
             WHERE c.article_id = $2
             ORDER BY c.created_at DESC, c.id DESC
             LIMIT 100
            """,
            [auth.viewer, id]
        )
        var out = "{\"comments\":["
        var first = true
        for row in rows {
            if !first { out += "," }
            first = false
            let cid = try row.cell(0).int()
            let body = try row.cell(1).text()
            let created = try row.cell(2).date()
            let updated = try row.cell(3).date()
            let username = try row.cell(4).text()
            let bio = try row.cell(5).textOrNull()
            let image = try row.cell(6).textOrNull()
            let following = try row.cell(7).bool()
            out += "{\"id\":\(cid),\"createdAt\":\"\(rfc3339ms(created))\",\"updatedAt\":\"\(rfc3339ms(updated))\""
            out += ",\"body\":\(jsonEscape(body))"
            out += ",\"author\":{\"username\":\(jsonEscape(username))"
            if let bio { out += ",\"bio\":\(jsonEscape(bio))" } else { out += ",\"bio\":null" }
            if let image { out += ",\"image\":\(jsonEscape(image))" } else { out += ",\"image\":null" }
            out += ",\"following\":\(following ? "true" : "false")}}"
        }
        out += "]}"
        return jsonResponse(.ok, out)
    }

    // POST /api/articles/:slug/comments
    func createComment(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
        let slug = ctx.parameters.get("slug") ?? ""
        let m: [String: Any]
        do { m = try await readWrapper(request, "comment") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let body: String
        do { body = try reqString(m, "body") } catch { throw ApiError(.unprocessableContent, "body is required") }
        let id = try await articleID(slug)
        guard let row = try await queryRow(
            """
            WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
                       RETURNING id, body, created_at, updated_at, author_id)
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
              FROM c JOIN users u ON u.id = c.author_id
            """,
            [id, auth.viewer, body]
        ) else {
            throw ApiError(.internalServerError, "insert returned no row")
        }
        var out = "{\"comment\":{\"id\":\(try row.cell(0).int())"
        out += ",\"createdAt\":\"\(rfc3339ms(try row.cell(2).date()))\",\"updatedAt\":\"\(rfc3339ms(try row.cell(3).date()))\""
        out += ",\"body\":\(jsonEscape(try row.cell(1).text()))"
        out += ",\"author\":{\"username\":\(jsonEscape(try row.cell(4).text()))"
        if let bio = try row.cell(5).textOrNull() { out += ",\"bio\":\(jsonEscape(bio))" } else { out += ",\"bio\":null" }
        if let image = try row.cell(6).textOrNull() { out += ",\"image\":\(jsonEscape(image))" } else { out += ",\"image\":null" }
        out += ",\"following\":false}}}"
        return jsonResponse(.created, out)
    }

    // DELETE /api/articles/:slug/comments/:id
    func deleteComment(_ request: Request, _ ctx: BasicRequestContext) async throws -> Response {
        let auth = try Auth.require(request, secret: secret)
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
        guard try row.cell(0).int() == auth.viewer else { throw ApiError(.forbidden, "not the author") }
        try await exec("DELETE FROM comments WHERE id = $1", [cid])
        return jsonResponse(.noContent, "")
    }
}
