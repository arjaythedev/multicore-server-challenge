//! GET /api/tags: the tag list.

const zix = @import("zix");

const db = @import("../db.zig");
const tag_domain = @import("../domain/tag.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/tags";

// --------------------------------------------------------- //

fn list(
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const query = tag_domain.prepared(conn) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    const names = query.list(ctx.allocator) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    try respond.sendTags(res, names, .OK);
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

    try list(res, ctx);
}
