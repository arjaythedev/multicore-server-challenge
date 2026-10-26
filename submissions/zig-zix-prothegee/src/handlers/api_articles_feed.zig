//! GET /api/articles/feed: the viewer's feed.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const article_domain = @import("../domain/article.zig");
const article_view = @import("../http/article_view.zig");
const paging = @import("../http/paging.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/articles/feed";

// --------------------------------------------------------- //

fn feed(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const viewer = auth_request.authenticate(
        req,
        app.get().jwt_secret,
        clock.unixSeconds(ctx.io),
        ctx.allocator,
    ) catch {
        try respond.sendError(res, .UNAUTHORIZED, "Unauthorized");
        return;
    };

    const page_params = paging.parse(req.queryParam("limit"), req.queryParam("offset")) catch {
        try respond.sendError(res, .UNPROCESSABLE_ENTITY, "invalid paging");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const prepared = article_domain.prepared(conn) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const page = prepared.feed(
        ctx.allocator,
        viewer.id,
        page_params.limit,
        page_params.offset,
    ) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const summaries = article_view.summaries(ctx.allocator, page.articles) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
        return;
    };

    try respond.sendArticles(res, summaries, page.count, .OK);
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() != .GET) {
        try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed");
        return;
    }

    try feed(req, res, ctx);
}
