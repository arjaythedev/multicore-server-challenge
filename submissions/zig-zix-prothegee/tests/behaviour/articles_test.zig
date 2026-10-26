//! Behaviour tests: articles request handling contract.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const api_articles = conduit.handlers.api_articles;
const api_articles_feed = conduit.handlers.api_articles_feed;
const api_articles_slug = conduit.handlers.api_articles_slug;
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
// list paging and auth
// --------------------------------------------------------- //

test "behaviour: GET /api/articles with an invalid token is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles.RESPONSE,
        "GET /api/articles HTTP/1.1\r\nHost: t\r\nAuthorization: Token bad\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: GET /api/articles rejects a zero limit" {
    var out: [512]u8 = undefined;

    const resp = try call(api_articles.RESPONSE, "GET /api/articles?limit=0 HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

test "behaviour: GET /api/articles rejects a limit above 100" {
    var out: [512]u8 = undefined;

    const resp = try call(api_articles.RESPONSE, "GET /api/articles?limit=101 HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

test "behaviour: GET /api/articles rejects a negative offset" {
    var out: [512]u8 = undefined;

    const resp = try call(api_articles.RESPONSE, "GET /api/articles?offset=-1 HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

test "behaviour: GET /api/articles rejects a non-numeric limit" {
    var out: [512]u8 = undefined;

    const resp = try call(api_articles.RESPONSE, "GET /api/articles?limit=ten HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

// --------------------------------------------------------- //
// feed auth and paging
// --------------------------------------------------------- //

test "behaviour: GET /api/articles/feed without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_feed.RESPONSE,
        "GET /api/articles/feed HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: GET /api/articles/feed rejects invalid paging with a token" {
    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = try currentToken(&token_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "GET /api/articles/feed?limit=0 HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\n\r\n",
        .{signed},
    );

    var out: [512]u8 = undefined;
    const resp = try call(api_articles_feed.RESPONSE, raw, &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

// --------------------------------------------------------- //
// create, update, delete auth and body
// --------------------------------------------------------- //

test "behaviour: POST /api/articles without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles.RESPONSE,
        "POST /api/articles HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: POST /api/articles with a token and an empty body is 422" {
    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = try currentToken(&token_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "POST /api/articles HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\nContent-Length: 0\r\n\r\n",
        .{signed},
    );

    var out: [512]u8 = undefined;
    const resp = try call(api_articles.RESPONSE, raw, &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

test "behaviour: PUT /api/articles/:slug without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_slug.RESPONSE,
        "PUT /api/articles/hello HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: DELETE /api/articles/:slug without auth is 401" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_slug.RESPONSE,
        "DELETE /api/articles/hello HTTP/1.1\r\nHost: t\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: POST on the slug path is method not allowed" {
    var out: [512]u8 = undefined;

    const resp = try call(
        api_articles_slug.RESPONSE,
        "POST /api/articles/hello HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n",
        &out,
    );

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}
