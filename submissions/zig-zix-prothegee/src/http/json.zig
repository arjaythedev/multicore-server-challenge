//! JSON payload shapes for the API endpoints.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const UserView = struct {
    email: []const u8,
    token: []const u8,
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
};

pub const ProfileView = struct {
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    following: bool,
};

pub const ArticleSummaryView = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    tagList: []const []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    favorited: bool,
    favoritesCount: i64,
    author: ProfileView,
};

pub const ArticleView = struct {
    slug: []const u8,
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tagList: []const []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    favorited: bool,
    favoritesCount: i64,
    author: ProfileView,
};

pub const CommentView = struct {
    id: i64,
    body: []const u8,
    createdAt: []const u8,
    updatedAt: []const u8,
    author: ProfileView,
};

const UserEnvelope = struct {
    user: UserView,
};

const ProfileEnvelope = struct {
    profile: ProfileView,
};

const ArticlesEnvelope = struct {
    articles: []const ArticleSummaryView,
    articlesCount: i64,
};

const ArticleEnvelope = struct {
    article: ArticleView,
};

const CommentsEnvelope = struct {
    comments: []const CommentView,
};

const CommentEnvelope = struct {
    comment: CommentView,
};

const ErrorBody = struct {
    body: []const []const u8,
};

const ErrorEnvelope = struct {
    errors: ErrorBody,
};

const TagsEnvelope = struct {
    tags: []const []const u8,
};

// --------------------------------------------------------- //

/// Render `{"user": User}`.
pub fn renderUser(buf: []u8, user: UserView) !usize {
    return jzon.serialize(buf, UserEnvelope{ .user = user }, .{ .strategy = .GENERATED });
}

/// Render `{"errors": {"body": ["message"]}}`.
pub fn renderError(buf: []u8, message: []const u8) !usize {
    const messages = [_][]const u8{message};

    return jzon.serialize(buf, ErrorEnvelope{ .errors = .{ .body = &messages } }, .{ .strategy = .GENERATED });
}

/// Render `{"tags": ["name", ...]}`.
pub fn renderTags(buf: []u8, names: []const []const u8) !usize {
    return jzon.serialize(buf, TagsEnvelope{ .tags = names }, .{ .strategy = .GENERATED });
}

/// Render `{"profile": Profile}`.
pub fn renderProfile(buf: []u8, profile: ProfileView) !usize {
    return jzon.serialize(buf, ProfileEnvelope{ .profile = profile }, .{ .strategy = .GENERATED });
}

/// Render `{"articles": [Article], "articlesCount": count}`.
pub fn renderArticles(buf: []u8, articles: []const ArticleSummaryView, count: i64) !usize {
    return jzon.serialize(buf, ArticlesEnvelope{ .articles = articles, .articlesCount = count }, .{ .strategy = .GENERATED });
}

/// Render `{"article": Article}`.
pub fn renderArticle(buf: []u8, article: ArticleView) !usize {
    return jzon.serialize(buf, ArticleEnvelope{ .article = article }, .{ .strategy = .GENERATED });
}

/// Render `{"comments": [Comment]}`.
pub fn renderComments(buf: []u8, comments: []const CommentView) !usize {
    return jzon.serialize(buf, CommentsEnvelope{ .comments = comments }, .{ .strategy = .GENERATED });
}

/// Render `{"comment": Comment}`.
pub fn renderComment(buf: []u8, comment: CommentView) !usize {
    return jzon.serialize(buf, CommentEnvelope{ .comment = comment }, .{ .strategy = .GENERATED });
}

// --------------------------------------------------------- //

test "json: a user renders with a token" {
    var buf: [1024]u8 = undefined;

    const len = try renderUser(&buf, .{
        .email = "ada@example.com",
        .token = "tok",
        .username = "ada",
        .bio = null,
        .image = null,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"email\":\"ada@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"username\":\"ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"token\":\"tok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"image\":null") != null);
}

test "json: an error renders the body shape" {
    var buf: [256]u8 = undefined;

    const len = try renderError(&buf, "is invalid");
    const text = buf[0..len];

    try std.testing.expectEqualStrings("{\"errors\":{\"body\":[\"is invalid\"]}}", text);
}

test "json: a bio with quotes and backslashes is escaped" {
    var buf: [1024]u8 = undefined;

    const len = try renderUser(&buf, .{
        .email = "a@b.c",
        .token = "t",
        .username = "u",
        .bio = "say \"hi\" \\ end",
        .image = null,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "say \\\"hi\\\" \\\\ end") != null);

    // The rendered document is still valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}

test "json: a full user renders a small document" {
    var buf: [1024]u8 = undefined;

    const len = try renderUser(&buf, .{
        .email = "zoe@example.com",
        .token = "header.payload.signature",
        .username = "zoe",
        .bio = "hello",
        .image = "https://example.com/zoe.png",
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"image\":\"https://example.com/zoe.png\"") != null);
}

test "json: tags render as an array of names" {
    var buf: [256]u8 = undefined;
    const names = [_][]const u8{ "alpha", "beta" };

    const len = try renderTags(&buf, &names);

    try std.testing.expectEqualStrings("{\"tags\":[\"alpha\",\"beta\"]}", buf[0..len]);
}

test "json: an empty tag list renders an empty array" {
    var buf: [64]u8 = undefined;
    const names = [_][]const u8{};

    const len = try renderTags(&buf, &names);

    try std.testing.expectEqualStrings("{\"tags\":[]}", buf[0..len]);
}

test "json: a profile renders with the following flag" {
    var buf: [512]u8 = undefined;

    const len = try renderProfile(&buf, .{
        .username = "ada",
        .bio = null,
        .image = null,
        .following = true,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"username\":\"ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"image\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"following\":true") != null);
}

test "json: a profile with text fields and a false flag" {
    var buf: [512]u8 = undefined;

    const len = try renderProfile(&buf, .{
        .username = "zoe",
        .bio = "hello",
        .image = "https://example.com/zoe.png",
        .following = false,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"following\":false") != null);
}

test "json: an article list omits the body" {
    var buf: [1024]u8 = undefined;
    const tags = [_][]const u8{ "alpha", "beta" };
    const articles = [_]ArticleSummaryView{.{
        .slug = "hello-1",
        .title = "Hello",
        .description = "Short",
        .tagList = &tags,
        .createdAt = "2025-04-01T12:00:00.000Z",
        .updatedAt = "2025-04-01T12:00:00.000Z",
        .favorited = false,
        .favoritesCount = 0,
        .author = .{
            .username = "ada",
            .bio = null,
            .image = null,
            .following = false,
        },
    }};

    const len = try renderArticles(&buf, &articles, 1);
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"articles\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"articlesCount\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"tagList\":[\"alpha\",\"beta\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"createdAt\":\"2025-04-01T12:00:00.000Z\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"body\"") == null);
}

test "json: an article includes the body and the author" {
    var buf: [2048]u8 = undefined;
    const tags = [_][]const u8{"alpha"};
    const article = ArticleView{
        .slug = "hello-1",
        .title = "Hello",
        .description = "Short",
        .body = "Text",
        .tagList = &tags,
        .createdAt = "2025-04-01T12:00:00.000Z",
        .updatedAt = "2025-04-01T12:00:00.000Z",
        .favorited = true,
        .favoritesCount = 3,
        .author = .{
            .username = "ada",
            .bio = "bio",
            .image = null,
            .following = true,
        },
    };

    const len = try renderArticle(&buf, article);
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"body\":\"Text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"favorited\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"favoritesCount\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"author\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"following\":true") != null);
}

test "json: an empty article list renders the count" {
    var buf: [128]u8 = undefined;
    const empty = [_]ArticleSummaryView{};

    const len = try renderArticles(&buf, &empty, 0);

    try std.testing.expectEqualStrings("{\"articles\":[],\"articlesCount\":0}", buf[0..len]);
}

test "json: a comment renders with its author" {
    var buf: [1024]u8 = undefined;
    const comment = CommentView{
        .id = 25093,
        .body = "Hello",
        .createdAt = "2025-04-01T12:00:00.000Z",
        .updatedAt = "2025-04-01T12:00:00.000Z",
        .author = .{
            .username = "ada",
            .bio = null,
            .image = null,
            .following = false,
        },
    };

    const len = try renderComment(&buf, comment);
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"comment\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"id\":25093") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"body\":\"Hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"author\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"following\":false") != null);
}

test "json: an empty comment list renders no count" {
    var buf: [64]u8 = undefined;
    const empty = [_]CommentView{};

    const len = try renderComments(&buf, &empty);

    try std.testing.expectEqualStrings("{\"comments\":[]}", buf[0..len]);
}
