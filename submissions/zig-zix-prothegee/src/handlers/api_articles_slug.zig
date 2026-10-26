//! GET, PUT, and DELETE /api/articles/:slug.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const article_domain = @import("../domain/article.zig");
const article_input = @import("../domain/article_input.zig");
const article_view = @import("../http/article_view.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/articles/:slug";

// --------------------------------------------------------- //

fn detail(
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

    const prepared = article_domain.prepared(conn) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const found = prepared.findBySlug(ctx.allocator, viewer, slug) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const article = found orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    try respond.sendArticle(res, article_view.full(article), .OK);
}

fn update(
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

    const slug = req.pathParam("slug") orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    const body = try req.body();
    const input = article_input.parseUpdate(ctx.allocator, body) catch {
        try respond.sendError(res, .UNPROCESSABLE_ENTITY, "is invalid");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const maybe_owner = article_domain.ownerBySlug(conn, ctx.allocator, slug) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const owner = maybe_owner orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    if (owner.author_id != viewer.id) {
        try respond.sendError(res, .FORBIDDEN, "not the author");
        return;
    }

    const updated = article_domain.update(
        conn,
        ctx.allocator,
        owner.id,
        viewer.id,
        input.title,
        input.description,
        input.body,
    ) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const article = updated orelse {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    try respond.sendArticle(res, article_view.full(article), .OK);
}

fn delete(
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

    const slug = req.pathParam("slug") orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const maybe_owner = article_domain.ownerBySlug(conn, ctx.allocator, slug) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const owner = maybe_owner orelse {
        try respond.sendError(res, .NOT_FOUND, "article not found");
        return;
    };

    if (owner.author_id != viewer.id) {
        try respond.sendError(res, .FORBIDDEN, "not the author");
        return;
    }

    article_domain.delete(conn, owner.id) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    try res.sendNoContent();
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    switch (req.method()) {
        .GET => try detail(req, res, ctx),
        .PUT => try update(req, res, ctx),
        .DELETE => try delete(req, res, ctx),
        else => try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed"),
    }
}
