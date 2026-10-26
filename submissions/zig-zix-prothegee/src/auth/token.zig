//! HS256 JSON web tokens for the challenge claims.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;
const jwt = zix.zwte.jwt;
const base64url = zix.zwte.base64url;

// --------------------------------------------------------- //

/// Token lifetime, 30 days.
pub const TTL_SECONDS: i64 = 30 * 24 * 60 * 60;

/// The challenge secret is 26 bytes, below the RFC default minimum.
pub const MIN_KEY_LENGTH: usize = 26;

/// Bytes one signed token may occupy.
pub const TOKEN_MAX: usize = 512;

/// Bytes one decoded payload may occupy.
pub const PAYLOAD_MAX: usize = 512;

// --------------------------------------------------------- //

pub const Error = error{
    InvalidToken,
    Expired,
};

const Claims = struct {
    sub: []const u8,
    iat: i64 = 0,
    exp: i64,
};

// --------------------------------------------------------- //

/// Sign a fresh token for `user_id` at `now`.
pub fn sign(secret: []const u8, user_id: i64, now: i64, out: []u8) ![]const u8 {
    var payload_buf: [PAYLOAD_MAX]u8 = undefined;
    const payload = try std.fmt.bufPrint(
        &payload_buf,
        "{{\"sub\":\"{d}\",\"iat\":{d},\"exp\":{d}}}",
        .{ user_id, now, now + TTL_SECONDS },
    );

    var encoded_buf: [PAYLOAD_MAX]u8 = undefined;
    const payload_b64 = try base64url.encode(payload, &encoded_buf);

    return jwt.sign(secret, payload_b64, out, .{ .min_key_length = MIN_KEY_LENGTH });
}

/// Verify a token and return its viewer user id.
///
/// Note:
/// - The signature and the `alg` field are checked by the library.
/// - `exp` and a decimal string `sub` are required here.
pub fn verify(secret: []const u8, raw_token: []const u8, now: i64, allocator: std.mem.Allocator) Error!i64 {
    var payload_buf: [PAYLOAD_MAX]u8 = undefined;
    const payload = jwt.verify(secret, raw_token, &payload_buf, .{ .min_key_length = MIN_KEY_LENGTH }) catch {
        return error.InvalidToken;
    };

    const claims = jzon.deserialize(Claims, allocator, payload, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidToken;
    };

    if (claims.exp <= now) return error.Expired;

    const user_id = std.fmt.parseInt(i64, claims.sub, 10) catch return error.InvalidToken;
    if (user_id <= 0) return error.InvalidToken;

    return user_id;
}

// --------------------------------------------------------- //

const TEST_SECRET = "multicore-server-challenge";
const TEST_NOW: i64 = 1_700_000_000;

/// Sign an arbitrary payload for the rejection cases below.
fn signPayload(secret: []const u8, payload: []const u8, out: []u8) ![]const u8 {
    var encoded_buf: [PAYLOAD_MAX]u8 = undefined;
    const payload_b64 = try base64url.encode(payload, &encoded_buf);

    return jwt.sign(secret, payload_b64, out, .{ .min_key_length = MIN_KEY_LENGTH });
}

// --------------------------------------------------------- //

test "token: sign then verify returns the same user id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try sign(TEST_SECRET, 42, TEST_NOW, &token_buf);
    const user_id = try verify(TEST_SECRET, signed, TEST_NOW, arena.allocator());

    try std.testing.expectEqual(@as(i64, 42), user_id);
}

test "token: a token from the wrong secret is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try sign(TEST_SECRET, 42, TEST_NOW, &token_buf);

    try std.testing.expectError(
        error.InvalidToken,
        verify("a-different-26-byte-secret!", signed, TEST_NOW, arena.allocator()),
    );
}

test "token: an expired token is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try sign(TEST_SECRET, 42, TEST_NOW - TTL_SECONDS - 1, &token_buf);

    try std.testing.expectError(
        error.Expired,
        verify(TEST_SECRET, signed, TEST_NOW, arena.allocator()),
    );
}

test "token: a payload without exp is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try signPayload(TEST_SECRET, "{\"sub\":\"42\",\"iat\":1700000000}", &token_buf);

    try std.testing.expectError(
        error.InvalidToken,
        verify(TEST_SECRET, signed, TEST_NOW, arena.allocator()),
    );
}

test "token: a non string sub is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try signPayload(TEST_SECRET, "{\"sub\":42,\"iat\":1700000000,\"exp\":1800000000}", &token_buf);

    try std.testing.expectError(
        error.InvalidToken,
        verify(TEST_SECRET, signed, TEST_NOW, arena.allocator()),
    );
}

test "token: a non numeric sub is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try signPayload(TEST_SECRET, "{\"sub\":\"abc\",\"iat\":1700000000,\"exp\":1800000000}", &token_buf);

    try std.testing.expectError(
        error.InvalidToken,
        verify(TEST_SECRET, signed, TEST_NOW, arena.allocator()),
    );
}

test "token: sub zero is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var token_buf: [TOKEN_MAX]u8 = undefined;

    const signed = try signPayload(TEST_SECRET, "{\"sub\":\"0\",\"iat\":1700000000,\"exp\":1800000000}", &token_buf);

    try std.testing.expectError(
        error.InvalidToken,
        verify(TEST_SECRET, signed, TEST_NOW, arena.allocator()),
    );
}

test "token: a malformed string is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(
        error.InvalidToken,
        verify(TEST_SECRET, "not-a-token", TEST_NOW, arena.allocator()),
    );
}
