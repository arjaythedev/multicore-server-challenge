//! POST /api/users: register a new account.

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

pub const PATH = "/api/users";

// --------------------------------------------------------- //

fn register(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const body = try req.body();

    const input = user_input.parseRegister(ctx.allocator, body) catch {
        try respond.sendError(res, .UNPROCESSABLE_ENTITY, "is invalid");
        return;
    };

    var hash_buf: [password.HASH_MAX]u8 = undefined;
    const password_hash = password.hash(ctx.io, ctx.allocator, input.password, &hash_buf) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not hash password");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const user = user_domain.insert(conn, ctx.allocator, input.username, input.email, password_hash) catch |err| switch (err) {
        error.Duplicate => {
            try respond.sendError(res, .UNPROCESSABLE_ENTITY, "has already been taken");
            return;
        },
        else => {
            try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
            return;
        },
    };

    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = token.sign(app.get().jwt_secret, user.id, clock.unixSeconds(ctx.io), &token_buf) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not sign token");
        return;
    };

    try respond.sendUser(res, .{
        .email = user.email,
        .token = signed,
        .username = user.username,
        .bio = user.bio,
        .image = user.image,
    }, .CREATED);
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

    try register(req, res, ctx);
}
