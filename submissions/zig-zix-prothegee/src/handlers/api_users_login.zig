//! POST /api/users/login: exchange credentials for a token.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const password = @import("../auth/password.zig");
const token = @import("../auth/token.zig");
const user_input = @import("../domain/user_input.zig");
const user_domain = @import("../domain/user.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/users/login";

// --------------------------------------------------------- //

fn login(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const body = try req.body();

    const input = user_input.parseLogin(ctx.allocator, body) catch {
        try respond.sendError(res, .UNPROCESSABLE_ENTITY, "is invalid");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const found = user_domain.findByEmail(conn, ctx.allocator, input.email) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const account = found orelse {
        try respond.sendError(res, .UNAUTHORIZED, "invalid email or password");
        return;
    };

    password.verify(ctx.allocator, input.password, account.password_hash) catch {
        try respond.sendError(res, .UNAUTHORIZED, "invalid email or password");
        return;
    };

    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = token.sign(app.get().jwt_secret, account.id, clock.unixSeconds(ctx.io), &token_buf) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not sign token");
        return;
    };

    try respond.sendUser(res, .{
        .email = account.email,
        .token = signed,
        .username = account.username,
        .bio = account.bio,
        .image = account.image,
    }, .OK);
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() != .POST) {
        try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed");
        return;
    }

    try login(req, res, ctx);
}
