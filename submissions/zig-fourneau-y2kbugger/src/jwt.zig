//! HS256 JSON Web Tokens: verified on every request (the header says
//! HS256, the signature matches, `exp` is a number in the future, `nbf` if
//! present is past, `sub` a decimal string), and issued at login. The
//! secret's HMAC pads are computed once (`Key`); nothing about a token is
//! remembered.

const std = @import("std");
const assert = std.debug.assert;

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const base64 = std.base64.url_safe_no_pad;

pub const ttl_s = 30 * 24 * 3600;

/// The secret, as HMAC's state after its inner pad: copied per token.
pub const Key = struct {
    hmac: Hmac,

    pub fn init(secret: []const u8) Key {
        return .{ .hmac = .init(secret) };
    }
};

const segment_bytes_max = 1024;
pub const memory_bytes = 3 * segment_bytes_max + 4096;

/// The token's user id, or null: malformed, not HS256, a bad signature,
/// expired, not yet valid, or a `sub` that is not a positive decimal.
pub fn verify(key: *const Key, token: []const u8, now_s: i64, memory: []u8) ?i64 {
    assert(memory.len >= memory_bytes);
    const dot_1 = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const dot_2 = std.mem.indexOfScalarPos(u8, token, dot_1 + 1, '.') orelse return null;
    const signature_text = token[dot_2 + 1 ..];
    if (std.mem.indexOfScalar(u8, signature_text, '.') != null) return null;

    var signature: [Hmac.mac_length]u8 = undefined;
    const signature_bytes = base64.Decoder.calcSizeForSlice(signature_text) catch return null;
    if (signature_bytes != signature.len) return null;
    base64.Decoder.decode(&signature, signature_text) catch return null;
    var expected: [Hmac.mac_length]u8 = undefined;
    var hmac = key.hmac;
    hmac.update(token[0..dot_2]);
    hmac.final(&expected);
    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, signature, expected)) return null;

    const header = decode(token[0..dot_1], memory[0..segment_bytes_max]) orelse return null;
    const payload = decode(token[dot_1 + 1 .. dot_2], memory[segment_bytes_max..][0..segment_bytes_max]) orelse
        return null;
    const scratch = memory[2 * segment_bytes_max ..];
    if (!header_is_hs256(header, scratch)) return null;
    return subject(payload, now_s, scratch);
}

fn decode(text: []const u8, buffer: []u8) ?[]const u8 {
    const size = base64.Decoder.calcSizeForSlice(text) catch return null;
    if (size > buffer.len) return null;
    base64.Decoder.decode(buffer[0..size], text) catch return null;
    return buffer[0..size];
}

fn header_is_hs256(header: []const u8, memory: []u8) bool {
    var fixed: std.heap.FixedBufferAllocator = .init(memory);
    const gpa = fixed.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(gpa, header);
    var algorithm: ?[]const u8 = null;
    if ((scanner.next() catch return false) != .object_begin) return false;
    // Bounded: each pass consumes a key and its value from a finite input.
    for (0..header.len + 1) |_| {
        const name = switch (scanner.nextAlloc(gpa, .alloc_if_needed) catch return false) {
            .object_end => break,
            .string => |text| text,
            .allocated_string => |text| text,
            else => return false,
        };
        if (!std.mem.eql(u8, name, "alg")) {
            scanner.skipValue() catch return false;
            continue;
        }
        algorithm = switch (scanner.nextAlloc(gpa, .alloc_if_needed) catch return false) {
            .string => |text| text,
            .allocated_string => |text| text,
            else => return false,
        };
    } else unreachable;
    if ((scanner.next() catch return false) != .end_of_document) return false;
    return std.mem.eql(u8, algorithm orelse return false, "HS256");
}

const Claim = enum { sub, exp, nbf, other };

fn subject(payload: []const u8, now_s: i64, memory: []u8) ?i64 {
    var fixed: std.heap.FixedBufferAllocator = .init(memory);
    const gpa = fixed.allocator();
    var scanner: std.json.Scanner = .initCompleteInput(gpa, payload);
    var sub: ?[]const u8 = null;
    var exp: ?f64 = null;
    var nbf: ?f64 = null;
    if ((scanner.next() catch return null) != .object_begin) return null;
    // Bounded: each pass consumes a key and its value from a finite input.
    for (0..payload.len + 1) |_| {
        const name = switch (scanner.nextAlloc(gpa, .alloc_if_needed) catch return null) {
            .object_end => break,
            .string => |text| text,
            .allocated_string => |text| text,
            else => return null,
        };
        const claim = std.meta.stringToEnum(Claim, name) orelse .other;
        if (claim == .other) {
            scanner.skipValue() catch return null;
            continue;
        }
        const token = scanner.nextAlloc(gpa, .alloc_if_needed) catch return null;
        switch (claim) {
            // A registered claim of the wrong type fails the token, as
            // golang-jwt's does.
            .sub => sub = switch (token) {
                .string => |text| text,
                .allocated_string => |text| text,
                else => return null,
            },
            .exp, .nbf => {
                const text = switch (token) {
                    .number => |text| text,
                    .allocated_number => |text| text,
                    else => return null,
                };
                const value = std.fmt.parseFloat(f64, text) catch return null;
                if (claim == .exp) exp = value else nbf = value;
            },
            .other => unreachable,
        }
    } else unreachable;
    if ((scanner.next() catch return null) != .end_of_document) return null;
    const now: f64 = @floatFromInt(now_s);
    if (!((exp orelse return null) > now)) return null;
    if (nbf) |not_before| if (now < not_before) return null;
    return positive_integer(sub orelse return null);
}

/// Digits only, no sign, greater than 0, within an i64.
pub fn positive_integer(text: []const u8) ?i64 {
    const value = unsigned_integer(text) orelse return null;
    if (value == 0) return null;
    return value;
}

/// Digits only (leading zeros allowed), no sign, within an i64.
pub fn unsigned_integer(text: []const u8) ?i64 {
    if (text.len == 0) return null;
    var value: i64 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = std.math.mul(i64, value, 10) catch return null;
        value = std.math.add(i64, value, byte - '0') catch return null;
    }
    return value;
}

pub const token_bytes_max = 256;

/// `{"alg":"HS256","typ":"JWT"}` in base64url (a test checks it).
const header_text = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

test "jwt: the header's text is its JSON encoded" {
    var buffer: [64]u8 = undefined;
    const encoded = base64.Encoder.encode(&buffer, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}");
    try testing.expectEqualStrings(header_text, encoded);
}

/// `{"alg":"HS256","typ":"JWT"}` and `{"sub":"<id>","iat":now,"exp":now+30d}`.
pub fn issue(key: *const Key, user_id: i64, now_s: i64, out: *[token_bytes_max]u8) []const u8 {
    assert(user_id > 0);
    const header = header_text;
    var payload_buffer: [96]u8 = undefined;
    const payload = std.fmt.bufPrint(&payload_buffer, "{{\"sub\":\"{d}\",\"iat\":{d},\"exp\":{d}}}", .{
        user_id, now_s, now_s + ttl_s,
    }) catch unreachable;
    var used: usize = 0;
    @memcpy(out[0..header.len], header);
    used += header.len;
    out[used] = '.';
    used += 1;
    used += base64.Encoder.encode(out[used..], payload).len;
    var mac: [Hmac.mac_length]u8 = undefined;
    var hmac = key.hmac;
    hmac.update(out[0..used]);
    hmac.final(&mac);
    out[used] = '.';
    used += 1;
    used += base64.Encoder.encode(out[used..], &mac).len;
    return out[0..used];
}

const testing = std.testing;

fn sign(buffer: []u8, secret: []const u8, header: []const u8, payload: []const u8) []const u8 {
    const encoder = base64.Encoder;
    var used: usize = 0;
    used += encoder.encode(buffer[used..], header).len;
    buffer[used] = '.';
    used += 1;
    used += encoder.encode(buffer[used..], payload).len;
    var mac: [Hmac.mac_length]u8 = undefined;
    Hmac.create(&mac, buffer[0..used], secret);
    buffer[used] = '.';
    used += 1;
    used += encoder.encode(buffer[used..], &mac).len;
    return buffer[0..used];
}

test "jwt: the conformance suite's tokens" {
    const key: Key = .init("secret");
    var memory: [memory_bytes]u8 = undefined;
    var buffer: [512]u8 = undefined;
    const hs256 = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const now = 1_000_000;
    const Case = struct { header: []const u8, payload: []const u8, id: ?i64 };
    const cases = [_]Case{
        .{ .header = hs256, .payload = "{\"sub\":\"7\",\"iat\":1,\"exp\":2000000}", .id = 7 },
        .{ .header = hs256, .payload = "{\"sub\":\"7\",\"exp\":999999}", .id = null },
        .{ .header = hs256, .payload = "{\"sub\":\"7\",\"iat\":1}", .id = null },
        .{ .header = hs256, .payload = "{\"sub\":7,\"exp\":2000000}", .id = null },
        .{ .header = hs256, .payload = "{\"sub\":\"abc\",\"exp\":2000000}", .id = null },
        .{ .header = hs256, .payload = "{\"sub\":\"7\",\"exp\":2000000,\"nbf\":1500000}", .id = null },
        .{ .header = "{\"alg\":\"none\"}", .payload = "{\"sub\":\"7\",\"exp\":2000000}", .id = null },
    };
    for (cases) |case| {
        const token = sign(&buffer, "secret", case.header, case.payload);
        try testing.expectEqual(case.id, verify(&key, token, now, &memory));
    }
    const wrong = sign(&buffer, "other", hs256, "{\"sub\":\"7\",\"exp\":2000000}");
    try testing.expectEqual(null, verify(&key, wrong, now, &memory));
    try testing.expectEqual(null, verify(&key, "not.a.jwt", now, &memory));
    var issued: [token_bytes_max]u8 = undefined;
    const token = issue(&key, 42, now, &issued);
    try testing.expectEqual(42, verify(&key, token, now, &memory));
    try testing.expectEqual(null, verify(&key, token, now + ttl_s, &memory));
}
