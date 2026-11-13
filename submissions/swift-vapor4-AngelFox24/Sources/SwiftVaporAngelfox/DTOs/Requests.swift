import Vapor

// Wrapper types match the RealWorld request bodies exactly. Decoding failures
// (missing keys, nulls where a value is required, wrong types) become 422 in
// APIErrorMiddleware.

struct RegisterRequest: Content, Sendable {
    let user: RegisterPayload
}

struct RegisterPayload: Content, Sendable {
    let username: String
    let email: String
    let password: String
}

struct LoginRequest: Content, Sendable {
    let user: LoginPayload
}

struct LoginPayload: Content, Sendable {
    let email: String
    let password: String
}

struct UpdateUserRequest: Content, Sendable {
    let user: UpdateUserPayload
}

struct UpdateUserPayload: Content, Sendable {
    let email: String?
    let username: String?
    let password: String?
    let bio: String?
    let image: String?
}

struct CreateArticleRequest: Content, Sendable {
    let article: CreateArticlePayload
}

struct CreateArticlePayload: Content, Sendable {
    let title: String
    let description: String
    let body: String
    let tagList: [String]?
}

struct UpdateArticleRequest: Content, Sendable {
    let article: UpdateArticlePayload
}

struct UpdateArticlePayload: Content, Sendable {
    let title: String?
    let description: String?
    let body: String?
}

struct CreateCommentRequest: Content, Sendable {
    let comment: CreateCommentPayload
}

struct CreateCommentPayload: Content, Sendable {
    let body: String
}

/// Query parameters arrive as raw strings so a present but invalid value can
/// be rejected with 422 instead of being silently replaced by the default.
struct ArticleListQuery: Content, Sendable {
    let tag: String?
    let author: String?
    let favorited: String?
    let limit: String?
    let offset: String?
}
