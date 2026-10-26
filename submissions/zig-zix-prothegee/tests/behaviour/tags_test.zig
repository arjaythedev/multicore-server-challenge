//! Behaviour tests: tags request handling contract.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const api_tags = conduit.handlers.api_tags;

// --------------------------------------------------------- //

fn call(handler: zix.Http1.HandlerFn, raw: []const u8, out: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var pair = try zix.utils.socket_pair.Pair.open(std.testing.allocator);
    defer pair.deinit();

    var req = try zix.Http1.Request.fromRaw(raw, allocator);
    req.fd = pair.fds[1];

    var res = zix.Http1.Response.init(pair.fds[1], std.testing.io, allocator);
    var ctx = zix.Http1.Context.init(std.testing.io, allocator, pair.fds[1]);

    handler(&req, &res, &ctx) catch {};

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pair.fds[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&poll_fds, 2_000) catch 0;
    if (ready == 0) return out[0..0];

    const len = try zix.utils.fd_io.readOnce(pair.fds[0], out);

    return out[0..len];
}

// --------------------------------------------------------- //

test "behaviour: POST /api/tags is method not allowed" {
    var out: [512]u8 = undefined;

    const resp = try call(api_tags.RESPONSE, "POST /api/tags HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "behaviour: PUT /api/tags is method not allowed" {
    var out: [512]u8 = undefined;

    const resp = try call(api_tags.RESPONSE, "PUT /api/tags HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}
