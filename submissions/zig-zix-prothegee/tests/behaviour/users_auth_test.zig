//! Behaviour tests: users and auth request handling contract.
//!
//! These drive the handlers through a connected socket pair, so the status and
//! body shape are asserted on the wire. Paths that reach the database are left
//! to the integration suite.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const api_users = conduit.handlers.api_users;
const api_users_login = conduit.handlers.api_users_login;
const api_user = conduit.handlers.api_user;

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

/// Call one handler over a connected socket pair, returning the wire response.
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

/// Sign a token that authenticates user id 1 at the current time.
fn currentToken(buf: []u8) ![]const u8 {
    return token.sign(TEST_SECRET, 1, clock.unixSeconds(std.testing.io), buf);
}

// --------------------------------------------------------- //
// handler status contract

test "behaviour: POST /api/users rejects an empty body" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_users.RESPONSE, "POST /api/users HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"errors\"") != null);
}

test "behaviour: GET /api/users is method not allowed" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_users.RESPONSE, "GET /api/users HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "behaviour: POST /api/users/login rejects an empty body" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_users_login.RESPONSE, "POST /api/users/login HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"errors\"") != null);
}

test "behaviour: GET /api/users/login is method not allowed" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_users_login.RESPONSE, "GET /api/users/login HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "behaviour: GET /api/user without auth is 401" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_user.RESPONSE, "GET /api/user HTTP/1.1\r\nHost: t\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: PUT /api/user without auth is 401" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_user.RESPONSE, "PUT /api/user HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\n\r\n{}", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: POST /api/user is method not allowed" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_user.RESPONSE, "POST /api/user HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 405"));
}

test "behaviour: GET /api/user with a Bearer header is 401" {
    var out: [1024]u8 = undefined;

    const resp = try call(api_user.RESPONSE, "GET /api/user HTTP/1.1\r\nHost: t\r\nAuthorization: Bearer abc\r\n\r\n", &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: GET /api/user with an expired token is 401" {
    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const expired = try token.sign(TEST_SECRET, 1, 0, &token_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "GET /api/user HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\n\r\n",
        .{expired},
    );

    var out: [1024]u8 = undefined;
    const resp = try call(api_user.RESPONSE, raw, &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: GET /api/user with a sub zero token is 401" {
    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const zero_sub = try token.sign(TEST_SECRET, 0, clock.unixSeconds(std.testing.io), &token_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "GET /api/user HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\n\r\n",
        .{zero_sub},
    );

    var out: [1024]u8 = undefined;
    const resp = try call(api_user.RESPONSE, raw, &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 401"));
}

test "behaviour: PUT /api/user with a valid token and an invalid body is 422" {
    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = try currentToken(&token_buf);

    const body = "{}";
    var raw_buf: [1024]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "PUT /api/user HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ signed, body.len, body },
    );

    var out: [1024]u8 = undefined;
    const resp = try call(api_user.RESPONSE, raw, &out);

    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 422"));
}

// --------------------------------------------------------- //
// token contract

test "behaviour: a signed token verifies to the same user id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const now = clock.unixSeconds(std.testing.io);
    const signed = try token.sign(TEST_SECRET, 7, now, &token_buf);

    const user_id = try token.verify(TEST_SECRET, signed, now, arena.allocator());
    try std.testing.expectEqual(@as(i64, 7), user_id);
}

test "behaviour: the token lifetime is 30 days" {
    try std.testing.expectEqual(@as(i64, 30 * 24 * 60 * 60), token.TTL_SECONDS);
}

test "behaviour: a token one second before expiry is valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const now = clock.unixSeconds(std.testing.io);
    const signed = try token.sign(TEST_SECRET, 7, now, &token_buf);

    const user_id = try token.verify(TEST_SECRET, signed, now + token.TTL_SECONDS - 1, arena.allocator());
    try std.testing.expectEqual(@as(i64, 7), user_id);
}

test "behaviour: a token at its expiry instant is expired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const now = clock.unixSeconds(std.testing.io);
    const signed = try token.sign(TEST_SECRET, 7, now, &token_buf);

    try std.testing.expectError(
        error.Expired,
        token.verify(TEST_SECRET, signed, now + token.TTL_SECONDS, arena.allocator()),
    );
}
