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
