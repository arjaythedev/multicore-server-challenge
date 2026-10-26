//! POST and DELETE /api/profiles/:username/follow.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const profile_domain = @import("../domain/profile.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/profiles/:username/follow";

const Action = enum { FOLLOW, UNFOLLOW };

// --------------------------------------------------------- //

fn apply(
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
    viewer: i64,
    username: []const u8,
    action: Action,
) !void {
    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const result = if (action == .FOLLOW)
        profile_domain.follow(conn, ctx.allocator, viewer, username)
    else
        profile_domain.unfollow(conn, ctx.allocator, viewer, username);

    const found = result catch {
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

    const username = req.pathParam("username") orelse {
        try respond.sendError(res, .NOT_FOUND, "profile not found");
        return;
    };

    const action: Action = if (method == .POST) .FOLLOW else .UNFOLLOW;

    try apply(res, ctx, viewer.id, username, action);
}
