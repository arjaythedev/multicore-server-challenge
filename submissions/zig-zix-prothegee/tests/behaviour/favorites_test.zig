//! Behaviour tests: favorites request handling contract.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const api_articles_slug_favorite = conduit.handlers.api_articles_slug_favorite;
const app = conduit.app;
const clock = conduit.clock;
const token = conduit.auth.token;

// --------------------------------------------------------- //

const TEST_SECRET = "multicore-server-challenge";

fn configure() void {
    app.init(.{
        .database_url = "postgres://conduit:conduit@127.0.0.1:5432/conduit",
        .jwt_secret = TEST_SECRET,
        .host = "127.0.0.1",
        .port = 3000,
    });
}

fn currentToken(buf: []u8) ![]const u8 {
    return token.sign(TEST_SECRET, 1, clock.unixSeconds(std.testing.io), buf);
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

test "behaviour: POST favorite without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_slug_favorite.RESPONSE,
        "POST /api/articles/hello/favorite HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: DELETE favorite without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_slug_favorite.RESPONSE,
        "DELETE /api/articles/hello/favorite HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: GET favorite is method not allowed" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_slug_favorite.RESPONSE,
        "GET /api/articles/hello/favorite HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "behaviour: POST favorite with a token and no path is 404" {
    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = try currentToken(&token_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "POST /api/articles/hello/favorite HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\nContent-Length: 0\r\n\r\n",
        .{signed},
    );

    var out: [512]u8 = undefined;
    const resp = try call(api_articles_slug_favorite.RESPONSE, raw, &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 404"));
}
