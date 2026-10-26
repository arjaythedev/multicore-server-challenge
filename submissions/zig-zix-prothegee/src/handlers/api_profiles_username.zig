//! GET /api/profiles/:username: one profile with the viewer's follow state.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const profile_domain = @import("../domain/profile.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/profiles/:username";

// --------------------------------------------------------- //

fn get(
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

    const username = req.pathParam("username") orelse {
        try respond.sendError(res, .NOT_FOUND, "profile not found");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const query = profile_domain.prepared(conn) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const found = query.findByUsername(ctx.allocator, viewer, username) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const profile = found orelse {
        try respond.sendError(res, .NOT_FOUND, "profile not found");
        return;
    };

    try respond.sendProfile(res, .{
        .username = profile.username,
        .bio = profile.bio,
        .image = profile.image,
        .following = profile.following,
    }, .OK);
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

    try get(req, res, ctx);
}
