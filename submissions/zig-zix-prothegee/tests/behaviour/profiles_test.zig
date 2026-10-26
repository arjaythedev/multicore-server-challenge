//! Behaviour tests: profiles request handling contract.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const api_profiles_username = conduit.handlers.api_profiles_username;
const api_profiles_username_follow = conduit.handlers.api_profiles_username_follow;
const app = conduit.app;

// --------------------------------------------------------- //

fn configure() void {
    app.init(.{
        .database_url = "postgres://conduit:conduit@127.0.0.1:5432/conduit",
        .jwt_secret = "multicore-server-challenge",
        .host = "127.0.0.1",
        .port = 3000,
    });
}

fn call(handler: zix.Http1.HandlerFn, raw: []const u8, out: []u8) ![]const u8 {
    configure();

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

test "behaviour: GET profile with an invalid token is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_profiles_username.RESPONSE,
        "GET /api/profiles/ada HTTP/1.1\r\nHost: t\r\nAuthorization: Token bad\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: POST follow without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_profiles_username_follow.RESPONSE,
        "POST /api/profiles/ada/follow HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: DELETE follow without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_profiles_username_follow.RESPONSE,
        "DELETE /api/profiles/ada/follow HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: PUT profile is method not allowed" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_profiles_username.RESPONSE,
        "PUT /api/profiles/ada HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "behaviour: GET on the follow path is method not allowed" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_profiles_username_follow.RESPONSE,
        "GET /api/profiles/ada/follow HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}
