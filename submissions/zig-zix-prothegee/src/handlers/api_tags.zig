//! GET /api/tags: the tag list, served through the L1 response cache.

const std = @import("std");
const zix = @import("zix");

const db = @import("../db.zig");
const tag_domain = @import("../domain/tag.zig");
const json = @import("../http/json.zig");
const respond = @import("../http/respond.zig");

// --------------------------------------------------------- //

pub const PATH = "/api/tags";

/// Freshness of one cached tag list. Tags change only when an article adds a
/// new name, so a short window keeps the list current.
const CACHE_TTL_MS: u32 = 2_000;

/// Room for 200 tag names. The seed has 200, an article adds at most a few.
const BODY_MAX: usize = 16 * 1024;

// --------------------------------------------------------- //

fn serve(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (res.sendFromCache(req)) return;

    const conn = db.conn() catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database unavailable");
        return;
    };

    const names = tag_domain.list(conn, ctx.allocator) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "database error");
        return;
    };

    var buf: [BODY_MAX]u8 = undefined;
    const len = json.renderTags(&buf, names) catch {
        try respond.sendError(res, .INTERNAL_SERVER_ERROR, "could not render response");
        return;
    };

    res.setStatus(.OK);
    res.setContentType(.APPLICATION_JSON);

    try res.sendCached(req, buf[0..len], CACHE_TTL_MS);
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

    try serve(req, res, ctx);
}
