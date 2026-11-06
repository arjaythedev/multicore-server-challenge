//! HS256 JWTs, verified on every request with the same rules as golang-jwt v5 in the reference server
//! (WithValidMethods HS256, WithExpirationRequired; sub must be a positive decimal string).
const std = @import("std");
const sha = @import("sha256.zig");
const json = @import("json.zig");

/// golang-jwt's header for HS256 tokens, base64url: {"alg":"HS256","typ":"JWT"}. Any other header is decoded
/// and checked in full.
const std_header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

var mac_ni: sha.Hmac(true) = undefined;
var mac_sw: sha.Hmac(false) = undefined;
var use_ni = false;

pub fn init(secret: []const u8) void {
    use_ni = sha.hasShaNi();
    if (use_ni) mac_ni = .init(secret) else mac_sw = .init(secret);
}

pub fn usingShaNi() bool {
    return use_ni;
}

fn mac(msg: []const u8) [32]u8 {
    return if (use_ni) mac_ni.mac(msg) else mac_sw.mac(msg);
}

/// Returns the user id of a valid token, or null.
pub fn verify(token: []const u8, now: i64) ?i64 {
    const d1 = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const d2 = d1 + 1 + (std.mem.indexOfScalar(u8, token[d1 + 1 ..], '.') orelse return null);
    if (std.mem.indexOfScalarPos(u8, token, d2 + 1, '.') != null) return null;
    const head = token[0..d1];
    const payload = token[d1 + 1 .. d2];
    const sig = token[d2 + 1 ..];

    var sig_bytes: [33]u8 = undefined;
    const sl = b64Decode(sig, &sig_bytes) orelse return null;
    if (sl.len != 32) return null;
    const want = mac(token[0..d2]);
    var diff: u8 = 0;
    for (want, sl) |a, b| diff |= a ^ b;
    if (diff != 0) return null;

    if (!std.mem.eql(u8, head, std_header) and !headerOk(head)) return null;

    var pbuf: [1024]u8 = undefined;
    const p = b64Decode(payload, &pbuf) orelse return null;
    return claims(p, now);
}

fn headerOk(head: []const u8) bool {
    var buf: [512]u8 = undefined;
    const h = b64Decode(head, &buf) orelse return false;
    const v = json.parse(h) orelse return false;
    if (v.kind() != .object) return false;
    const alg = v.get("alg") orelse return false;
    return std.mem.eql(u8, alg.raw, "\"HS256\"");
}

const Claim = enum { sub, exp, nbf, iat, iss, jti, aud };

fn claimOf(m: json.Member) ?Claim {
    const inner = m.key_raw[1 .. m.key_raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') == null) return std.meta.stringToEnum(Claim, inner);
    var tmp: [24]u8 = undefined;
    return std.meta.stringToEnum(Claim, json.decodeString(m.key_raw, &tmp) orelse return null);
}

/// One pass over the claims. Registered claims must have their JSON types, as golang-jwt's RegisteredClaims
/// unmarshal requires; a repeated claim's last value wins, as in encoding/json.
fn claims(p: []const u8, now: i64) ?i64 {
    const v = json.parse(p) orelse return null;
    if (v.kind() != .object) return null;
    var exp: ?json.Value = null;
    var nbf: ?json.Value = null;
    var sub: ?json.Value = null;
    var it = v.members();
    while (it.next()) |m| {
        const c = claimOf(m) orelse continue;
        const k = m.value.kind();
        const ok = switch (c) {
            .sub => k == .string,
            .exp, .nbf, .iat => k == .number or k == .null,
            .iss, .jti => k == .string or k == .null,
            .aud => k == .string or k == .array or k == .null,
        };
        if (!ok) return null;
        switch (c) {
            .sub => sub = m.value,
            .exp => exp = m.value,
            .nbf => nbf = m.value,
            else => {},
        }
    }
    const e = exp orelse return null;
    if (e.kind() != .number) return null;
    const exp_s = std.fmt.parseFloat(f64, e.raw) catch return null;
    if (!(@as(f64, @floatFromInt(now)) < exp_s)) return null;
    if (nbf) |n| if (n.kind() == .number) {
        const nbf_s = std.fmt.parseFloat(f64, n.raw) catch return null;
        if (@as(f64, @floatFromInt(now)) < nbf_s) return null;
    };
    const sub_raw = (sub orelse return null).raw;
    var sbuf: [64]u8 = undefined;
    if (sub_raw.len > 24) return null;
    const s = json.decodeString(sub_raw, &sbuf) orelse return null;
    if (s.len == 0) return null;
    var id: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        id = std.math.mul(i64, id, 10) catch return null;
        id = std.math.add(i64, id, c - '0') catch return null;
    }
    if (id <= 0) return null;
    return id;
}

/// Writes a fresh token for `id` into `out` and returns it. Claims: sub, iat, exp = iat + 30 days.
pub fn issue(id: i64, now: i64, out: *[256]u8) []const u8 {
    var payload: [96]u8 = undefined;
    const pl = std.fmt.bufPrint(&payload, "{{\"sub\":\"{d}\",\"exp\":{d},\"iat\":{d}}}", .{ id, now + 30 * 24 * 3600, now }) catch unreachable;
    var n: usize = 0;
    @memcpy(out[0..std_header.len], std_header);
    n = std_header.len;
    out[n] = '.';
    n += 1;
    n += b64Encode(pl, out[n..]);
    const sig = mac(out[0..n]);
    out[n] = '.';
    n += 1;
    n += b64Encode(&sig, out[n..]);
    return out[0..n];
}

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const inverse = blk: {
    var t: [256]u8 = @splat(0xff);
    for (alphabet, 0..) |c, i| t[c] = i;
    break :blk t;
};

/// Unpadded base64url, as Go's base64.RawURLEncoding decodes it (leftover bits are ignored).
fn b64Decode(s: []const u8, out: []u8) ?[]u8 {
    if (s.len % 4 == 1) return null;
    if (s.len / 4 * 3 + 3 > out.len) return null;
    var o: usize = 0;
    var i: usize = 0;
    while (i + 4 <= s.len) : (i += 4) {
        const a = inverse[s[i]];
        const b = inverse[s[i + 1]];
        const c = inverse[s[i + 2]];
        const d = inverse[s[i + 3]];
        if ((a | b | c | d) & 0xc0 != 0) return null;
        const v = (@as(u32, a) << 18) | (@as(u32, b) << 12) | (@as(u32, c) << 6) | d;
        out[o] = @truncate(v >> 16);
        out[o + 1] = @truncate(v >> 8);
        out[o + 2] = @truncate(v);
        o += 3;
    }
    const rem = s.len - i;
    if (rem >= 2) {
        const a = inverse[s[i]];
        const b = inverse[s[i + 1]];
        if ((a | b) & 0xc0 != 0) return null;
        out[o] = (a << 2) | (b >> 4);
        o += 1;
        if (rem == 3) {
            const c = inverse[s[i + 2]];
            if (c & 0xc0 != 0) return null;
            out[o] = (b << 4) | (c >> 2);
            o += 1;
        }
    }
    return out[0..o];
}

fn b64Encode(src: []const u8, out: []u8) usize {
    var o: usize = 0;
    var i: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const v = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8) | src[i + 2];
        out[o] = alphabet[v >> 18];
        out[o + 1] = alphabet[(v >> 12) & 63];
        out[o + 2] = alphabet[(v >> 6) & 63];
        out[o + 3] = alphabet[v & 63];
        o += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        const v = @as(u32, src[i]) << 16;
        out[o] = alphabet[v >> 18];
        out[o + 1] = alphabet[(v >> 12) & 63];
        o += 2;
    } else if (rem == 2) {
        const v = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8);
        out[o] = alphabet[v >> 18];
        out[o + 1] = alphabet[(v >> 12) & 63];
        out[o + 2] = alphabet[(v >> 6) & 63];
        o += 3;
    }
    return o;
}

test "issue then verify" {
    init("multicore-server-challenge");
    var buf: [256]u8 = undefined;
    const t = issue(42, 1_700_000_000, &buf);
    try std.testing.expectEqual(@as(?i64, 42), verify(t, 1_700_000_000));
    try std.testing.expectEqual(@as(?i64, null), verify(t, 1_700_000_000 + 31 * 24 * 3600));
    var bad = buf;
    bad[t.len - 1] ^= 1;
    try std.testing.expectEqual(@as(?i64, null), verify(bad[0..t.len], 1_700_000_000));
}

test "golang-jwt token" {
    init("multicore-server-challenge");
    // Python: jwt.encode({"sub":"123","iat":1700000000,"exp":4102444800}, key, "HS256") with golang-jwt's header.
    const header = std_header;
    var pl: [128]u8 = undefined;
    const n = b64Encode("{\"exp\":4102444800,\"iat\":1700000000,\"sub\":\"123\"}", &pl);
    var tok: [256]u8 = undefined;
    var t: usize = 0;
    @memcpy(tok[0..header.len], header);
    t = header.len;
    tok[t] = '.';
    t += 1;
    @memcpy(tok[t..][0..n], pl[0..n]);
    t += n;
    var want: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&want, tok[0..t], "multicore-server-challenge");
    tok[t] = '.';
    t += 1;
    t += b64Encode(&want, tok[t..]);
    try std.testing.expectEqual(@as(?i64, 123), verify(tok[0..t], 1_800_000_000));
}

fn testToken(payload: []const u8, out: *[512]u8) []const u8 {
    var t: usize = std_header.len;
    @memcpy(out[0..t], std_header);
    out[t] = '.';
    t += 1;
    t += b64Encode(payload, out[t..]);
    const sig = mac(out[0..t]);
    out[t] = '.';
    t += 1;
    t += b64Encode(&sig, out[t..]);
    return out[0..t];
}

test "claims follow golang-jwt's types" {
    init("multicore-server-challenge");
    const now = 1_800_000_000;
    var buf: [512]u8 = undefined;
    const cases = [_]struct { []const u8, ?i64 }{
        .{ "{\"sub\":\"7\",\"exp\":1900000000}", 7 },
        .{ "{\"sub\":\"7\",\"exp\":1900000000,\"iss\":null,\"aud\":[\"x\"],\"jti\":\"j\",\"iat\":1,\"nbf\":null}", 7 },
        // The last of a repeated claim wins; every occurrence must have the claim's type.
        .{ "{\"sub\":\"7\",\"exp\":1900000000,\"sub\":\"8\"}", 8 },
        .{ "{\"sub\":\"7\",\"exp\":1700000000,\"exp\":1900000000}", 7 },
        .{ "{\"sub\":\"7\",\"exp\":1900000000,\"exp\":1700000000}", null },
        .{ "{\"sub\":7,\"sub\":\"7\",\"exp\":1900000000}", null },
        .{ "{\"iat\":\"1\",\"sub\":\"7\",\"exp\":1900000000}", null },
        .{ "{\"sub\":\"7\",\"exp\":1900000000,\"aud\":1}", null },
        // Escaped keys name the same claim.
        .{ "{\"\\u0073ub\":\"9\",\"exp\":1900000000}", 9 },
        .{ "{\"sub\":\"7\",\"\\u0065xp\":1700000000}", null },
        .{ "{\"sub\":\"7\",\"exp\":1900000000,\"nbf\":1850000000}", null },
        .{ "{\"sub\":\"7\"}", null },
        .{ "{\"sub\":\"7\",\"exp\":null}", null },
        .{ "{\"sub\":\"0\",\"exp\":1900000000}", null },
        .{ "{\"sub\":\"\",\"exp\":1900000000}", null },
        .{ "[]", null },
    };
    for (cases) |c| try std.testing.expectEqual(c[1], verify(testToken(c[0], &buf), now));
}
