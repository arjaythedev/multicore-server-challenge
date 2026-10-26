//! GET and PUT /api/user: the authenticated account.

const std = @import("std");
const zix = @import("zix");

const app = @import("../app.zig");
const clock = @import("../clock.zig");
const db = @import("../db.zig");
const auth_request = @import("../auth/request.zig");
const password = @import("../auth/password.zig");
const token = @import("../auth/token.zig");
const user_input = @import("../domain/user_input.zig");
const user_domain = @import("../domain/user.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/user";

// --------------------------------------------------------- //

fn authenticate(req: *zix.Http1.Request, ctx: *zix.Http1.Context) !auth_request.Viewer {
    return auth_request.authenticate(
        req,
        app.get().jwt_secret,
        clock.unixSeconds(ctx.io),
        ctx.allocator,
    );
}

fn get(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const viewer = authenticate(req, ctx) catch {
        try respond.sendError(res, .UNAUTHORIZED, "Unauthorized");
        return;
    };

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const found = user_domain.findById(conn, ctx.allocator, viewer.id) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };
    const user = found orelse {
        try respond.sendError(res, .UNAUTHORIZED, "Unauthorized");
        return;
    };

    try respond.sendUser(res, .{
        .email = user.email,
        .token = viewer.token,
        .username = user.username,
        .bio = user.bio,
        .image = user.image,
    }, .OK);
}

fn update(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const viewer = authenticate(req, ctx) catch {
        try respond.sendError(res, .UNAUTHORIZED, "Unauthorized");
        return;
    };

    const body = try req.body();

    const input = user_input.parseUpdate(ctx.allocator, body) catch {
        try respond.sendError(res, .UNPROCESSABLE_ENTITY, "is invalid");
        return;
    };

    var hash_buf: [password.HASH_MAX]u8 = undefined;
    var new_hash: ?[]const u8 = null;
    if (input.password) |raw| {
        new_hash = password.hash(ctx.io, ctx.allocator, raw, &hash_buf) catch {
            try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not hash password");
            return;
        };
    }

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const updated = user_domain.update(
        conn,
        ctx.allocator,
        viewer.id,
        input.email,
        input.username,
        new_hash,
        input.bio,
        input.image,
    ) catch |err| switch (err) {
        error.Duplicate => {
            try respond.sendError(res, .UNPROCESSABLE_ENTITY, "has already been taken");
            return;
        },
        else => {
            try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
            return;
        },
    };

    const user = updated orelse {
        try respond.sendError(res, .UNAUTHORIZED, "Unauthorized");
        return;
    };

    try respond.sendUser(res, .{
        .email = user.email,
        .token = viewer.token,
        .username = user.username,
        .bio = user.bio,
        .image = user.image,
    }, .OK);
}

// --------------------------------------------------------- //

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    switch (req.method()) {
        .GET => try get(req, res, ctx),
        .PUT => try update(req, res, ctx),
        else => try respond.sendError(res, .METHOD_NOT_ALLOWED, "Method Not Allowed"),
    }
}
