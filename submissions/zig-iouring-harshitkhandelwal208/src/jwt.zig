//! HS256 JWTs. The HMAC pad states are derived from the secret once at startup; every request still verifies the
//! signature and `exp` in full (no verification cache).
const std = @import("std");
const jp = @import("jp.zig");
const Scratch = @import("scratch.zig").Scratch;
const Sha256 = std.crypto.hash.sha2.Sha256;
const b64 = std.base64.url_safe_no_pad;

pub const lifetime: i64 = 30 * 24 * 3600;
const header_b64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"; // {"alg":"HS256","typ":"JWT"}

pub const Key = struct {
    inner: Sha256,
    outer: Sha256,

    pub fn init(secret: []const u8) Key {
        var k: [64]u8 = @splat(0);
        if (secret.len > 64) Sha256.hash(secret, k[0..32], .{}) else @memcpy(k[0..secret.len], secret);
        var ip: [64]u8 = undefined;
        var op: [64]u8 = undefined;
        for (k, 0..) |c, i| {
            ip[i] = c ^ 0x36;
            op[i] = c ^ 0x5c;
        }
        var key: Key = .{ .inner = Sha256.init(.{}), .outer = Sha256.init(.{}) };
        key.inner.update(&ip);
        key.outer.update(&op);
        return key;
    }

    fn mac(self: *const Key, msg: []const u8) [32]u8 {
        var h = self.inner;
        h.update(msg);
        var d: [32]u8 = undefined;
        h.final(&d);
        var o = self.outer;
        o.update(&d);
        o.final(&d);
        return d;
    }

    /// Writes a fresh token for `uid` into `out` (at least `max_token_len` bytes) and returns its length.
    pub fn issue(self: *const Key, out: []u8, uid: u64, now: i64) usize {
        var payload: [96]u8 = undefined;
        const pl = std.fmt.bufPrint(&payload, "{{\"sub\":\"{d}\",\"iat\":{d},\"exp\":{d}}}", .{ uid, now, now + lifetime }) catch unreachable;
        @memcpy(out[0..header_b64.len], header_b64);
        var n: usize = header_b64.len;
        out[n] = '.';
        n += 1;
        n += b64.Encoder.encode(out[n..], pl).len;
        const sig = self.mac(out[0..n]);
        out[n] = '.';
        n += 1;
        n += b64.Encoder.encode(out[n..], &sig).len;
        return n;
    }

    /// Returns the user id when the signature, algorithm and expiry are valid.
    pub fn verify(self: *const Key, token: []const u8, now: i64, sc: *Scratch) ?u64 {
        const d1 = std.mem.indexOfScalar(u8, token, '.') orelse return null;
        const d2 = std.mem.indexOfScalarPos(u8, token, d1 + 1, '.') orelse return null;
        const sig_b = token[d2 + 1 ..];
        if (sig_b.len != 43) return null;
        var sig: [32]u8 = undefined;
        b64.Decoder.decode(&sig, sig_b) catch return null;
        const want = self.mac(token[0..d2]);
        var diff: u8 = 0;
        for (sig, want) |a, b| diff |= a ^ b;
        if (diff != 0) return null;
        // Signature is ours; now check the header's algorithm (fast path: the canonical header).
        const hdr = token[0..d1];
        if (!std.mem.eql(u8, hdr, header_b64)) {
            var hb: [128]u8 = undefined;
            const hl = b64.Decoder.calcSizeForSlice(hdr) catch return null;
            if (hl > hb.len) return null;
            b64.Decoder.decode(hb[0..hl], hdr) catch return null;
            var f: [1]jp.Field = undefined;
            jp.parseObject(hb[0..hl], sc, &.{"alg"}, &f) catch return null;
            if (f[0].kind != .string or !std.mem.eql(u8, f[0].s, "HS256")) return null;
        }
        var pb: [256]u8 = undefined;
        const pl = b64.Decoder.calcSizeForSlice(token[d1 + 1 .. d2]) catch return null;
        if (pl > pb.len) return null;
        b64.Decoder.decode(pb[0..pl], token[d1 + 1 .. d2]) catch return null;
        // Exact issued payload only, after HMAC and algorithm verification. Any
        // extra/reordered claim (including nbf) must use the general parser below.
        if (canonicalClaims(pb[0..pl], now)) |uid| return uid;
        var f: [3]jp.Field = undefined;
        jp.parseObject(pb[0..pl], sc, &.{ "sub", "exp", "nbf" }, &f) catch return null;
        if (f[0].kind != .string or f[1].kind != .number) return null;
        const exp = parseNumericDate(f[1].s) orelse return null;
        if (exp <= now) return null;
        if (f[2].kind == .number) {
            const nbf = parseNumericDate(f[2].s) orelse return null;
            if (nbf > now) return null;
        } else if (f[2].kind != .absent and f[2].kind != .null) return null;
        const sub = f[0].s;
        if (sub.len == 0 or sub.len > 19) return null;
        var uid: u64 = 0;
        for (sub) |c| {
            if (c < '0' or c > '9') return null;
            uid = uid * 10 + (c - '0');
        }
        if (uid == 0 or uid > std.math.maxInt(i64)) return null;
        return uid;
    }
};

pub const max_token_len = header_b64.len + 1 + 96 * 4 / 3 + 3 + 1 + 43;

fn decimal(s: []const u8, json_number: bool) ?u64 {
    if (s.len == 0 or s.len > 19 or (json_number and s.len > 1 and s[0] == '0')) return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
    }
    return if (n <= std.math.maxInt(i64)) n else null;
}

fn canonicalClaims(payload: []const u8, now: i64) ?u64 {
    const prefix = "{\"sub\":\"";
    const middle = "\",\"iat\":";
    const end = ",\"exp\":";
    if (!std.mem.startsWith(u8, payload, prefix) or !std.mem.endsWith(u8, payload, "}")) return null;
    const split = std.mem.indexOfPos(u8, payload, prefix.len, middle) orelse return null;
    const uid = decimal(payload[prefix.len..split], false) orelse return null;
    if (uid == 0) return null;
    const at = split + middle.len;
    const next = std.mem.indexOfPos(u8, payload, at, end) orelse return null;
    _ = decimal(payload[at..next], true) orelse return null;
    const expires = decimal(payload[next + end.len .. payload.len - 1], true) orelse return null;
    if (@as(i64, @intCast(expires)) <= now) return null;
    return uid;
}

test "canonical claims never bypass nbf, extra claims, malformed numbers or expiration" {
    try std.testing.expectEqual(@as(?u64, 42), canonicalClaims("{\"sub\":\"42\",\"iat\":100,\"exp\":200}", 150));
    const rejected = [_][]const u8{
        "{\"sub\":\"42\",\"iat\":100,\"exp\":150}",
        "{\"sub\":\"0\",\"iat\":100,\"exp\":200}",
        "{\"sub\":\"42\",\"iat\":0100,\"exp\":200}",
        "{\"sub\":\"42\",\"iat\":100,\"exp\":0200}",
        "{\"sub\":\"42\",\"iat\":100,\"exp\":200,\"nbf\":190}",
        "{\"sub\":\"42\",\"iat\":100,\"exp\":200,\"extra\":true}",
        "{\"sub\":\"9223372036854775808\",\"iat\":100,\"exp\":200}",
    };
    for (rejected) |p| try std.testing.expect(canonicalClaims(p, 150) == null);
}

fn parseNumericDate(s: []const u8) ?i64 {
    if (std.fmt.parseInt(i64, s, 10)) |v| return v else |_| {}
    const f = std.fmt.parseFloat(f64, s) catch return null;
    if (!(f > -1e15 and f < 1e15)) return null;
    return @intFromFloat(@floor(f));
}

test "issue and verify" {
    var sc = try Scratch.init(1024);
    const key = Key.init("multicore-server-challenge");
    var tok: [max_token_len]u8 = undefined;
    const n = key.issue(&tok, 4242, 1_700_000_000);
    try std.testing.expectEqual(@as(?u64, 4242), key.verify(tok[0..n], 1_700_000_100, &sc));
    try std.testing.expectEqual(@as(?u64, null), key.verify(tok[0..n], 1_700_000_000 + lifetime + 1, &sc));
    tok[n - 1] = if (tok[n - 1] == 'A') 'B' else 'A';
    try std.testing.expectEqual(@as(?u64, null), key.verify(tok[0..n], 1_700_000_100, &sc));
    // A reference token from the Go conformance minting code path (HS256, secret above) is checked end-to-end by the suite.
}
