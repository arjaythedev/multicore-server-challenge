const std = @import("std");
const base64 = std.base64.url_safe_no_pad;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;

pub const lifetime = 30 * 24 * 60 * 60;
pub const max_token = 4096;

fn encode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, base64.Encoder.calcSize(bytes.len));
    return base64.Encoder.encode(out, bytes);
}

pub fn issue(allocator: std.mem.Allocator, secret: []const u8, id: []const u8, now: i64) ![]const u8 {
    const header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
    const claims = try std.json.Stringify.valueAlloc(allocator, .{ .sub = id, .iat = now, .exp = now + lifetime }, .{});
    const payload = try encode(allocator, claims);
    const message = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header, payload });
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, message, secret);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ message, try encode(allocator, &mac) });
}

fn decode(buffer: []u8, text: []const u8) ![]const u8 {
    const len = try base64.Decoder.calcSizeForSlice(text);
    if (len > buffer.len) return error.InvalidToken;
    try base64.Decoder.decode(buffer[0..len], text);
    return buffer[0..len];
}

pub const Identity = struct { id: i64, token: []const u8 };

pub fn verify(allocator: std.mem.Allocator, secret: []const u8, authorization: ?[]const u8, now: i64) !Identity {
    const header_value = authorization orelse return error.InvalidToken;
    if (!std.mem.startsWith(u8, header_value, "Token ")) return error.InvalidToken;
    const token = header_value[6..];
    if (token.len == 0 or token.len > max_token) return error.InvalidToken;
    var parts = std.mem.splitScalar(u8, token, '.');
    const header = parts.next().?;
    const claims = parts.next() orelse return error.InvalidToken;
    const signature = parts.next() orelse return error.InvalidToken;
    if (parts.next() != null) return error.InvalidToken;
    var actual: [Hmac.mac_length]u8 = undefined;
    if ((try decode(&actual, signature)).len != actual.len) return error.InvalidToken;
    var expected: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&expected, token[0 .. header.len + 1 + claims.len], secret);
    if (!std.crypto.timing_safe.eql(@TypeOf(actual), actual, expected)) return error.InvalidToken;
    var header_buffer: [512]u8 = undefined;
    const parsed_header = try std.json.parseFromSlice(std.json.Value, allocator, try decode(&header_buffer, header), .{});
    defer parsed_header.deinit();
    if (parsed_header.value != .object) return error.InvalidToken;
    const alg = parsed_header.value.object.get("alg") orelse return error.InvalidToken;
    if (alg != .string or !std.mem.eql(u8, alg.string, "HS256")) return error.InvalidToken;
    var claims_buffer: [max_token]u8 = undefined;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, try decode(&claims_buffer, claims), .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToken;
    const exp = parsed.value.object.get("exp") orelse return error.InvalidToken;
    if (exp != .integer or exp.integer <= now) return error.InvalidToken;
    if (parsed.value.object.get("iat")) |iat| if (iat != .integer) return error.InvalidToken;
    const sub = parsed.value.object.get("sub") orelse return error.InvalidToken;
    if (sub != .string or sub.string.len == 0) return error.InvalidToken;
    for (sub.string) |ch| if (ch < '0' or ch > '9') return error.InvalidToken;
    const id = std.fmt.parseInt(i64, sub.string, 10) catch return error.InvalidToken;
    if (id <= 0) return error.InvalidToken;
    return .{ .id = id, .token = token };
}

test "HS256 round trip, expiry, signature and exact scheme" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const token = try issue(a, "secret", "42", 1000);
    const header = try std.fmt.allocPrint(a, "Token {s}", .{token});
    try std.testing.expectEqual(@as(i64, 42), (try verify(a, "secret", header, 1001)).id);
    try std.testing.expectError(error.InvalidToken, verify(a, "wrong", header, 1001));
    try std.testing.expectError(error.InvalidToken, verify(a, "secret", header, 1000 + lifetime));
    try std.testing.expectError(error.InvalidToken, verify(a, "secret", token, 1001));
}
