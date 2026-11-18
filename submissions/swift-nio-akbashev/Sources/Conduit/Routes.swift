// Routing: a request's method and path to its handler, on the connection's event loop. Token checks, query parsing
// and the 401/404/422s that need no database happen right there; a hot read goes to the read batcher, everything
// else to an async handler.
import NIOCore

enum Dispatch {
    /// Answered without the database.
    case now(Response)
    /// A read for the batcher. `token` is GET /api/user's, which its response echoes.
    case read(Read, viewer: Int64, token: String?)
    case later(@Sendable () async -> Answer)
}

/// What an async handler answers with.
enum Answer: Sendable {
    case response(Response)
    /// A read for the batcher, answered under `status`: the article a write returns, read once the write is committed.
    case read(Read, viewer: Int64, status: Status)
}

/// The non-empty segments of a path, as ranges of it: empty ones (`//`, a trailing `/`) are skipped. More than five
/// matches no route, so `count` stops at six.
private struct PathSegments {
    private(set) var ranges = InlineArray<6, Range<Int>>(repeating: 0..<0)
    private(set) var count = 0

    init(_ path: Span<UInt8>) {
        var i = 0
        while i < path.count {
            while i < path.count, path[i] == 0x2F { i += 1 } // /
            let start = i
            while i < path.count, path[i] != 0x2F { i += 1 }
            guard i > start else { break }
            ranges[count] = start..<i
            count += 1
            if count == 6 { return }
        }
    }
}

extension App {
    func dispatch(_ method: Method, path: Span<UInt8>, query: ByteBuffer, authorization: Span<UInt8>,
                  body: ByteBuffer) -> Dispatch {
        do {
            return try route(method, path, query, authorization, body)
        } catch {
            return .now(errorResponse(for: error))
        }
    }

    private func route(_ method: Method, _ path: Span<UInt8>, _ query: ByteBuffer, _ authorization: Span<UInt8>,
                       _ body: ByteBuffer) throws -> Dispatch {
        let segments = PathSegments(path)
        let r = segments.ranges
        guard (2...5).contains(segments.count), equals(path.extracting(r[0]), "api") else { throw notFound }
        let resource = path.extracting(r[1])

        switch segments.count {
        case 2:
            if equals(resource, "articles") {
                switch method {
                case .get:
                    return try listArticles(QueryParams(query), viewer: Auth.optional(authorization, signer))
                case .post:
                    let viewer = try Auth.require(authorization, signer)
                    return .later { await handleWrite { try await self.createArticle(viewer: viewer, body) } }
                default: break
                }
            } else if equals(resource, "tags"), method == .get {
                if reads != nil { return .read(.tags, viewer: 0, token: nil) }
                return .later { await handle { try await self.tags() } }
            } else if equals(resource, "user") {
                switch method {
                case .get:
                    let (viewer, token) = try Auth.requireWithToken(authorization, signer)
                    if reads != nil { return .read(.user(id: viewer), viewer: viewer, token: token) }
                    return .later { await handle { try await self.currentUser(viewer: viewer, token: token) } }
                case .put:
                    let (viewer, token) = try Auth.requireWithToken(authorization, signer)
                    return .later { await handleWrite { try await self.updateUser(viewer: viewer, token: token, body) } }
                default: break
                }
            } else if equals(resource, "users"), method == .post {
                return .later { await handleWrite { try await self.register(body) } }
            }

        case 3:
            let key = path.extracting(r[2])
            if equals(resource, "articles") {
                if method == .get, equals(key, "feed") {
                    return try feed(QueryParams(query), viewer: Auth.require(authorization, signer))
                }
                let slug = try segment(key)
                switch method {
                case .get:
                    let viewer = try Auth.optional(authorization, signer)
                    if reads != nil { return .read(.article(slug: slug), viewer: viewer, token: nil) }
                    return .later { await handle { try await self.getArticle(viewer: viewer, slug: slug) } }
                case .put:
                    let viewer = try Auth.require(authorization, signer)
                    return .later { await handleWrite { try await self.updateArticle(viewer: viewer, slug: slug, body) } }
                case .delete:
                    let viewer = try Auth.require(authorization, signer)
                    return .later { await handleWrite { try await self.deleteArticle(viewer: viewer, slug: slug) } }
                default: break
                }
            } else if equals(resource, "profiles"), method == .get {
                let username = try segment(key)
                let viewer = try Auth.optional(authorization, signer)
                if reads != nil { return .read(.profile(username: username), viewer: viewer, token: nil) }
                return .later { await handle { try await self.getProfile(viewer: viewer, username: username) } }
            } else if equals(resource, "users"), equals(key, "login"), method == .post {
                return .later { await handle { try await self.login(body) } }
            }

        case 4:
            let action = path.extracting(r[3])
            let toggle = method == .post || method == .delete
            if equals(resource, "articles") {
                if equals(action, "favorite"), toggle {
                    let slug = try segment(path.extracting(r[2]))
                    let viewer = try Auth.require(authorization, signer)
                    return .later { await handleWrite { try await self.favorite(viewer: viewer, slug: slug, on: method == .post) } }
                } else if equals(action, "comments") {
                    let slug = try segment(path.extracting(r[2]))
                    switch method {
                    case .get:
                        let viewer = try Auth.optional(authorization, signer)
                        if reads != nil { return .read(.comments(slug: slug), viewer: viewer, token: nil) }
                        return .later { await handle { try await self.listComments(viewer: viewer, slug: slug) } }
                    case .post:
                        let viewer = try Auth.require(authorization, signer)
                        return .later { await handleWrite { try await self.createComment(viewer: viewer, slug: slug, body) } }
                    default: break
                    }
                }
            } else if equals(resource, "profiles"), equals(action, "follow"), toggle {
                let username = try segment(path.extracting(r[2]))
                let viewer = try Auth.require(authorization, signer)
                return .later { await handleWrite { try await self.follow(viewer: viewer, username: username, on: method == .post) } }
            }

        case 5:
            if equals(resource, "articles"), equals(path.extracting(r[3]), "comments"), method == .delete {
                let slug = try segment(path.extracting(r[2]))
                let viewer = try Auth.require(authorization, signer)
                // SPEC.md: a non-integer :id is a 404.
                guard let id = parseUint(path.extracting(r[4])) else { throw ApiError(.notFound, "comment not found") }
                return .later { await handleWrite { try await self.deleteComment(viewer: viewer, slug: slug, id: id) } }
            }

        default:
            break
        }
        throw notFound
    }

    // GET /api/articles: the first non-empty filter of tag, author and favorited applies; later ones aren't looked up.
    private func listArticles(_ query: QueryParams, viewer: Int64) throws -> Dispatch {
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
            return .now(emptyPage())
        }
        if reads != nil { return .read(.page(kind, limit: limit, offset: offset), viewer: viewer, token: nil) }
        return .later { await handle { try await self.listArticles(kind, limit: limit, offset: offset, viewer: viewer) } }
    }

    // GET /api/articles/feed
    private func feed(_ query: QueryParams, viewer: Int64) throws -> Dispatch {
        let (limit, offset) = try limitOffset(query)
        if reads != nil { return .read(.page(.feed(viewer), limit: limit, offset: offset), viewer: viewer, token: nil) }
        return .later { await handle { try await self.listArticles(.feed(viewer), limit: limit, offset: offset, viewer: viewer) } }
    }

    /// A batched read's response, on the connection's event loop. `status` is for an article (201 after creating it).
    func render(_ result: borrowing ReadResult, token: String?, status: Status) -> Response {
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
}

extension App {
    /// Runs a write's handler. An article it answers with is read once the write is committed: through the read
    /// batcher, or (READ_BATCHING=0) right here.
    func handleWrite(_ handler: () async throws -> WriteOutcome) async -> Answer {
        do {
            switch try await handler() {
            case .response(let response):
                return .response(response)
            case .article(let slug, let viewer, let status):
                if reads != nil { return .read(.article(slug: slug), viewer: viewer, status: status) }
                return .response(try await writeFullArticle(status: status, ArticleByKey<ArticleBySlugSQL>(viewer: viewer, key: slug)))
            }
        } catch {
            return .response(errorResponse(for: error))
        }
    }
}

private let notFound = ApiError(.notFound, "not found")

/// A path parameter, percent-decoded. One that can't match a row (invalid UTF-8, or NUL, which Postgres text can't
/// hold) is a 404 here.
private func segment(_ bytes: Span<UInt8>) throws -> String {
    guard let s = percentDecodePath(bytes), !s.utf8.contains(0) else { throw notFound }
    return s
}
