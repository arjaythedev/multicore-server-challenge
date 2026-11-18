// Articles, feed, favorites (SPEC.md "Articles", "Favorites"): the write handlers, and the responses read batches
// answer with. The reads themselves are in Reads.swift, the writes' statements in Writes.swift.
import Foundation

extension App {
    /// A page from the read batcher: its articles copied from the batch's JSON.
    func pageResponse(total: Int64, articles: borrowing [ArticleView], json: JSONBytes) -> Response {
        var size = 64
        for i in articles.indices { size += articles[i].splice.length }
        var out = JSONWriter(capacity: size)
        out.raw("{\"articles\":[")
        for i in articles.indices {
            if i > 0 { out.raw(",") }
            out.article(articles[i], from: json)
        }
        out.raw("],\"articlesCount\":")
        out.int(total)
        out.raw("}")
        return out.response(.ok)
    }

    func emptyPage() -> Response {
        var out = JSONWriter(capacity: 40)
        out.raw("{\"articles\":[],\"articlesCount\":0}")
        return out.response(.ok)
    }

    /// A single article from the read batcher.
    func articleResponse(_ view: ArticleView, json: JSONBytes, status: Status) -> Response {
        var out = JSONWriter(capacity: view.splice.length + 16)
        out.raw("{\"article\":")
        out.article(view, from: json)
        out.raw("}")
        return out.response(status)
    }

    // POST /api/articles
    func createArticle(viewer: Int64, _ body: Data) async throws -> WriteOutcome {
        let m: [String: Any]
        do { m = try readWrapper(body, "article") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let title: String
        let description: String
        let text: String
        let tagList: [String]
        do {
            title = try reqString(m, "title")
            description = try reqString(m, "description")
            text = try reqString(m, "body")
            tagList = try optTagList(m)
        } catch {
            throw ApiError(.unprocessableContent, "title, description and body are required")
        }
        return try await writes.run(.createArticle(viewer: viewer, title: title, description: description, body: text, tags: tagList))
    }

    // PUT /api/articles/:slug
    func updateArticle(viewer: Int64, slug: String, _ body: Data) async throws -> WriteOutcome {
        let m: [String: Any]
        do { m = try readWrapper(body, "article") } catch { throw ApiError(.unprocessableContent, "invalid body") }
        let title: String?
        let description: String?
        let text: String?
        do {
            title = try optString(m, "title", nonEmpty: true)
            description = try optString(m, "description", nonEmpty: true)
            text = try optString(m, "body", nonEmpty: true)
        } catch {
            throw ApiError(.unprocessableContent, "title, description and body must be non-empty strings")
        }
        return try await writes.run(.updateArticle(viewer: viewer, slug: slug, title: title, description: description, body: text))
    }

    // DELETE /api/articles/:slug
    func deleteArticle(viewer: Int64, slug: String) async throws -> WriteOutcome {
        try await writes.run(.deleteArticle(viewer: viewer, slug: slug))
    }

    // POST and DELETE /api/articles/:slug/favorite
    func favorite(viewer: Int64, slug: String, on: Bool) async throws -> WriteOutcome {
        try await writes.run(.favorite(viewer: viewer, slug: slug, on: on))
    }
}
