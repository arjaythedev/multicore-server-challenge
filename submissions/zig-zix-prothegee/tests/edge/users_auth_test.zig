//! Edge tests: users and auth boundary conditions.
//!
//! These cover inputs that are valid shapes but outside the happy path: token
//! claims that must be rejected, header spellings, and body fields that the
//! parser must refuse.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const token = conduit.auth.token;
const request = conduit.auth.request;
const user_input = conduit.domain.user_input;

// --------------------------------------------------------- //

const TEST_SECRET = "multicore-server-challenge";
const TEST_NOW: i64 = 1_700_000_000;

/// Sign an arbitrary payload, so a verify boundary case does not need a signer.
fn signPayload(payload: []const u8, out: []u8) ![]const u8 {
    var encoded: [512]u8 = undefined;
    const payload_b64 = try zix.zwte.base64url.encode(payload, &encoded);

    return zix.zwte.jwt.sign(TEST_SECRET, payload_b64, out, .{ .min_key_length = token.MIN_KEY_LENGTH });
}

/// Sign a token with an arbitrary header, to exercise the header check.
fn signRaw(header: []const u8, payload: []const u8, out: []u8) ![]const u8 {
    var header_b64_buf: [256]u8 = undefined;
    const header_b64 = try zix.zwte.base64url.encode(header, &header_b64_buf);

    var payload_b64_buf: [256]u8 = undefined;
    const payload_b64 = try zix.zwte.base64url.encode(payload, &payload_b64_buf);

    const signing_len = header_b64.len + 1 + payload_b64.len;
    if (out.len < signing_len + 1 + zix.zwte.jwt.SIGNATURE_B64_LENGTH) return error.NoSpaceLeft;

    @memcpy(out[0..header_b64.len], header_b64);
    out[header_b64.len] = '.';
    @memcpy(out[header_b64.len + 1 ..][0..payload_b64.len], payload_b64);

    const signature = zix.zwte.hmac.sign(TEST_SECRET, out[0..signing_len]);
    out[signing_len] = '.';

    const signature_b64 = try zix.zwte.base64url.encode(&signature, out[signing_len + 1 ..]);

    return out[0 .. signing_len + 1 + signature_b64.len];
}

// --------------------------------------------------------- //
// token boundary cases

test "edge: a token without exp is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"sub\":\"42\",\"iat\":1700000000}", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token without sub is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"exp\":1800000000}", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with a negative sub is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"sub\":\"-1\",\"exp\":1800000000}", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with sub zero is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"sub\":\"0\",\"exp\":1800000000}", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with an overflowing sub is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"sub\":\"99999999999999999999\",\"exp\":1800000000}", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with a non HS256 alg is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signRaw("{\"alg\":\"none\",\"typ\":\"JWT\"}", "{\"sub\":\"42\",\"exp\":1800000000}", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with an empty payload is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("", &buf);

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with an empty signature is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var payload_b64_buf: [256]u8 = undefined;
    const payload_b64 = try zix.zwte.base64url.encode("{\"sub\":\"42\",\"exp\":1800000000}", &payload_b64_buf);

    var raw_buf: [512]u8 = undefined;
    const raw = try std.fmt.bufPrint(&raw_buf, "{s}.{s}.", .{ zix.zwte.jwt.HEADER_B64, payload_b64 });

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

test "edge: a token with one dot is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, "abc.def", TEST_NOW, arena.allocator()));
}

test "edge: a token with more than two dots is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidToken, token.verify(TEST_SECRET, "a.b.c.d", TEST_NOW, arena.allocator()));
}

test "edge: signing with a secret shorter than 26 bytes fails" {
    var buf: [token.TOKEN_MAX]u8 = undefined;

    try std.testing.expectError(error.KeyTooShort, token.sign("short-secret", 1, TEST_NOW, &buf));
}

test "edge: extra claims are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"sub\":\"42\",\"iat\":1700000000,\"exp\":1800000000,\"role\":\"admin\"}", &buf);

    const user_id = try token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator());
    try std.testing.expectEqual(@as(i64, 42), user_id);
}

test "edge: exp equal to now is expired" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buf: [token.TOKEN_MAX]u8 = undefined;
    const raw = try signPayload("{\"sub\":\"42\",\"exp\":1700000000}", &buf);

    try std.testing.expectError(error.Expired, token.verify(TEST_SECRET, raw, TEST_NOW, arena.allocator()));
}

// --------------------------------------------------------- //
// header boundary cases

test "edge: a tab separates the Token scheme from the token" {
    try std.testing.expectEqualStrings("abc", request.tokenFromHeader("Token\tabc").?);
}

test "edge: several spaces separate the Token scheme from the token" {
    try std.testing.expectEqualStrings("abc", request.tokenFromHeader("Token     abc").?);
}

test "edge: a lowercase scheme is accepted" {
    try std.testing.expectEqualStrings("abc", request.tokenFromHeader("token abc").?);
}

test "edge: a Bearer scheme is rejected" {
    try std.testing.expect(request.tokenFromHeader("Bearer abc") == null);
}

test "edge: a header with only the scheme is rejected" {
    try std.testing.expect(request.tokenFromHeader("Token") == null);
}

test "edge: an empty header is rejected" {
    try std.testing.expect(request.tokenFromHeader("") == null);
}

test "edge: a whitespace only header is rejected" {
    try std.testing.expect(request.tokenFromHeader("   ") == null);
}

// --------------------------------------------------------- //
// body boundary cases

test "edge: a null user wrapper is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseRegister(arena.allocator(), "{\"user\":null}"));
}

test "edge: a numeric username is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":1,\"email\":\"a@b.c\",\"password\":\"x\"}}",
    ));
}

test "edge: an object email is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":\"u\",\"email\":{},\"password\":\"x\"}}",
    ));
}

test "edge: an array password is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":\"u\",\"email\":\"a@b.c\",\"password\":[]}}",
    ));
}

test "edge: trailing bytes after the document are rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":\"u\",\"email\":\"a@b.c\",\"password\":\"x\"}} extra",
    ));
}

test "edge: an empty bio is kept as an empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try user_input.parseUpdate(arena.allocator(), "{\"user\":{\"bio\":\"\"}}");

    try std.testing.expect(input.bio != null);
    try std.testing.expectEqualStrings("", input.bio.?);
}

test "edge: an update with only unknown fields changes nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try user_input.parseUpdate(arena.allocator(), "{\"user\":{\"nope\":1}}");

    try std.testing.expect(input.email == null);
    try std.testing.expect(input.username == null);
    try std.testing.expect(input.password == null);
    try std.testing.expect(input.bio == null);
    try std.testing.expect(input.image == null);
}

test "edge: a null user wrapper in an update is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseUpdate(arena.allocator(), "{\"user\":null}"));
}

test "edge: a numeric bio is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseUpdate(arena.allocator(), "{\"user\":{\"bio\":1}}"));
}

test "edge: a login with a null email is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseLogin(
        arena.allocator(),
        "{\"user\":{\"email\":null,\"password\":\"x\"}}",
    ));
}

test "edge: a login with a numeric password is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, user_input.parseLogin(
        arena.allocator(),
        "{\"user\":{\"email\":\"a@b.c\",\"password\":1}}",
    ));
}
