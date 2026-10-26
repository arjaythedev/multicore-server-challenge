//! POST and DELETE /api/articles/:slug/favorite.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const article_domain = @import("../domain/article.zig");
const favorite_domain = @import("../domain/favorite.zig");
const article_view = @import("../http/article_view.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/articles/:slug/favorite";

const Action = enum { ADD, REMOVE };

// --------------------------------------------------------- //

fn apply(
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
    viewer: i64,
    slug: []const u8,
    action: Action,
) !void {
    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const maybe_article_id = article_domain.idBySlug(conn, ctx.allocator, slug) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const article_id = maybe_article_id orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    const changed = if (action == .ADD)
        favorite_domain.add(conn, viewer, article_id)
    else
        favorite_domain.remove(conn, viewer, article_id);

    changed catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const found = article_domain.findById(conn, ctx.allocator, viewer, article_id) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const article = found orelse {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    try respond.sendArticle(res, article_view.full(article), .OK);
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const method = req.method();
    if (method != .POST and method != .DELETE) {
        try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed");
        return;
    }

    const viewer = auth_request.authenticate(
        req,
        app.get().jwt_secret,
        clock.unixSeconds(ctx.io),
        ctx.allocator,
    ) catch {
        try respond.sendError(res, .UNAUTHORIZED, "Unauthorized");
        return;
    };

    const slug = req.pathParam("slug") orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    const action: Action = if (method == .POST) .ADD else .REMOVE;

    try apply(res, ctx, viewer.id, slug, action);
}
