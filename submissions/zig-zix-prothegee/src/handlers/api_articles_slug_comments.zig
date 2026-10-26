//! GET and POST /api/articles/:slug/comments.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const article_domain = @import("../domain/article.zig");
const comment_domain = @import("../domain/comment.zig");
const comment_input = @import("../domain/comment_input.zig");
const comment_view = @import("../http/comment_view.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/articles/:slug/comments";

// --------------------------------------------------------- //

fn list(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const viewer = auth_request.optionalViewer(
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

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const comment_prepared = comment_domain.prepared(conn) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const comments = comment_prepared.listBySlug(ctx.allocator, viewer, slug) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    // An empty list could mean a missing article. Check only then, so the
    // common case stays one round-trip.
    if (comments.len == 0) {
        const article_prepared = article_domain.prepared(conn) catch {
            try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
            return;
        };

        const maybe_article_id = article_prepared.idBySlug(ctx.allocator, slug) catch {
            try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
            return;
        };
        if (maybe_article_id == null) {
            try respond.sendError(res, .NOT_FOUND, "article not found");
            return;
        }
    }
    const shapes = comment_view.views(ctx.allocator, comments) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
        return;
    };

    try respond.sendComments(res, shapes, .OK);
}

fn create(
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

    const body = try req.body();
    const input = comment_input.parseCreate(ctx.allocator, body) catch {
        try respond.sendError(res, .UNPROCESSABLE_ENTITY, "is invalid");
        return;
    };

    const slug = req.pathParam("slug") orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

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

    const created = comment_domain.create(conn, ctx.allocator, article_id, viewer.id, input.body) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const comment = created orelse {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    try respond.sendComment(res, comment_view.view(comment), .CREATED);
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    switch (req.method()) {
        .GET => try list(req, res, ctx),
        .POST => try create(req, res, ctx),
        else => try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed"),
    }
}
