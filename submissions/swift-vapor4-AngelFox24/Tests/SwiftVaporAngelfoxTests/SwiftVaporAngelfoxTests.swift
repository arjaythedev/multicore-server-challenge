@testable import SwiftVaporAngelfox
import Fluent
import Foundation
import Testing
import VaporTesting

@Suite("Conduit API", .serialized)
struct SwiftVaporAngelfoxTests {
    // MARK: - Harness

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func send(
        _ app: Application,
        _ method: HTTPMethod,
        _ path: String,
        token: String? = nil,
        json: String? = nil
    ) async throws -> TestingHTTPResponse {
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        if let token {
            headers.replaceOrAdd(name: .authorization, value: "Token \(token)")
        }
        let body = json.map { ByteBufferAllocator().buffer(string: $0) }
        return try await app.testing().sendRequest(method, path, headers: headers, body: body) { request in
            // `sendRequest` builds the URI from the path alone, so re-parse it here
            // when the path contains a query string.
            request.url = URI(string: path)
        }
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private func jsonObject(_ response: TestingHTTPResponse) throws -> [String: Any] {
        let string = response.body.getString(
            at: response.body.readerIndex,
            length: response.body.readableBytes
        ) ?? ""
        return try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] ?? [:]
    }

    @discardableResult
    private func register(
        _ app: Application,
        username: String,
        email: String? = nil,
        password: String = "password123"
    ) async throws -> UserDTO {
        let payload = RegisterRequest(
            user: RegisterPayload(
                username: username,
                email: email ?? "\(username)@example.com",
                password: password
            )
        )
        let response = try await send(app, .POST, "api/users", json: try json(payload))
        #expect(response.status == .created)
        return try response.content.decode(UserResponse.self).user
    }

    @discardableResult
    private func createArticle(
        _ app: Application,
        token: String,
        title: String,
        description: String = "A description",
        body: String = "The body",
        tagList: [String]? = nil
    ) async throws -> ArticleDTO {
        let payload = CreateArticleRequest(
            article: CreateArticlePayload(
                title: title,
                description: description,
                body: body,
                tagList: tagList
            )
        )
        let response = try await send(app, .POST, "api/articles", token: token, json: try json(payload))
        #expect(response.status == .created)
        return try response.content.decode(ArticleResponse.self).article
    }

    private func decodeJWTPart(_ token: String, index: Int) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var base64 = String(parts[index])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return [:] }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func isRFC3339Milliseconds(_ value: String) -> Bool {
        value.range(
            of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
            options: .regularExpression
        ) != nil
    }

    // MARK: - Users

    @Test("Register, login, current user and profile updates")
    func userLifecycle() async throws {
        try await withApp { app in
            // Missing body fields are a 422 with the RealWorld error shape.
            let empty = try await send(app, .POST, "api/users", json: "{}")
            #expect(empty.status == .unprocessableEntity)
            #expect(try empty.content.decode(APIErrorBody.self).errors.body.count == 1)

            let blank = try await send(
                app,
                .POST,
                "api/users",
                json: #"{"user":{"username":"","email":"a@b.c","password":"x"}}"#
            )
            #expect(blank.status == .unprocessableEntity)

            // bcrypt only uses the first 72 bytes; the contract rejects longer input.
            let longPassword = try await send(
                app,
                .POST,
                "api/users",
                json: try json(
                    RegisterRequest(
                        user: RegisterPayload(
                            username: "toolong",
                            email: "toolong@example.com",
                            password: String(repeating: "p", count: 73)
                        )
                    )
                )
            )
            #expect(longPassword.status == .unprocessableEntity)

            let user = try await register(app, username: "alice", email: "alice@example.com")
            #expect(user.username == "alice")
            #expect(user.email == "alice@example.com")
            #expect(user.bio == nil)
            #expect(user.image == nil)

            let registerObject = try jsonObject(try await send(app, .POST, "api/users", json: #"{"user":{"username":"nulls","email":"nulls@example.com","password":"password123"}}"#))
            let registerUser = registerObject["user"] as? [String: Any]
            #expect(registerUser?["bio"] is NSNull)
            #expect(registerUser?["image"] is NSNull)

            // JWT: HS256 header, sub/iat/exp claims, 30 day expiry.
            let header = try decodeJWTPart(user.token, index: 0)
            #expect(header["alg"] as? String == "HS256")
            let claims = try decodeJWTPart(user.token, index: 1)
            let subject = claims["sub"] as? String
            #expect(subject.flatMap(Int.init) != nil)
            let issuedAt = (claims["iat"] as? NSNumber)?.doubleValue
            let expiresAt = (claims["exp"] as? NSNumber)?.doubleValue
            #expect(claims.count == 3)
            #expect(issuedAt != nil && expiresAt != nil)
            if let issuedAt, let expiresAt {
                // Conformance requires whole Unix seconds.
                #expect(issuedAt == issuedAt.rounded(.towardZero))
                #expect(expiresAt == expiresAt.rounded(.towardZero))
                #expect(abs(expiresAt - issuedAt - 2_592_000) < 5)
            }

            // bcrypt only uses the first 72 bytes, so longer passwords are rejected.
            let tooLong = try await send(
                app,
                .POST,
                "api/users",
                json: #"{"user":{"username":"longpass","email":"longpass@example.com","password":"\#(String(repeating: "p", count: 73))"}}"#
            )
            #expect(tooLong.status == .unprocessableEntity)

            // Duplicate email is a 422.
            let duplicate = try await send(
                app,
                .POST,
                "api/users",
                json: #"{"user":{"username":"other","email":"alice@example.com","password":"password123"}}"#
            )
            #expect(duplicate.status == .unprocessableEntity)

            // Login failures and success.
            let wrongPassword = try await send(
                app,
                .POST,
                "api/users/login",
                json: #"{"user":{"email":"alice@example.com","password":"wrong"}}"#
            )
            #expect(wrongPassword.status == .unauthorized)

            let unknownEmail = try await send(
                app,
                .POST,
                "api/users/login",
                json: #"{"user":{"email":"nobody@example.com","password":"password123"}}"#
            )
            #expect(unknownEmail.status == .unauthorized)

            let login = try await send(
                app,
                .POST,
                "api/users/login",
                json: #"{"user":{"email":"alice@example.com","password":"password123"}}"#
            )
            #expect(login.status == .ok)
            let loginToken = try login.content.decode(UserResponse.self).user.token

            // Auth required and invalid tokens are 401.
            #expect(try await send(app, .GET, "api/user").status == .unauthorized)
            #expect(try await send(app, .GET, "api/user", token: "garbage").status == .unauthorized)

            let current = try await send(app, .GET, "api/user", token: loginToken)
            #expect(current.status == .ok)
            #expect(try current.content.decode(UserResponse.self).user.token == loginToken)

            // Update profile fields.
            let update = try await send(
                app,
                .PUT,
                "api/user",
                token: loginToken,
                json: #"{"user":{"bio":"Hello","image":"https://example.com/a.png","username":"alice2"}}"#
            )
            #expect(update.status == .ok)
            let updated = try update.content.decode(UserResponse.self).user
            #expect(updated.username == "alice2")
            #expect(updated.bio == "Hello")
            #expect(updated.image == "https://example.com/a.png")

            // Explicit nulls and absent fields leave values unchanged.
            let nullUpdate = try await send(
                app,
                .PUT,
                "api/user",
                token: loginToken,
                json: #"{"user":{"bio":null,"image":null}}"#
            )
            #expect(nullUpdate.status == .ok)
            let afterNull = try nullUpdate.content.decode(UserResponse.self).user
            #expect(afterNull.bio == "Hello")
            #expect(afterNull.image == "https://example.com/a.png")

            // Empty email/username/password are rejected, but empty bio is allowed.
            for field in ["email", "username", "password"] {
                let empty = try await send(
                    app,
                    .PUT,
                    "api/user",
                    token: loginToken,
                    json: #"{"user":{"\#(field)":""}}"#
                )
                #expect(empty.status == .unprocessableEntity)
            }

            // Present-but-empty identity fields are rejected.
            for field in ["email", "username"] {
                let emptyField = try await send(
                    app,
                    .PUT,
                    "api/user",
                    token: loginToken,
                    json: #"{"user":{"\#(field)":""}}"#
                )
                #expect(emptyField.status == .unprocessableEntity)
            }

            let longPasswordUpdate = try await send(
                app,
                .PUT,
                "api/user",
                token: loginToken,
                json: #"{"user":{"password":"\#(String(repeating: "p", count: 73))"}}"#
            )
            #expect(longPasswordUpdate.status == .unprocessableEntity)

            // Password change takes effect.
            let passwordUpdate = try await send(
                app,
                .PUT,
                "api/user",
                token: loginToken,
                json: #"{"user":{"password":"newpassword"}}"#
            )
            #expect(passwordUpdate.status == .ok)

            let oldLogin = try await send(
                app,
                .POST,
                "api/users/login",
                json: #"{"user":{"email":"alice@example.com","password":"password123"}}"#
            )
            #expect(oldLogin.status == .unauthorized)

            let newLogin = try await send(
                app,
                .POST,
                "api/users/login",
                json: #"{"user":{"email":"alice@example.com","password":"newpassword"}}"#
            )
            #expect(newLogin.status == .ok)

            // A duplicate username/email on update is a 422.
            _ = try await register(app, username: "bob", email: "bob@example.com")
            let conflict = try await send(
                app,
                .PUT,
                "api/user",
                token: loginToken,
                json: #"{"user":{"email":"bob@example.com"}}"#
            )
            #expect(conflict.status == .unprocessableEntity)
        }
    }

    // MARK: - Profiles

    @Test("Profiles, follow and unfollow")
    func profilesAndFollows() async throws {
        try await withApp { app in
            let alice = try await register(app, username: "alice")
            let bob = try await register(app, username: "bob")

            let anonymous = try await send(app, .GET, "api/profiles/bob")
            #expect(anonymous.status == .ok)
            let anonymousProfile = try anonymous.content.decode(ProfileResponse.self).profile
            #expect(anonymousProfile.username == "bob")
            #expect(anonymousProfile.following == false)
            #expect(anonymousProfile.bio == nil)

            let missing = try await send(app, .GET, "api/profiles/nobody")
            #expect(missing.status == .notFound)
            #expect(try missing.content.decode(APIErrorBody.self).errors.body.count == 1)

            #expect(try await send(app, .POST, "api/profiles/bob/follow").status == .unauthorized)

            let follow = try await send(app, .POST, "api/profiles/bob/follow", token: alice.token)
            #expect(follow.status == .ok)
            #expect(try follow.content.decode(ProfileResponse.self).profile.following)

            // Following twice is idempotent.
            let followAgain = try await send(app, .POST, "api/profiles/bob/follow", token: alice.token)
            #expect(followAgain.status == .ok)
            #expect(try followAgain.content.decode(ProfileResponse.self).profile.following)

            let asAlice = try await send(app, .GET, "api/profiles/bob", token: alice.token)
            #expect(try asAlice.content.decode(ProfileResponse.self).profile.following)
            let asBob = try await send(app, .GET, "api/profiles/bob", token: bob.token)
            #expect(try asBob.content.decode(ProfileResponse.self).profile.following == false)

            let unfollow = try await send(app, .DELETE, "api/profiles/bob/follow", token: alice.token)
            #expect(unfollow.status == .ok)
            #expect(try unfollow.content.decode(ProfileResponse.self).profile.following == false)

            let unfollowAgain = try await send(app, .DELETE, "api/profiles/bob/follow", token: alice.token)
            #expect(unfollowAgain.status == .ok)
            #expect(try unfollowAgain.content.decode(ProfileResponse.self).profile.following == false)

            // An invalid token on an auth-optional endpoint is still 401.
            #expect(try await send(app, .GET, "api/profiles/bob", token: "nope").status == .unauthorized)

            let missingFollow = try await send(app, .POST, "api/profiles/nobody/follow", token: alice.token)
            #expect(missingFollow.status == .notFound)
        }
    }

    // MARK: - Articles

    @Test("Article create, read, update and delete")
    func articleCRUD() async throws {
        try await withApp { app in
            let alice = try await register(app, username: "alice")
            let bob = try await register(app, username: "bob")

            #expect(
                try await send(
                    app,
                    .POST,
                    "api/articles",
                    json: #"{"article":{"title":"T","description":"D","body":"B"}}"#
                ).status == .unauthorized
            )

            let missingField = try await send(
                app,
                .POST,
                "api/articles",
                token: alice.token,
                json: #"{"article":{"title":"","description":"D","body":"B"}}"#
            )
            #expect(missingField.status == .unprocessableEntity)

            let emptyTag = try await send(
                app,
                .POST,
                "api/articles",
                token: alice.token,
                json: #"{"article":{"title":"T","description":"D","body":"B","tagList":[""]}}"#
            )
            #expect(emptyTag.status == .unprocessableEntity)

            let article = try await createArticle(
                app,
                token: alice.token,
                title: "Hello World",
                tagList: ["Swift", "Vapor", "Swift"]
            )
            #expect(article.slug.hasPrefix("hello-world-"))
            #expect(article.tagList == ["Swift", "Vapor"])
            #expect(article.body == "The body")
            #expect(article.favorited == false)
            #expect(article.favoritesCount == 0)
            #expect(article.author.username == "alice")
            #expect(article.author.following == false)
            #expect(isRFC3339Milliseconds(article.createdAt))
            #expect(isRFC3339Milliseconds(article.updatedAt))
            #expect(article.createdAt == article.updatedAt)

            let shown = try await send(app, .GET, "api/articles/\(article.slug)")
            #expect(shown.status == .ok)
            #expect(try shown.content.decode(ArticleResponse.self).article.body == "The body")

            let updateByOther = try await send(
                app,
                .PUT,
                "api/articles/\(article.slug)",
                token: bob.token,
                json: #"{"article":{"title":"Nope"}}"#
            )
            #expect(updateByOther.status == .forbidden)

            let emptyTitle = try await send(
                app,
                .PUT,
                "api/articles/\(article.slug)",
                token: alice.token,
                json: #"{"article":{"title":""}}"#
            )
            #expect(emptyTitle.status == .unprocessableEntity)

            let updated = try await send(
                app,
                .PUT,
                "api/articles/\(article.slug)",
                token: alice.token,
                json: #"{"article":{"title":"New Title","description":"New description"}}"#
            )
            #expect(updated.status == .ok)
            let updatedArticle = try updated.content.decode(ArticleResponse.self).article
            #expect(updatedArticle.title == "New Title")
            #expect(updatedArticle.description == "New description")
            #expect(updatedArticle.slug.hasPrefix("new-title-"))
            #expect(updatedArticle.tagList == ["Swift", "Vapor"])

            // Updating only the body leaves the title-derived slug alone.
            let bodyUpdate = try await send(
                app,
                .PUT,
                "api/articles/\(updatedArticle.slug)",
                token: alice.token,
                json: #"{"article":{"body":"New body"}}"#
            )
            #expect(bodyUpdate.status == .ok)
            #expect(try bodyUpdate.content.decode(ArticleResponse.self).article.slug == updatedArticle.slug)

            let deleteByOther = try await send(
                app,
                .DELETE,
                "api/articles/\(updatedArticle.slug)",
                token: bob.token
            )
            #expect(deleteByOther.status == .forbidden)

            let deleted = try await send(
                app,
                .DELETE,
                "api/articles/\(updatedArticle.slug)",
                token: alice.token
            )
            #expect(deleted.status == .noContent)
            #expect(deleted.body.readableBytes == 0)

            #expect(try await send(app, .GET, "api/articles/\(updatedArticle.slug)").status == .notFound)
            #expect(try await send(app, .GET, "api/articles/does-not-exist").status == .notFound)
        }
    }

    @Test("Article lists, filters, pagination and feed")
    func articleLists() async throws {
        try await withApp { app in
            let alice = try await register(app, username: "alice")
            let bob = try await register(app, username: "bob")

            let alpha = try await createArticle(app, token: alice.token, title: "Alpha", tagList: ["Swift"])
            let beta = try await createArticle(app, token: alice.token, title: "Beta", tagList: ["Rust"])
            let gamma = try await createArticle(app, token: alice.token, title: "Gamma", tagList: ["Swift"])
            _ = try await send(app, .POST, "api/profiles/bob/follow", token: alice.token)
            let delta = try await createArticle(app, token: bob.token, title: "Delta", tagList: ["Swift"])

            let all = try await send(app, .GET, "api/articles")
            #expect(all.status == .ok)
            let allList = try all.content.decode(ArticleListResponse.self)
            #expect(allList.articlesCount == 4)
            #expect(allList.articles.map(\.slug) == [delta.slug, gamma.slug, beta.slug, alpha.slug])
            #expect(allList.articles.allSatisfy { $0.body == nil })

            let listObject = try jsonObject(all)
            let rawArticles = listObject["articles"] as? [[String: Any]] ?? []
            #expect(rawArticles.count == 4)
            #expect(rawArticles.allSatisfy { $0["body"] == nil })

            let page = try await send(app, .GET, "api/articles?limit=2&offset=1")
            let pageList = try page.content.decode(ArticleListResponse.self)
            #expect(pageList.articles.map(\.slug) == [gamma.slug, beta.slug])
            #expect(pageList.articlesCount == 4)

            let byTag = try await send(app, .GET, "api/articles?tag=Swift")
            let tagged = try byTag.content.decode(ArticleListResponse.self)
            #expect(tagged.articlesCount == 3)
            #expect(tagged.articles.map(\.slug) == [delta.slug, gamma.slug, alpha.slug])

            let byAuthor = try await send(app, .GET, "api/articles?author=alice")
            #expect(try byAuthor.content.decode(ArticleListResponse.self).articlesCount == 3)

            // Favoriting by Bob makes Alpha show up under favorited=bob.
            _ = try await send(app, .POST, "api/articles/\(alpha.slug)/favorite", token: bob.token)
            let byFavorite = try await send(app, .GET, "api/articles?favorited=bob")
            let favorited = try byFavorite.content.decode(ArticleListResponse.self)
            #expect(favorited.articlesCount == 1)
            #expect(favorited.articles.first?.slug == alpha.slug)
            #expect(favorited.articles.first?.favorited == false)

            // Tag wins over author when both are supplied.
            let precedence = try await send(app, .GET, "api/articles?tag=Rust&author=alice")
            #expect(try precedence.content.decode(ArticleListResponse.self).articles.map(\.slug) == [beta.slug])

            // Unknown filters are empty lists, not 404s.
            for filter in ["tag=missing", "author=missing", "favorited=missing"] {
                let response = try await send(app, .GET, "api/articles?\(filter)")
                #expect(response.status == .ok)
                #expect(try response.content.decode(ArticleListResponse.self).articles.isEmpty)
            }

            // Invalid pagination is 422.
            for query in ["limit=0", "limit=101", "limit=abc", "offset=-1", "offset=x"] {
                let response = try await send(app, .GET, "api/articles?\(query)")
                #expect(response.status == .unprocessableEntity)
            }

            // Feed requires auth and only contains followed authors' articles.
            #expect(try await send(app, .GET, "api/articles/feed").status == .unauthorized)

            let feed = try await send(app, .GET, "api/articles/feed", token: alice.token)
            #expect(feed.status == .ok)
            let feedList = try feed.content.decode(ArticleListResponse.self)
            #expect(feedList.articlesCount == 1)
            #expect(feedList.articles.map(\.slug) == [delta.slug])

            // The conformance suite uses `/api/articles/feed?&limit=...`.
            let feedPage = try await send(
                app,
                .GET,
                "api/articles/feed?&limit=10&offset=0",
                token: alice.token
            )
            #expect(feedPage.status == .ok)
            #expect(try feedPage.content.decode(ArticleListResponse.self).articles.map(\.slug) == [delta.slug])

            let bobFeed = try await send(app, .GET, "api/articles/feed", token: bob.token)
            #expect(bobFeed.status == .ok)
            #expect(try bobFeed.content.decode(ArticleListResponse.self).articles.isEmpty)

            // Optional auth still rejects a bad token.
            #expect(try await send(app, .GET, "api/articles", token: "bad").status == .unauthorized)
        }
    }

    // MARK: - Favorites

    @Test("Favorites are idempotent and reflected in article payloads")
    func favorites() async throws {
        try await withApp { app in
            let alice = try await register(app, username: "alice")
            let bob = try await register(app, username: "bob")
            let article = try await createArticle(app, token: alice.token, title: "Popular")

            #expect(try await send(app, .POST, "api/articles/\(article.slug)/favorite").status == .unauthorized)

            let first = try await send(app, .POST, "api/articles/\(article.slug)/favorite", token: bob.token)
            #expect(first.status == .ok)
            let firstArticle = try first.content.decode(ArticleResponse.self).article
            #expect(firstArticle.favorited)
            #expect(firstArticle.favoritesCount == 1)
            #expect(firstArticle.body == "The body")

            let second = try await send(app, .POST, "api/articles/\(article.slug)/favorite", token: bob.token)
            #expect(try second.content.decode(ArticleResponse.self).article.favoritesCount == 1)

            let anonymous = try await send(app, .GET, "api/articles/\(article.slug)")
            let anonymousArticle = try anonymous.content.decode(ArticleResponse.self).article
            #expect(anonymousArticle.favorited == false)
            #expect(anonymousArticle.favoritesCount == 1)

            _ = try await send(app, .POST, "api/articles/\(article.slug)/favorite", token: alice.token)
            let aliceView = try await send(app, .GET, "api/articles/\(article.slug)", token: alice.token)
            let aliceArticle = try aliceView.content.decode(ArticleResponse.self).article
            #expect(aliceArticle.favorited)
            #expect(aliceArticle.favoritesCount == 2)

            let unfavorite = try await send(app, .DELETE, "api/articles/\(article.slug)/favorite", token: bob.token)
            #expect(unfavorite.status == .ok)
            let unfavorited = try unfavorite.content.decode(ArticleResponse.self).article
            #expect(unfavorited.favorited == false)
            #expect(unfavorited.favoritesCount == 1)

            let unfavoriteAgain = try await send(app, .DELETE, "api/articles/\(article.slug)/favorite", token: bob.token)
            #expect(unfavoriteAgain.status == .ok)
            #expect(try unfavoriteAgain.content.decode(ArticleResponse.self).article.favoritesCount == 1)

            #expect(
                try await send(app, .POST, "api/articles/missing/favorite", token: bob.token).status == .notFound
            )
        }
    }

    // MARK: - Comments

    @Test("Comments: create, list, following and delete")
    func comments() async throws {
        try await withApp { app in
            let alice = try await register(app, username: "alice")
            let bob = try await register(app, username: "bob")
            let article = try await createArticle(app, token: alice.token, title: "Discussed")

            let emptyList = try await send(app, .GET, "api/articles/\(article.slug)/comments")
            #expect(emptyList.status == .ok)
            #expect(try emptyList.content.decode(CommentListResponse.self).comments.isEmpty)

            #expect(
                try await send(
                    app,
                    .POST,
                    "api/articles/\(article.slug)/comments",
                    json: #"{"comment":{"body":"Hi"}}"#
                ).status == .unauthorized
            )

            let emptyBody = try await send(
                app,
                .POST,
                "api/articles/\(article.slug)/comments",
                token: bob.token,
                json: #"{"comment":{"body":""}}"#
            )
            #expect(emptyBody.status == .unprocessableEntity)

            #expect(
                try await send(
                    app,
                    .POST,
                    "api/articles/missing/comments",
                    token: bob.token,
                    json: #"{"comment":{"body":"Hi"}}"#
                ).status == .notFound
            )

            let created = try await send(
                app,
                .POST,
                "api/articles/\(article.slug)/comments",
                token: bob.token,
                json: #"{"comment":{"body":"Nice article"}}"#
            )
            #expect(created.status == .created)
            let comment = try created.content.decode(CommentResponse.self).comment
            #expect(comment.body == "Nice article")
            #expect(comment.author.username == "bob")
            #expect(comment.author.following == false)
            #expect(isRFC3339Milliseconds(comment.createdAt))
            #expect(isRFC3339Milliseconds(comment.updatedAt))
            #expect(comment.createdAt == comment.updatedAt)

            // Following the author is reflected when listing, not when creating.
            _ = try await send(app, .POST, "api/profiles/bob/follow", token: alice.token)

            let listed = try await send(app, .GET, "api/articles/\(article.slug)/comments", token: alice.token)
            #expect(listed.status == .ok)
            let comments = try listed.content.decode(CommentListResponse.self).comments
            #expect(comments.count == 1)
            #expect(comments.first?.author.following == true)

            // Newest first when several comments share a timestamp.
            for body in ["Second", "Third"] {
                let response = try await send(
                    app,
                    .POST,
                    "api/articles/\(article.slug)/comments",
                    token: bob.token,
                    json: try json(CreateCommentRequest(comment: CreateCommentPayload(body: body)))
                )
                #expect(response.status == .created)
            }
            let ordered = try await send(app, .GET, "api/articles/\(article.slug)/comments")
            #expect(
                try ordered.content.decode(CommentListResponse.self).comments.map(\.body)
                    == ["Third", "Second", "Nice article"]
            )

            let forbidden = try await send(
                app,
                .DELETE,
                "api/articles/\(article.slug)/comments/\(comment.id)",
                token: alice.token
            )
            #expect(forbidden.status == .forbidden)

            let badID = try await send(
                app,
                .DELETE,
                "api/articles/\(article.slug)/comments/not-a-number",
                token: bob.token
            )
            #expect(badID.status == .notFound)

            let deleted = try await send(
                app,
                .DELETE,
                "api/articles/\(article.slug)/comments/\(comment.id)",
                token: bob.token
            )
            #expect(deleted.status == .noContent)
            #expect(deleted.body.readableBytes == 0)

            let unknown = try await send(
                app,
                .DELETE,
                "api/articles/\(article.slug)/comments/\(comment.id)",
                token: bob.token
            )
            #expect(unknown.status == .notFound)
        }
    }

    // MARK: - Tags and error shape

    @Test("Tags are sorted and unknown routes use the RealWorld error shape")
    func tagsAndErrors() async throws {
        try await withApp { app in
            let empty = try await send(app, .GET, "api/tags")
            #expect(empty.status == .ok)
            #expect(try empty.content.decode(TagsResponse.self).tags.isEmpty)
            #expect(empty.headers.contentType == .json)

            let alice = try await register(app, username: "alice")
            _ = try await createArticle(app, token: alice.token, title: "One", tagList: ["Zeta", "Alpha"])
            _ = try await createArticle(app, token: alice.token, title: "Two", tagList: ["Beta"])

            let tags = try await send(app, .GET, "api/tags")
            #expect(tags.status == .ok)
            #expect(try tags.content.decode(TagsResponse.self).tags == ["Alpha", "Beta", "Zeta"])

            let notFound = try await send(app, .GET, "api/does-not-exist")
            #expect(notFound.status == .notFound)
            #expect(notFound.headers.contentType == .json)
            let body = try notFound.content.decode(APIErrorBody.self)
            #expect(body.errors.body.count == 1)

            let malformed = try await send(app, .POST, "api/users", json: "{")
            #expect(malformed.status == .unprocessableEntity)
            #expect(try malformed.content.decode(APIErrorBody.self).errors.body.count == 1)
        }
    }
}
