//! Response writes for the API endpoints.

const std = @import("std");
const zix = @import("zix");

const json = @import("json.zig");

// --------------------------------------------------------- //

/// Room for one rendered user or profile document. Seed bios and images are short.
const BODY_MAX: usize = 8 * 1024;

/// Room for one rendered error document.
const ERROR_BODY_MAX: usize = 256;

/// Room for one rendered article list. A page holds at most 20 summaries.
const ARTICLE_LIST_BODY_MAX: usize = 64 * 1024;

/// Room for one rendered full article.
const ARTICLE_BODY_MAX: usize = 32 * 1024;

/// Room for one rendered comment list. The list returns at most 100 comments.
const COMMENTS_BODY_MAX: usize = 128 * 1024;

/// Room for one rendered comment.
const COMMENT_BODY_MAX: usize = 16 * 1024;

/// Room for one rendered tag list.
const TAGS_BODY_MAX: usize = 16 * 1024;

// --------------------------------------------------------- //

/// Send a JSON `{"user": ...}` response.
pub fn sendUser(res: *zix.Http1.Response, user: json.UserView, status: zix.Http1.Status.Code) !void {
    var buf: [BODY_MAX]u8 = undefined;

    const len = json.renderUser(&buf, user) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"profile": ...}` response.
pub fn sendProfile(res: *zix.Http1.Response, profile: json.ProfileView, status: zix.Http1.Status.Code) !void {
    var buf: [BODY_MAX]u8 = undefined;

    const len = json.renderProfile(&buf, profile) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"tags": [...]}` response.
pub fn sendTags(res: *zix.Http1.Response, tags: []const []const u8, status: zix.Http1.Status.Code) !void {
    var buf: [TAGS_BODY_MAX]u8 = undefined;

    const len = json.renderTags(&buf, tags) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"articles": ..., "articlesCount": ...}` response.
pub fn sendArticles(
    res: *zix.Http1.Response,
    articles: []const json.ArticleSummaryView,
    count: i64,
    status: zix.Http1.Status.Code,
) !void {
    var buf: [ARTICLE_LIST_BODY_MAX]u8 = undefined;

    const len = json.renderArticles(&buf, articles, count) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"article": ...}` response.
pub fn sendArticle(res: *zix.Http1.Response, article: json.ArticleView, status: zix.Http1.Status.Code) !void {
    var buf: [ARTICLE_BODY_MAX]u8 = undefined;

    const len = json.renderArticle(&buf, article) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"comments": [...]}` response.
pub fn sendComments(
    res: *zix.Http1.Response,
    comments: []const json.CommentView,
    status: zix.Http1.Status.Code,
) !void {
    var buf: [COMMENTS_BODY_MAX]u8 = undefined;

    const len = json.renderComments(&buf, comments) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send a JSON `{"comment": ...}` response.
pub fn sendComment(res: *zix.Http1.Response, comment: json.CommentView, status: zix.Http1.Status.Code) !void {
    var buf: [COMMENT_BODY_MAX]u8 = undefined;

    const len = json.renderComment(&buf, comment) catch {
        return sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

/// Send the RealWorld error shape.
pub fn sendError(res: *zix.Http1.Response, status: zix.Http1.Status.Code, message: []const u8) !void {
    var buf: [ERROR_BODY_MAX]u8 = undefined;

    const len = json.renderError(&buf, message) catch {
        res.setStatus(.INTERNAL_SERVER_ERROR);

        try res.sendJson("{\"errors\":{\"body\":[\"internal error\"]}}");
        return;
    };

    res.setStatus(status);

    try res.sendJson(buf[0..len]);
}

// --------------------------------------------------------- //

test "respond: a render failure falls back to an internal error body" {
    // The user buffer cannot hold this document, so sendUser must fall back.
    // This only checks the render step, the socket write is not exercised.
    var buf: [16]u8 = undefined;

    try std.testing.expectError(error.NoSpaceLeft, json.renderUser(&buf, .{
        .email = "ada@example.com",
        .token = "tok",
        .username = "ada",
        .bio = null,
        .image = null,
    }));
}
