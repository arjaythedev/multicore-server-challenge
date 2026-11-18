// What the server reads from Postgres and how it is written as JSON. A row's text stays where Postgres put it: a
// `PGTextRef` into the buffer its batch (or its write) copied the rows into, passed along `borrowing` to the JSON
// writer, which escapes it straight into the response. A batch writes every article, comment, profile and user it
// shows once, with the values that depend on the viewer left open (a splice); each response copies its parts and
// fills those in.

struct ProfileRow {
    var username: PGTextRef
    var bio: PGTextRef?
    var image: PGTextRef?
    var following: Bool
}

struct UserRow {
    var username: PGTextRef
    var email: PGTextRef
    var bio: PGTextRef?
    var image: PGTextRef?
}

struct ArticleRow {
    var slug: PGTextRef
    var title: PGTextRef
    var description: PGTextRef
    var body: PGTextRef?
    var tagList: [PGTextRef]
    var createdAt: PGTimestamp
    var updatedAt: PGTimestamp
    var favorited: Bool
    var favoritesCount: Int64
    var author: ProfileRow
}

struct CommentRow {
    var id: Int64
    var body: PGTextRef
    var createdAt: PGTimestamp
    var updatedAt: PGTimestamp
    var author: ProfileRow
}

// ---------- reading rows ----------

extension PGCursor {
    /// username, bio, image (the viewer's `following` comes from elsewhere).
    mutating func profile(_ rows: borrowing Bytes) throws(PGCursorError) -> ProfileRow {
        let username = try text(rows)
        let bio = try textOrNull(rows)
        let image = try textOrNull(rows)
        return ProfileRow(username: username, bio: bio, image: image, following: false)
    }

    /// id, username, email, bio, image.
    mutating func user(_ rows: borrowing Bytes) throws(PGCursorError) -> (id: Int64, user: UserRow) {
        let id = try int(rows)
        let username = try text(rows)
        let email = try text(rows)
        let bio = try textOrNull(rows)
        let image = try textOrNull(rows)
        return (id, UserRow(username: username, email: email, bio: bio, image: image))
    }

    /// A whole article as a write reads it (WriteArticleColumns): slug, title, description, body, created_at,
    /// updated_at, its tag names, favorited, favorites count, then the author's username, bio, image and following.
    mutating func article(_ rows: borrowing Bytes) throws(PGCursorError) -> ArticleRow {
        let slug = try text(rows)
        let title = try text(rows)
        let description = try text(rows)
        let body = try text(rows)
        let createdAt = try timestamp(rows)
        let updatedAt = try timestamp(rows)
        let tagList = try textArray(rows)
        let favorited = try bool(rows)
        let favoritesCount = try int(rows)
        var author = try profile(rows)
        author.following = try bool(rows)
        return ArticleRow(slug: slug, title: title, description: description, body: body, tagList: tagList,
                          createdAt: createdAt, updatedAt: updatedAt, favorited: favorited,
                          favoritesCount: favoritesCount, author: author)
    }

    /// id, body, created_at, updated_at, then the author's username, bio, image.
    mutating func comment(_ rows: borrowing Bytes) throws(PGCursorError) -> CommentRow {
        let id = try int(rows)
        let body = try text(rows)
        let createdAt = try timestamp(rows)
        let updatedAt = try timestamp(rows)
        return CommentRow(id: id, body: body, createdAt: createdAt, updatedAt: updatedAt, author: try profile(rows))
    }
}

// ---------- writing them ----------

extension JSONWriter {
    mutating func string(_ t: PGTextRef, _ rows: borrowing Bytes) {
        rows.withSpan { escaped($0.extracting(Int(t.start)..<Int(t.start + t.count))) }
    }

    mutating func stringOrNull(_ t: PGTextRef?, _ rows: borrowing Bytes) {
        if let t { string(t, rows) } else { raw("null") }
    }

    /// {"username":..,"bio":..,"image":..,"following":..}: a profile, or an article's or comment's author.
    mutating func author(_ p: borrowing ProfileRow, _ rows: borrowing Bytes) {
        authorUpToFollowing(p, rows)
        bool(p.following)
        raw("}")
    }

    /// An author up to its `following` value, which depends on the viewer.
    mutating func authorUpToFollowing(_ p: borrowing ProfileRow, _ rows: borrowing Bytes) {
        raw("{\"username\":"); string(p.username, rows)
        raw(",\"bio\":"); stringOrNull(p.bio, rows)
        raw(",\"image\":"); stringOrNull(p.image, rows)
        raw(",\"following\":")
    }

    /// {"user":{...}} with the token as presented or as just issued.
    mutating func user(_ u: borrowing UserRow, token: String, _ rows: borrowing Bytes) {
        userUpToToken(u, rows)
        string(token)
        userAfterToken(u, rows)
    }

    private mutating func userUpToToken(_ u: borrowing UserRow, _ rows: borrowing Bytes) {
        raw("{\"user\":{\"email\":"); string(u.email, rows)
        raw(",\"token\":")
    }

    private mutating func userAfterToken(_ u: borrowing UserRow, _ rows: borrowing Bytes) {
        raw(",\"username\":"); string(u.username, rows)
        raw(",\"bio\":"); stringOrNull(u.bio, rows)
        raw(",\"image\":"); stringOrNull(u.image, rows)
        raw("}}")
    }

    mutating func article(_ a: borrowing ArticleRow, full: Bool, _ rows: borrowing Bytes) {
        articleUpToFavorited(a, full: full, rows)
        bool(a.favorited)
        articleUpToFollowing(a, rows)
        bool(a.author.following)
        raw("}}")
    }

    /// An article up to its `favorited` value: the part that is the same for every viewer.
    private mutating func articleUpToFavorited(_ a: borrowing ArticleRow, full: Bool, _ rows: borrowing Bytes) {
        raw("{\"slug\":"); string(a.slug, rows)
        raw(",\"title\":"); string(a.title, rows)
        raw(",\"description\":"); string(a.description, rows)
        if full, let body = a.body { raw(",\"body\":"); string(body, rows) }
        raw(",\"tagList\":[")
        for i in a.tagList.indices {
            if i > 0 { raw(",") }
            string(a.tagList[i], rows)
        }
        raw("],\"createdAt\":"); timestamp(a.createdAt)
        raw(",\"updatedAt\":"); timestamp(a.updatedAt)
        raw(",\"favorited\":")
    }

    /// From after `favorited` up to the author's `following` value.
    private mutating func articleUpToFollowing(_ a: borrowing ArticleRow, _ rows: borrowing Bytes) {
        raw(",\"favoritesCount\":"); int(a.favoritesCount)
        raw(",\"author\":"); authorUpToFollowing(a.author, rows)
    }

    mutating func comment(_ c: borrowing CommentRow, _ rows: borrowing Bytes) {
        commentUpToFollowing(c, rows)
        bool(c.author.following)
        raw("}}")
    }

    /// A comment up to its author's `following` value, which depends on the viewer.
    private mutating func commentUpToFollowing(_ c: borrowing CommentRow, _ rows: borrowing Bytes) {
        raw("{\"id\":"); int(c.id)
        raw(",\"createdAt\":"); timestamp(c.createdAt)
        raw(",\"updatedAt\":"); timestamp(c.updatedAt)
        raw(",\"body\":"); string(c.body, rows)
        raw(",\"author\":"); authorUpToFollowing(c.author, rows)
    }

    // ---------- once per batch, with the viewer's values left open ----------

    mutating func articleSplice(_ a: borrowing ArticleRow, full: Bool, _ rows: borrowing Bytes) -> ArticleSplice {
        let start = position
        articleUpToFavorited(a, full: full, rows)
        let favorited = position
        articleUpToFollowing(a, rows)
        return ArticleSplice(start: Int32(start), favorited: Int32(favorited), following: Int32(position))
    }

    mutating func commentSplice(_ c: borrowing CommentRow, _ rows: borrowing Bytes) -> CommentSplice {
        let start = position
        commentUpToFollowing(c, rows)
        return CommentSplice(start: Int32(start), following: Int32(position))
    }

    /// {"profile":{..., "following":} : the response's whole body but for that value and the closing `}}`.
    mutating func profileSplice(_ p: borrowing ProfileRow, _ rows: borrowing Bytes) -> ProfileSplice {
        let start = position
        raw("{\"profile\":")
        authorUpToFollowing(p, rows)
        return ProfileSplice(start: Int32(start), following: Int32(position))
    }

    /// {"user":{...}}: the response's whole body but for the token.
    mutating func userSplice(_ u: borrowing UserRow, _ rows: borrowing Bytes) -> UserSplice {
        let start = position
        userUpToToken(u, rows)
        let token = position
        userAfterToken(u, rows)
        return UserSplice(start: Int32(start), token: Int32(token), end: Int32(position))
    }

    // ---------- one viewer's copy ----------

    mutating func article(_ view: ArticleView, from json: JSONBytes) {
        let s = view.splice
        splice(json, s.start..<s.favorited)
        bool(view.favorited)
        splice(json, s.favorited..<s.following)
        bool(view.following)
        raw("}}")
    }

    mutating func comment(_ view: CommentView, from json: JSONBytes) {
        splice(json, view.splice.start..<view.splice.following)
        bool(view.following)
        raw("}}")
    }

    mutating func profile(_ view: ProfileView, from json: JSONBytes) {
        splice(json, view.splice.start..<view.splice.following)
        bool(view.following)
        raw("}}")
    }

    mutating func user(_ s: UserSplice, token: String, from json: JSONBytes) {
        splice(json, s.start..<s.token)
        string(token)
        splice(json, s.token..<s.end)
    }
}

/// Where an article's JSON sits in its batch's buffer: from `start`, with the `favorited` value due at `favorited` and
/// the author's `following` value at `following`; the object then ends with `}}`.
struct ArticleSplice: Sendable, BitwiseCopyable {
    let start: Int32
    let favorited: Int32
    let following: Int32

    var length: Int { Int(following - start) + 16 }
}

/// An article of a batch as one viewer sees it.
struct ArticleView: Sendable, BitwiseCopyable {
    let splice: ArticleSplice
    let favorited: Bool
    let following: Bool
}

/// Where a comment's JSON sits in its batch's buffer; the author's `following` value is due at `following`.
struct CommentSplice: Sendable, BitwiseCopyable {
    let start: Int32
    let following: Int32
}

struct CommentView: Sendable, BitwiseCopyable {
    let splice: CommentSplice
    let following: Bool
}

/// A profile response's body in its batch's buffer, with `following` due at `following`.
struct ProfileSplice: Sendable, BitwiseCopyable {
    let start: Int32
    let following: Int32
}

struct ProfileView: Sendable, BitwiseCopyable {
    let splice: ProfileSplice
    let following: Bool
}

/// A user response's body in its batch's buffer, with the token due at `token`.
struct UserSplice: Sendable, BitwiseCopyable {
    let start: Int32
    let token: Int32
    let end: Int32

    var length: Int { Int(end - start) }
}

/// A login's user, read in a batch: what bcrypt checks, and the response's body but for the token.
struct LoginView: Sendable {
    let id: Int64
    let hash: String
    let user: UserSplice
}
