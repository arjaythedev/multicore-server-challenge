// The routes: Hummingbird's router in front of the handlers. Token checks, path parameters and query parsing happen
// before a handler runs; a hot read waits for its batch (Reads.swift), and a write for its group's commit (Writes.swift).
import HTTPTypes
import Hummingbird
import NIOCore

extension App {
    /// The routes. Built in a nonisolated method so no handler closure can pick up the main actor from `main()`.
    func router() -> Router<BasicRequestContext> {
        let router = Router(context: BasicRequestContext.self)

        router.post("api/users") { request, _ in
            await write { try await register(body(request)) }
        }
        router.post("api/users/login") { request, _ in
            await handle { try await login(body(request)) }
        }
        router.get("api/user") { request, _ in
            await handle {
                let (viewer, token) = try requireWithToken(request)
                if let reads { return render(try await reads.read(.user(id: viewer), viewer: viewer), token: token) }
                return try await currentUser(viewer: viewer, token: token)
            }
        }
        router.put("api/user") { request, _ in
            await write {
                let (viewer, token) = try requireWithToken(request)
                return try await updateUser(viewer: viewer, token: token, body(request))
            }
        }

        router.get("api/profiles/:username") { request, ctx in
            await handle {
                let username = try parameter(ctx, "username")
                let viewer = try optional(request)
                if let reads { return render(try await reads.read(.profile(username: username), viewer: viewer)) }
                return try await getProfile(viewer: viewer, username: username)
            }
        }
        for (method, on) in [(HTTPRequest.Method.post, true), (.delete, false)] {
            router.on("api/profiles/:username/follow", method: method) { request, ctx in
                await write {
                    let username = try parameter(ctx, "username")
                    return try await follow(viewer: require(request), username: username, on: on)
                }
            }
        }

        router.get("api/articles") { request, _ in
            await handle { try await list(request) }
        }
        router.get("api/articles/feed") { request, _ in
            await handle {
                let viewer = try require(request)
                let (limit, offset) = try limitOffset(query(request))
                if let reads { return render(try await reads.read(.page(.feed(viewer), limit: limit, offset: offset), viewer: viewer)) }
                return try await listArticles(.feed(viewer), limit: limit, offset: offset, viewer: viewer)
            }
        }
        router.post("api/articles") { request, _ in
            await write { try await createArticle(viewer: require(request), body(request)) }
        }
        router.get("api/articles/:slug") { request, ctx in
            await handle {
                let slug = try parameter(ctx, "slug")
                let viewer = try optional(request)
                if let reads { return render(try await reads.read(.article(slug: slug), viewer: viewer)) }
                return try await getArticle(viewer: viewer, slug: slug)
            }
        }
        router.put("api/articles/:slug") { request, ctx in
            await write {
                let slug = try parameter(ctx, "slug")
                return try await updateArticle(viewer: require(request), slug: slug, body(request))
            }
        }
        router.delete("api/articles/:slug") { request, ctx in
            await write {
                let slug = try parameter(ctx, "slug")
                return try await deleteArticle(viewer: require(request), slug: slug)
            }
        }
        for (method, on) in [(HTTPRequest.Method.post, true), (.delete, false)] {
            router.on("api/articles/:slug/favorite", method: method) { request, ctx in
                await write {
                    let slug = try parameter(ctx, "slug")
                    return try await favorite(viewer: require(request), slug: slug, on: on)
                }
            }
        }
        router.get("api/articles/:slug/comments") { request, ctx in
            await handle {
                let slug = try parameter(ctx, "slug")
                let viewer = try optional(request)
                if let reads { return render(try await reads.read(.comments(slug: slug), viewer: viewer)) }
                return try await listComments(viewer: viewer, slug: slug)
            }
        }
        router.post("api/articles/:slug/comments") { request, ctx in
            await write {
                let slug = try parameter(ctx, "slug")
                return try await createComment(viewer: require(request), slug: slug, body(request))
            }
        }
        router.delete("api/articles/:slug/comments/:id") { request, ctx in
            await write {
                let slug = try parameter(ctx, "slug")
                let viewer = try require(request)
                // SPEC.md: a non-integer :id is a 404.
                guard let id = parseUint(ctx.parameters.get("id") ?? "") else { throw ApiError(.notFound, "comment not found") }
                return try await deleteComment(viewer: viewer, slug: slug, id: id)
            }
        }

        router.get("api/tags") { _, _ in
            await handle {
                if let reads { return render(try await reads.read(.tags, viewer: 0)) }
                return try await tags()
            }
        }

        // Anything else (unknown path, or a known path with another method) is a JSON 404.
        for method: HTTPRequest.Method in [.get, .post, .put, .delete, .patch, .head, .options, .trace, .connect] {
            router.on("**", method: method) { _, _ in errorResponse(.notFound, "not found") }
        }
        return router
    }

    // GET /api/articles: the first non-empty filter of tag, author and favorited applies; later ones aren't looked up.
    private func list(_ request: Request) async throws -> Response {
        let viewer = try optional(request)
        let query = query(request)
        let (limit, offset) = try limitOffset(query)
        let kind: PageKind =
            if let tag = query.get("tag"), !tag.isEmpty { .tag(tag) }
            else if let author = query.get("author"), !author.isEmpty { .author(author) }
            else if let favorited = query.get("favorited"), !favorited.isEmpty { .favorited(favorited) }
            else { .all }
        let filter: String? = switch kind {
        case .tag(let s), .author(let s), .favorited(let s): s
        case .all, .feed: nil
        }
        if let filter, filter.utf8.contains(0) {
            // Postgres text can't hold NUL, so no row matches it; sent as a parameter it would be an error instead.
            return emptyPage()
        }
        if let reads { return render(try await reads.read(.page(kind, limit: limit, offset: offset), viewer: viewer)) }
        return try await listArticles(kind, limit: limit, offset: offset, viewer: viewer)
    }

    // ---------- requests ----------

    private func optional(_ request: Request) throws -> Int64 {
        let header = request.headers[.authorization] ?? ""
        let utf8 = header.utf8
        return try Auth.optional(utf8.span, signer)
    }

    private func require(_ request: Request) throws -> Int64 {
        let header = request.headers[.authorization] ?? ""
        let utf8 = header.utf8
        return try Auth.require(utf8.span, signer)
    }

    private func requireWithToken(_ request: Request) throws -> (Int64, String) {
        let header = request.headers[.authorization] ?? ""
        let utf8 = header.utf8
        return try Auth.requireWithToken(utf8.span, signer)
    }

    private func query(_ request: Request) -> QueryParams {
        QueryParams(ByteBuffer(string: request.uri.query ?? ""))
    }

    private func body(_ request: Request) async throws -> ByteBuffer {
        do {
            return try await request.body.collect(upTo: 1 << 20)
        } catch {
            throw ApiError(.contentTooLarge, "request body too large")
        }
    }

    /// A path parameter, percent-decoded. One that can't match a row (invalid UTF-8, or NUL, which Postgres text
    /// can't hold) is a 404 here.
    private func parameter(_ ctx: BasicRequestContext, _ name: String) throws -> String {
        let raw = ctx.parameters.get(name) ?? ""
        let utf8 = raw.utf8
        guard let s = percentDecodePath(utf8.span), !s.isEmpty, !s.utf8.contains(0) else {
            throw ApiError(.notFound, "not found")
        }
        return s
    }

    // ---------- responses ----------

    /// A batched read's response. `status` is for an article (201 after creating it).
    func render(_ result: borrowing ReadResult, token: String? = nil, status: Status = .ok) -> Response {
        switch result {
        case .page(let total, let articles, let json):
            return pageResponse(total: total, articles: articles, json: json)
        case .article(let article, let json):
            guard let article else { return errorResponse(.notFound, "article not found") }
            return articleResponse(article, json: json, status: status)
        case .comments(let comments, let json):
            guard let comments else { return errorResponse(.notFound, "article not found") }
            return commentsResponse(comments, json: json)
        case .profile(let profile):
            guard let profile else { return errorResponse(.notFound, "profile not found") }
            return profileResponse(profile)
        case .user(let user):
            guard let user else { return errorResponse(.unauthorized, "unauthorized") }
            return userResponse(.ok, user, token: token ?? "")
        case .tags(let body, let json):
            return tagsResponse(body, json: json)
        }
    }

    /// Runs a write's handler. An article it answers with is read once the write is committed: through the read
    /// batcher, or (READ_BATCHING=0) right here.
    private func write(_ handler: () async throws -> WriteOutcome) async -> Response {
        do {
            switch try await handler() {
            case .response(let response):
                return response
            case .article(let slug, let viewer, let status):
                if let reads { return render(try await reads.read(.article(slug: slug), viewer: viewer), status: status) }
                return try await writeFullArticle(status: status, ArticleByKey<ArticleBySlugSQL>(viewer: viewer, key: slug))
            }
        } catch {
            return errorResponse(for: error)
        }
    }
}
