//! DELETE /api/articles/:slug/comments/:id.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const comment_domain = @import("../domain/comment.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/articles/:slug/comments/:id";

// --------------------------------------------------------- //

fn remove(
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

    const raw_id = req.pathParam("id") orelse {
        try respond.sendError(res, .NOT_FOUND, "comment not found");
        return;
    };

    const id = std.fmt.parseInt(i64, raw_id, 10) catch {
        try respond.sendError(res, .NOT_FOUND, "comment not found");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const maybe_author_id = comment_domain.ownerBySlugAndId(conn, ctx.allocator, slug, id) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const author_id = maybe_author_id orelse {
        try respond.sendError(res, .NOT_FOUND, "comment not found");
        return;
    };

    if (author_id != viewer.id) {
        try respond.sendError(res, .FORBIDDEN, "not the author");
        return;
    }

    comment_domain.delete(conn, id) catch {
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
    if (req.method() != .DELETE) {
        try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed");
        return;
    }

    try remove(req, res, ctx);
}
