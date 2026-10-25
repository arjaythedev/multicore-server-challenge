const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

fn processGet(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    _ = res;
    _ = ctx;

    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "TODO: {s} ({s})", .{ PATH, "GET" });

    try zix.Http1.sendSimpleFD(req.fd, 200, "tex/plain", body);
}

fn processPut(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    _ = res;
    _ = ctx;

    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "TODO: {s} ({s})", .{ PATH, "PUT" });

    try zix.Http1.sendSimpleFD(req.fd, 200, "tex/plain", body);
}

// --------------------------------------------------------- //

pub const PATH = "/api/users";

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    switch (req.method()) {
        .GET => {
            try processGet(req, res, ctx);
        },
        .PUT => {
            try processPut(req, res, ctx);
        },
        else => {
            res.setStatus(.METHOD_NOT_ALLOWED);

            try res.sendJson(zix.Http1.Status.Code.METHOD_NOT_ALLOWED.asString());
        },
    }
}
