//! SHA-256 and HMAC-SHA256 for JWT HS256. Two block functions, chosen once at startup by CPUID: the SHA-NI
//! instructions when the CPU has them, portable scalar code otherwise. The HMAC key pads are absorbed once
//! (allowed: it is the key schedule, not a verification result), so a token costs its message blocks plus one.
const std = @import("std");

const V4u32 = @Vector(4, u32);

const K = [64]u32{
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, 0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3, 0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC, 0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7, 0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13, 0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3, 0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5, 0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208, 0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
};

pub const iv = [8]u32{ 0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19 };

pub fn hasShaNi() bool {
    const leaf7 = cpuid(7, 0);
    const leaf1 = cpuid(1, 0);
    const sha = (leaf7.ebx >> 29) & 1 == 1;
    const sse41 = (leaf1.ecx >> 19) & 1 == 1;
    return sha and sse41;
}

const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };
fn cpuid(leaf: u32, sub: u32) Cpuid {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
          [_] "{ecx}" (sub),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

fn loadWords(b: *const [64]u8) [64]u32 {
    var s: [64]u32 = undefined;
    inline for (0..16) |i| s[i] = std.mem.readInt(u32, b[i * 4 ..][0..4], .big);
    return s;
}

fn blockScalar(st: *[8]u32, b: *const [64]u8) void {
    var s = loadWords(b);
    var i: usize = 16;
    while (i < 64) : (i += 1) {
        const s0 = std.math.rotr(u32, s[i - 15], 7) ^ std.math.rotr(u32, s[i - 15], 18) ^ (s[i - 15] >> 3);
        const s1 = std.math.rotr(u32, s[i - 2], 17) ^ std.math.rotr(u32, s[i - 2], 19) ^ (s[i - 2] >> 10);
        s[i] = s[i - 16] +% s0 +% s[i - 7] +% s1;
    }
    var a = st[0];
    var bb = st[1];
    var c = st[2];
    var d = st[3];
    var e = st[4];
    var f = st[5];
    var g = st[6];
    var h = st[7];
    inline for (0..64) |r| {
        const S1 = std.math.rotr(u32, e, 6) ^ std.math.rotr(u32, e, 11) ^ std.math.rotr(u32, e, 25);
        const ch = (e & f) ^ (~e & g);
        const t1 = h +% S1 +% ch +% K[r] +% s[r];
        const S0 = std.math.rotr(u32, a, 2) ^ std.math.rotr(u32, a, 13) ^ std.math.rotr(u32, a, 22);
        const maj = (a & bb) ^ (a & c) ^ (bb & c);
        const t2 = S0 +% maj;
        h = g;
        g = f;
        f = e;
        e = d +% t1;
        d = c;
        c = bb;
        bb = a;
        a = t1 +% t2;
    }
    st[0] +%= a;
    st[1] +%= bb;
    st[2] +%= c;
    st[3] +%= d;
    st[4] +%= e;
    st[5] +%= f;
    st[6] +%= g;
    st[7] +%= h;
}

/// The SHA-NI form follows Zig std's x86_64 path (state as {f,e,b,a} / {h,g,d,c} lanes).
fn blockNi(st: *[8]u32, b: *const [64]u8) void {
    var s: [64]u32 align(16) = loadWords(b);
    var x: V4u32 = .{ st[5], st[4], st[1], st[0] };
    var y: V4u32 = .{ st[7], st[6], st[3], st[2] };
    const s_v: *[16]V4u32 = @ptrCast(&s);
    inline for (0..16) |k| {
        if (k < 12) {
            var tmp = s_v[k];
            s_v[k + 4] = asm (
                \\ sha256msg1 %[w4_7], %[tmp]
                \\ vpalignr $0x4, %[w8_11], %[w12_15], %[result]
                \\ paddd %[tmp], %[result]
                \\ sha256msg2 %[w12_15], %[result]
                : [tmp] "=&x" (tmp),
                  [result] "=&x" (-> V4u32),
                : [_] "0" (tmp),
                  [w4_7] "x" (s_v[k + 1]),
                  [w8_11] "x" (s_v[k + 2]),
                  [w12_15] "x" (s_v[k + 3]),
            );
        }
        const w: V4u32 = s_v[k] +% @as(V4u32, K[4 * k ..][0..4].*);
        y = asm ("sha256rnds2 %[x], %[y]"
            : [y] "=x" (-> V4u32),
            : [_] "0" (y),
              [x] "x" (x),
              [_] "{xmm0}" (w),
        );
        x = asm ("sha256rnds2 %[y], %[x]"
            : [x] "=x" (-> V4u32),
            : [_] "0" (x),
              [y] "x" (y),
              [_] "{xmm0}" (@as(V4u32, @bitCast(@as(u128, @bitCast(w)) >> 64))),
        );
    }
    st[0] +%= x[3];
    st[1] +%= x[2];
    st[4] +%= x[1];
    st[5] +%= x[0];
    st[2] +%= y[3];
    st[3] +%= y[2];
    st[6] +%= y[1];
    st[7] +%= y[0];
}

/// HMAC-SHA256 with the key pads absorbed once. `ni` picks the block function at compile time; startup picks
/// which instantiation runs.
pub fn Hmac(comptime ni: bool) type {
    return struct {
        const block = if (ni) blockNi else blockScalar;

        inner: [8]u32,
        outer: [8]u32,

        pub fn init(key: []const u8) @This() {
            var k: [64]u8 = @splat(0);
            if (key.len > 64) {
                k[0..32].* = digest(iv, 0, key);
            } else {
                @memcpy(k[0..key.len], key);
            }
            var ipad: [64]u8 = undefined;
            var opad: [64]u8 = undefined;
            for (k, 0..) |c, i| {
                ipad[i] = c ^ 0x36;
                opad[i] = c ^ 0x5c;
            }
            var h: @This() = .{ .inner = iv, .outer = iv };
            block(&h.inner, &ipad);
            block(&h.outer, &opad);
            return h;
        }

        /// SHA-256 of `msg` continuing from `state`, which has already absorbed `prefix` bytes (a multiple of 64).
        fn digest(state: [8]u32, prefix: u64, msg: []const u8) [32]u8 {
            var st = state;
            var i: usize = 0;
            while (i + 64 <= msg.len) : (i += 64) block(&st, msg[i..][0..64]);
            var tail: [128]u8 = @splat(0);
            const rem = msg.len - i;
            @memcpy(tail[0..rem], msg[i..]);
            tail[rem] = 0x80;
            const blocks: usize = if (rem + 9 <= 64) 1 else 2;
            const bits = (prefix + msg.len) * 8;
            std.mem.writeInt(u64, tail[blocks * 64 - 8 ..][0..8], bits, .big);
            block(&st, tail[0..64]);
            if (blocks == 2) block(&st, tail[64..128]);
            var out: [32]u8 = undefined;
            inline for (0..8) |j| std.mem.writeInt(u32, out[j * 4 ..][0..4], st[j], .big);
            return out;
        }

        pub fn mac(h: *const @This(), msg: []const u8) [32]u8 {
            const in = digest(h.inner, 64, msg);
            return digest(h.outer, 64, &in);
        }
    };
}

test "hmac matches std" {
    const key = "multicore-server-challenge";
    const msg = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjMiLCJpYXQiOjE3MDAwMDAwMDAsImV4cCI6MTcwMjU5MjAwMH0";
    var want: [32]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&want, msg, key);
    try std.testing.expectEqual(want, Hmac(false).init(key).mac(msg));
    if (hasShaNi()) try std.testing.expectEqual(want, Hmac(true).init(key).mac(msg));
    var lens: usize = 0;
    while (lens < 200) : (lens += 1) {
        var buf: [200]u8 = undefined;
        for (&buf, 0..) |*c, i| c.* = @truncate(i * 7 + lens);
        std.crypto.auth.hmac.sha2.HmacSha256.create(&want, buf[0..lens], key);
        try std.testing.expectEqual(want, Hmac(false).init(key).mac(buf[0..lens]));
        if (hasShaNi()) try std.testing.expectEqual(want, Hmac(true).init(key).mac(buf[0..lens]));
    }
}
