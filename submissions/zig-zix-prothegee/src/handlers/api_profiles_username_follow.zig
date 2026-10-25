const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// RESERVED: private region

// --------------------------------------------------------- //

pub const PATH = "/api/profiles/:username/follow";

pub fn RESPONSE(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    _ = ctx;

    if (req.method() != .POST or req.method() != .DELETE) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson(zix.Http1.Status.Code.METHOD_NOT_ALLOWED.asString());
        return;
    }

    var buf: [64]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "TODO: {s}", .{PATH});

    try zix.Http1.sendSimpleFD(req.fd, 200, "tex/plain", body);
}
