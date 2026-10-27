//! pz: gzip for small JSON answers (Zig port of research/gzip-fast/v2/pz2.c with PZ_HBYTES=8, anchor mode only).
//!
//! One dynamic-Huffman block whose header is precomputed (pz_table_anchor.zig, trained offline by mk_table.py),
//! so there is no per-call tree building. Matches are looked for only at closing quotes (a '"' followed by
//! , : ] }) and again where each match ends; every other byte is a literal, coded two per pair-table lookup and
//! four per bit-buffer write. With a budget, the Huffman block ends as soon as the rest of the input fits as one
//! stored block, which is all the 2-segment target needs.
//!
//! Needs x86-64-v3 (AVX2) and PCLMULQDQ. Call detectCpu() once: without PCLMULQDQ (`has_pclmul` false) encode() must
//! not be called, and the server sends identity bodies. The CRC uses 256-bit VPCLMULQDQ where present.
const std = @import("std");
const t = @import("pz_table_anchor.zig");

/// Largest input encode() takes: match positions are u16 and the anchor mask is on the stack.
pub const max_input = 65535;

/// Room encode() needs in `out` for an input of n bytes: the worst case is every byte as an 11-bit literal,
/// plus header, stored-block framing, trailer and 8 bytes of slack for the bit writer's 8-byte stores.
pub fn outBound(n: usize) usize {
    return n + n / 2 + 160;
}

const len_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const len_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

fn distSym(d: u32) u8 {
    var s: u8 = 0;
    while (s < 29 and dist_base[s + 1] <= d) s += 1;
    return s;
}

/// Tables derived from the trained codes, built at compile time.
const Coder = struct {
    /// Length 3..258: its code and extra bits as one value, and their bit count.
    len_bits: [259]u32,
    len_n: [259]u8,
    /// Distance symbol of d-1 for d <= 256, and of (d-1) >> 7 above.
    dsym_lo: [256]u8,
    dsym_hi: [256]u8,
    /// Bytes (x, y) at x | y << 8: code(x) | code(y) << len(x) in bits 0-21, len(x) + len(y) in 22-26, len(x) in 27-30.
    pair: [65536]u32,
};

const coder: Coder = blk: {
    @setEvalBranchQuota(10_000_000);
    var c: Coder = undefined;
    for (t.lit_len) |l| if (l > 11) @compileError("pz pairs need lit/len codes of at most 11 bits");
    for (3..259) |l| {
        var s: usize = 0;
        while (s < 28 and len_base[s + 1] <= l) s += 1;
        c.len_bits[l] = @as(u32, t.lit_code[257 + s]) | @as(u32, @intCast(l - len_base[s])) << @intCast(t.lit_len[257 + s]);
        c.len_n[l] = t.lit_len[257 + s] + len_extra[s];
    }
    for (0..256) |i| {
        c.dsym_lo[i] = distSym(@intCast(i + 1));
        c.dsym_hi[i] = distSym(@intCast((i << 7) + 1));
    }
    for (0..256) |x| for (0..256) |y| {
        c.pair[x | y << 8] = (@as(u32, t.lit_code[x]) | @as(u32, t.lit_code[y]) << @intCast(t.lit_len[x])) |
            @as(u32, t.lit_len[x] + t.lit_len[y]) << 22 | @as(u32, t.lit_len[x]) << 27;
    };
    break :blk c;
};

inline fn load16(p: [*]const u8) u32 {
    return std.mem.readInt(u16, p[0..2], .little);
}
inline fn load32(p: [*]const u8) u32 {
    return std.mem.readInt(u32, p[0..4], .little);
}
inline fn load64(p: [*]const u8) u64 {
    return std.mem.readInt(u64, p[0..8], .little);
}
/// Hashes the 8 bytes at p. At a closing quote 4 bytes are only `","` plus a key's first letter, so title and
/// tagList, or slug and status, would share a slot and give short matches of the wrong key.
inline fn hash(p: [*]const u8) u32 {
    return @intCast((load64(p) *% 0x9E3779B97F4A7C15) >> (64 - hash_bits));
}
const hash_bits = 10;

/// LSB-first bit writer. Every put() run between flushes is at most 55 bits, so bc stays below 64.
const Bits = struct {
    bb: u64 = 0,
    bc: u32 = 0,
    p: [*]u8,

    inline fn put(w: *Bits, v: u64, n: u32) void {
        w.bb |= v << @intCast(w.bc);
        w.bc += n;
    }
    inline fn flush(w: *Bits) void {
        std.mem.writeInt(u64, w.p[0..8], w.bb, .little);
        w.p += w.bc >> 3;
        w.bb >>= @intCast(w.bc & ~@as(u32, 7));
        w.bc &= 7;
    }
};

inline fn matchLen(a: [*]const u8, b: [*]const u8, max: u32) u32 {
    var len: u32 = 4;
    while (len + 8 <= max) : (len += 8) {
        const x = load64(a + len) ^ load64(b + len);
        if (x != 0) return len + @as(u32, @ctz(x) >> 3);
    }
    while (len < max and a[len] == b[len]) len += 1;
    return len;
}

/// Closing quotes in p[0..32]: a '"' followed by , : ] or }. Reads p[32].
inline fn anchors32(p: [*]const u8) u32 {
    const V = @Vector(32, u8);
    const v: V = p[0..32].*;
    const x: V = p[1..33].*;
    const q = v == @as(V, @splat('"'));
    const cl = (x == @as(V, @splat(','))) | (x == @as(V, @splat(':'))) | (x == @as(V, @splat(']'))) | (x == @as(V, @splat('}')));
    return @bitCast(q & cl);
}

/// Writes one gzip member for `in` to `out` (at least outBound(in.len) bytes) and returns its length.
/// `in` needs 3 readable bytes past its end (in.ptr[in.len..][0..3]). in.len <= max_input.
/// budget > 0: stop Huffman coding once the member is sure to fit `budget` bytes and send the rest stored.
pub fn encode(in: []const u8, out: []u8, budget: usize) usize {
    std.debug.assert(in.len <= max_input and out.len >= outBound(in.len));
    const n = in.len;
    const src = in.ptr;
    out[0..10].* = .{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff };
    var w: Bits = .{ .p = out.ptr + 10 };
    w.put(2 << 1, 3); // BFINAL=0 (set at the end when there is no stored tail), BTYPE=10
    var hb: u32 = 0;
    while (hb < t.hdr_bits) : (hb += 32) {
        const k = @min(t.hdr_bits - hb, 32);
        const word = load32(@ptrCast(&t.hdr[hb / 8]));
        w.put(if (k == 32) word else word & ((@as(u32, 1) << @intCast(k)) - 1), k);
        w.flush();
    }
    // The member fits once bytes so far + EOB + stored header (3 bits, align, 4 bytes) + rest + trailer do.
    const fixed: usize = 8 + 4 + 1 + (t.lit_len[256] + 3 + 7) / 8;
    const limit: isize = if (budget > fixed) @intCast(budget - fixed) else -1;

    var mask: [max_input / 64 + 2]u64 = undefined;
    const nw = (n + 63) / 64;
    var k: usize = 0;
    while (k + 64 <= n) : (k += 64) mask[k / 64] = anchors32(src + k) | @as(u64, anchors32(src + k + 32)) << 32;
    if (k < n) {
        var m: u64 = 0;
        for (k..n) |j| {
            const close = src[j] == '"' and j + 1 < n and (src[j + 1] == ',' or src[j + 1] == ':' or src[j + 1] == ']' or src[j + 1] == '}');
            m |= @as(u64, @intFromBool(close)) << @intCast(j - k);
        }
        mask[k / 64] = m;
    }
    var ht: [1 << hash_bits]u16 = @splat(0);

    var i: usize = 0;
    var stored = false;
    while (true) {
        // next anchor at or after i
        var wi = i >> 6;
        var a = n;
        var m: u64 = if (wi < nw) mask[wi] & (~@as(u64, 0) << @intCast(i & 63)) else 0;
        while (m == 0) {
            wi += 1;
            if (wi >= nw) break;
            m = mask[wi];
        }
        if (m != 0) a = (wi << 6) + @ctz(m);
        // literals [i, a): four per write; the 1-3 left are coded the same way and masked to their length
        while (i + 4 <= a) : (i += 4) {
            const e0 = coder.pair[load16(src + i)];
            const e1 = coder.pair[load16(src + i + 2)];
            const n0 = e0 >> 22 & 31;
            w.put(@as(u64, e0 & 0x3fffff) | @as(u64, e1 & 0x3fffff) << @intCast(n0), n0 + (e1 >> 22 & 31));
            w.flush();
        }
        if (i < a) {
            const r = a - i;
            const e0 = coder.pair[load16(src + i)];
            const e1 = coder.pair[load16(src + i + 2)];
            const n0 = e0 >> 22 & 31;
            const nb: u32 = if (r == 1) e0 >> 27 else if (r == 2) n0 else n0 + (e1 >> 27);
            const v = (@as(u64, e0 & 0x3fffff) | @as(u64, e1 & 0x3fffff) << @intCast(n0)) & ((@as(u64, 1) << @intCast(nb)) - 1);
            w.put(v, nb);
            w.flush();
            i = a;
        }
        if (a >= n) break;
        if (limit >= 0 and @as(isize, @intCast(w.p - out.ptr)) + @as(isize, @intCast(n - i)) <= limit) {
            stored = true;
            break;
        }
        // At the anchor, then where each match ends (a value start right after "key":"), chained while they hit.
        var pos = i;
        while (pos + 8 <= n) {
            const v = load32(src + pos);
            const h = hash(src + pos);
            const cand: u32 = ht[h];
            ht[h] = @intCast(pos);
            const d: u32 = @as(u32, @intCast(pos)) -% cand;
            if (!(cand < pos and d <= 32768 and load32(src + cand) == v)) break;
            const len = matchLen(src + pos, src + cand, @intCast(@min(n - pos, 258)));
            const ds = if (d <= 256) coder.dsym_lo[d - 1] else coder.dsym_hi[(d - 1) >> 7];
            w.put(coder.len_bits[len], coder.len_n[len]);
            w.put(@as(u64, t.dist_code[ds]) | @as(u64, d - dist_base[ds]) << @intCast(t.dist_len[ds]), @as(u32, t.dist_len[ds]) + dist_extra[ds]);
            w.flush();
            // the anchors inside the match go into the table too
            const e = pos + len;
            var b = pos + 1;
            while (b < e) {
                const bw = b >> 6;
                const bm = mask[bw] & (~@as(u64, 0) << @intCast(b & 63));
                if (bm == 0) {
                    b = (bw + 1) << 6;
                    continue;
                }
                b = (bw << 6) + @ctz(bm);
                if (b >= e) break;
                if (b + 8 <= n) ht[hash(src + b)] = @intCast(b);
                b += 1;
            }
            pos = e;
        }
        if (pos > i) {
            i = pos;
            continue;
        }
        w.put(t.lit_code[src[i]], t.lit_len[src[i]]);
        w.flush();
        i += 1;
    }
    w.put(t.lit_code[256], t.lit_len[256]);
    var p: [*]u8 = undefined;
    if (stored) {
        const rest = n - i;
        w.put(1, 3); // BFINAL=1, BTYPE=00
        w.flush();
        p = w.p + @intFromBool(w.bc != 0); // align: the partial byte is already written
        std.mem.writeInt(u16, p[0..2], @intCast(rest), .little);
        std.mem.writeInt(u16, p[2..4], ~@as(u16, @intCast(rest)), .little);
        @memcpy(p[4..][0..rest], src[i..n]);
        p += 4 + rest;
    } else {
        out[10] |= 1;
        w.flush();
        p = w.p + @intFromBool(w.bc != 0);
    }
    std.mem.writeInt(u32, p[0..4], crc32(in), .little);
    std.mem.writeInt(u32, p[4..8], @intCast(n), .little);
    return @intCast(p + 8 - out.ptr);
}

// ---------------------------------------------------------------- CRC-32 (gzip), PCLMULQDQ folding

const V2 = @Vector(2, u64);

/// out = clmul(a.qword[imm & 1], b.qword[imm >> 4 & 1])
inline fn clmul(a: V2, b: V2, comptime imm: u8) V2 {
    return asm ("vpclmulqdq %[imm], %[b], %[a], %[out]"
        : [out] "=x" (-> V2),
        : [a] "x" (a),
          [b] "x" (b),
          [imm] "n" (imm),
    );
}

const V4 = @Vector(4, u64);

/// CPUID.(EAX=7,ECX=0):ECX bit 10. Without it the 4-lane 128-bit loop does all the folding (~2x slower).
/// The server is built for x86-64-v3, which doesn't include VPCLMULQDQ, so this is checked at run time.
pub var has_vpclmul: bool = false;
/// CPUID.1:ECX bit 1. x86-64-v3 doesn't formally include PCLMULQDQ.
pub var has_pclmul: bool = false;

fn cpuidEcx(leaf: u32) u32 {
    var a: u32 = leaf;
    var b: u32 = undefined;
    var c: u32 = 0;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "+{eax}" (a),
          [b] "={ebx}" (b),
          [c] "+{ecx}" (c),
          [d] "={edx}" (d),
    );
    return c;
}

pub fn detectCpu() void {
    has_pclmul = cpuidEcx(1) & (1 << 1) != 0;
    has_vpclmul = has_pclmul and cpuidEcx(7) & (1 << 10) != 0;
}

/// clmul on both 128-bit halves (256-bit VPCLMULQDQ).
inline fn clmul256(a: V4, b: V4, comptime imm: u8) V4 {
    return asm ("vpclmulqdq %[imm], %[b], %[a], %[out]"
        : [out] "=x" (-> V4),
        : [a] "x" (a),
          [b] "x" (b),
          [imm] "n" (imm),
    );
}

inline fn ld256(p: [*]const u8) V4 {
    const v: @Vector(32, u8) = p[0..32].*;
    return @bitCast(v);
}

inline fn ld128(p: [*]const u8) V2 {
    const v: @Vector(16, u8) = p[0..16].*;
    return @bitCast(v);
}

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var tab: [256]u32 = undefined;
    for (&tab, 0..) |*e, i| {
        var c: u32 = i;
        for (0..8) |_| c = (c >> 1) ^ (if (c & 1 != 0) @as(u32, 0xEDB88320) else 0);
        e.* = c;
    }
    break :blk tab;
};

/// The gzip CRC-32 of `data`. Folds 64 bytes per step with PCLMULQDQ (constants from Linux's crc32-pclmul_asm.S,
/// reflected polynomial 0x104C11DB7), then a Barrett reduction; bytes past the last 16 go through a table.
pub fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xffffffff;
    var p = data.ptr;
    var len = data.len;
    if (len >= 64) {
        const k1k2: V2 = .{ 0x154442bd4, 0x1c6e41596 };
        const k3k4: V2 = .{ 0x1751997d0, 0x0ccaa009e };
        const k5: V2 = .{ 0x163cd6124, 0 };
        const poly_mu: V2 = .{ 0x1db710641, 0x1f7011641 };
        const mask32: V2 = .{ 0xffffffff, 0 };
        var x1 = ld128(p) ^ V2{ crc, 0 };
        var x2 = ld128(p + 16);
        var x3 = ld128(p + 32);
        var x4 = ld128(p + 48);
        p += 64;
        len -= 64;
        if (len >= 64 and has_vpclmul) {
            // Eight 128-bit lanes held as four 256-bit ones while 128 bytes remain (x^1056 and x^992: a 1024-bit
            // fold); 256-bit VPCLMULQDQ folds two lanes per instruction, and PCLMUL throughput is the limit on
            // Zen 3. Then lanes 5-8 are folded into 1-4 by 512 bits.
            const k8: V4 = .{ 0x1e88ef372, 0x14a7fe880, 0x1e88ef372, 0x14a7fe880 };
            var y1: V4 = @bitCast([2]V2{ x1, x2 });
            var y2: V4 = @bitCast([2]V2{ x3, x4 });
            var y3 = ld256(p);
            var y4 = ld256(p + 32);
            p += 64;
            len -= 64;
            while (len >= 128) : ({
                p += 128;
                len -= 128;
            }) {
                y1 = clmul256(y1, k8, 0x00) ^ clmul256(y1, k8, 0x11) ^ ld256(p);
                y2 = clmul256(y2, k8, 0x00) ^ clmul256(y2, k8, 0x11) ^ ld256(p + 32);
                y3 = clmul256(y3, k8, 0x00) ^ clmul256(y3, k8, 0x11) ^ ld256(p + 64);
                y4 = clmul256(y4, k8, 0x00) ^ clmul256(y4, k8, 0x11) ^ ld256(p + 96);
            }
            const a: [2]V2 = @bitCast(y1);
            const b: [2]V2 = @bitCast(y2);
            const c: [2]V2 = @bitCast(y3);
            const d: [2]V2 = @bitCast(y4);
            x1 = clmul(a[0], k1k2, 0x00) ^ clmul(a[0], k1k2, 0x11) ^ c[0];
            x2 = clmul(a[1], k1k2, 0x00) ^ clmul(a[1], k1k2, 0x11) ^ c[1];
            x3 = clmul(b[0], k1k2, 0x00) ^ clmul(b[0], k1k2, 0x11) ^ d[0];
            x4 = clmul(b[1], k1k2, 0x00) ^ clmul(b[1], k1k2, 0x11) ^ d[1];
        }
        while (len >= 64) : ({
            p += 64;
            len -= 64;
        }) {
            x1 = clmul(x1, k1k2, 0x00) ^ clmul(x1, k1k2, 0x11) ^ ld128(p);
            x2 = clmul(x2, k1k2, 0x00) ^ clmul(x2, k1k2, 0x11) ^ ld128(p + 16);
            x3 = clmul(x3, k1k2, 0x00) ^ clmul(x3, k1k2, 0x11) ^ ld128(p + 32);
            x4 = clmul(x4, k1k2, 0x00) ^ clmul(x4, k1k2, 0x11) ^ ld128(p + 48);
        }
        x1 = clmul(x1, k3k4, 0x00) ^ clmul(x1, k3k4, 0x11) ^ x2;
        x1 = clmul(x1, k3k4, 0x00) ^ clmul(x1, k3k4, 0x11) ^ x3;
        x1 = clmul(x1, k3k4, 0x00) ^ clmul(x1, k3k4, 0x11) ^ x4;
        while (len >= 16) : ({
            p += 16;
            len -= 16;
        }) x1 = clmul(x1, k3k4, 0x00) ^ clmul(x1, k3k4, 0x11) ^ ld128(p);
        // 128 -> 64 bits (adds 32 zero bits), then 64 -> 32 by Barrett reduction
        x1 = clmul(k3k4, x1, 0x01) ^ V2{ x1[1], 0 };
        const x = @as(u128, @bitCast(x1));
        x1 = clmul(x1 & mask32, k5, 0x00) ^ @as(V2, @bitCast(x >> 32));
        var x2b = clmul(x1 & mask32, poly_mu, 0x10) & mask32;
        x2b = clmul(x2b, poly_mu, 0x00);
        x1 ^= x2b;
        crc = @truncate(x1[0] >> 32);
    }
    for (p[0..len]) |byte| crc = crc_table[(crc ^ byte) & 0xff] ^ (crc >> 8);
    return ~crc;
}

test "crc32 matches std" {
    detectCpu();
    try crc32Both();
    has_vpclmul = false;
    try crc32Both();
    detectCpu();
}

fn crc32Both() !void {
    var buf: [5000]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(&buf);
    for ([_]usize{ 0, 1, 15, 16, 63, 64, 65, 127, 128, 129, 191, 192, 193, 200, 255, 256, 1000, 4999, 5000 }) |n|
        try std.testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), crc32(buf[0..n]));
}

test "encode inflates back" {
    const body = "{\"articles\":[{\"slug\":\"a-b\",\"title\":\"A B\",\"createdAt\":\"2026-08-31T23:58:47.487Z\",\"updatedAt\":\"2026-08-31T23:58:47.487Z\"},{\"slug\":\"c-d\",\"title\":\"C D\",\"createdAt\":\"2026-08-30T23:58:47.487Z\",\"updatedAt\":\"2026-08-30T23:58:47.487Z\"}],\"articlesCount\":2}";
    var in: [body.len + 3]u8 = undefined;
    @memcpy(in[0..body.len], body);
    var out: [outBound(body.len)]u8 = undefined;
    for ([_]usize{ 0, 150, 200 }) |budget| {
        const m = encode(in[0..body.len], &out, budget);
        var r: std.Io.Reader = .fixed(out[0..m]);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var d: std.compress.flate.Decompress = .init(&r, .gzip, &window);
        var got: [body.len + 16]u8 = undefined;
        const nread = try d.reader.readSliceShort(&got);
        try std.testing.expectEqualStrings(body, got[0..nread]);
    }
}
