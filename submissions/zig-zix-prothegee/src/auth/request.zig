//! Authorization header handling for the request path.

const std = @import("std");
const zix = @import("zix");

const token = @import("token.zig");

// --------------------------------------------------------- //

pub const Viewer = struct {
    id: i64,
    token: []const u8,
};

pub const Error = error{Unauthorized};

// --------------------------------------------------------- //

/// Extract the raw token from a `Token <jwt>` header value.
pub fn tokenFromHeader(header: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, header, " \t");

    var split: usize = 0;
    while (split < trimmed.len and !std.ascii.isWhitespace(trimmed[split])) split += 1;
    if (split == 0 or split == trimmed.len) return null;

    if (!std.ascii.eqlIgnoreCase(trimmed[0..split], "Token")) return null;

    const raw = std.mem.trim(u8, trimmed[split..], " \t");
    if (raw.len == 0) return null;

    return raw;
}

/// Verify the request token and return the viewer.
pub fn authenticate(
    req: *zix.Http1.Request,
    secret: []const u8,
    now: i64,
    allocator: std.mem.Allocator,
) Error!Viewer {
    const header = req.header("authorization") orelse return error.Unauthorized;
    const raw = tokenFromHeader(header) orelse return error.Unauthorized;

    const user_id = token.verify(secret, raw, now, allocator) catch return error.Unauthorized;

    return .{ .id = user_id, .token = raw };
}

/// Verify the request token when one is present, returning 0 for anonymous.
///
/// Note:
/// - A missing header is anonymous.
/// - A header that is present but malformed or invalid is an error.
pub fn optionalViewer(
    req: *zix.Http1.Request,
    secret: []const u8,
    now: i64,
    allocator: std.mem.Allocator,
) Error!i64 {
    const header = req.header("authorization") orelse return 0;
    const raw = tokenFromHeader(header) orelse return error.Unauthorized;

    return token.verify(secret, raw, now, allocator) catch return error.Unauthorized;
}

// --------------------------------------------------------- //

test "request: a Token header yields the raw token" {
    try std.testing.expectEqualStrings("abc.def.ghi", tokenFromHeader("Token abc.def.ghi").?);
}

test "request: the scheme is case insensitive" {
    try std.testing.expectEqualStrings("abc", tokenFromHeader("token abc").?);
}

test "request: surrounding whitespace is trimmed" {
    try std.testing.expectEqualStrings("abc", tokenFromHeader("  Token   abc   ").?);
}

test "request: a Bearer header is rejected" {
    try std.testing.expect(tokenFromHeader("Bearer abc") == null);
}

test "request: a header without a token is rejected" {
    try std.testing.expect(tokenFromHeader("Token") == null);
    try std.testing.expect(tokenFromHeader("Token   ") == null);
}

test "request: an empty header is rejected" {
    try std.testing.expect(tokenFromHeader("") == null);
}

test "request: a tab separator is accepted" {
    try std.testing.expectEqualStrings("abc", tokenFromHeader("Token\tabc").?);
}

// --------------------------------------------------------- //

const TEST_SECRET = "multicore-server-challenge";
const TEST_NOW: i64 = 1_700_000_000;

test "request: optionalViewer returns zero without a header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = "GET /api/profiles/ada HTTP/1.1\r\nHost: t\r\n\r\n";
    var req = try zix.Http1.Request.fromRaw(raw, arena.allocator());

    const viewer = try optionalViewer(&req, TEST_SECRET, TEST_NOW, arena.allocator());

    try std.testing.expectEqual(@as(i64, 0), viewer);
}

test "request: optionalViewer rejects an invalid header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const raw = "GET /api/profiles/ada HTTP/1.1\r\nHost: t\r\nAuthorization: Token bad\r\n\r\n";
    var req = try zix.Http1.Request.fromRaw(raw, arena.allocator());

    try std.testing.expectError(
        error.Unauthorized,
        optionalViewer(&req, TEST_SECRET, TEST_NOW, arena.allocator()),
    );
}

test "request: optionalViewer returns the token user id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var token_buf: [token.TOKEN_MAX]u8 = undefined;
    const signed = try token.sign(TEST_SECRET, 7, TEST_NOW, &token_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(
        &raw_buf,
        "GET /api/profiles/ada HTTP/1.1\r\nHost: t\r\nAuthorization: Token {s}\r\n\r\n",
        .{signed},
    );
    var req = try zix.Http1.Request.fromRaw(raw, arena.allocator());

    const viewer = try optionalViewer(&req, TEST_SECRET, TEST_NOW, arena.allocator());

    try std.testing.expectEqual(@as(i64, 7), viewer);
}
