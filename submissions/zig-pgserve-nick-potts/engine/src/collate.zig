//! Text order under a column's collation, as varstr_cmp gives it (bttextcmp, ORDER BY), with a shortcut.
//!
//! Under a libc collation such as en_US.UTF-8 varstr_cmp is strcoll, which costs hundreds of instructions
//! per call: a username descent makes about twenty. Strings of ASCII digits and lowercase letters
//! ("plain") are what the seed's usernames and tag names are made of, and collations like en_US.UTF-8 and
//! C.UTF-8 order plain strings exactly as their bytes. Two plain strings then compare with memcmp.
//!
//! A collation earns the shortcut by a test at schema load, once per backend: every plain string of up to
//! three characters, in byte order, must come out strictly ascending under varstr_cmp itself. A collation
//! with a contraction, an ignorable or a reordering among these characters fails it (a contraction of
//! two or three characters puts some string out of place) and keeps varstr_cmp for everything. A string
//! that is not plain always goes to varstr_cmp.

const std = @import("std");
const c = @import("pg_c");

const ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyz"; // byte order
const DEPTH = 3;

/// Collations tested in this backend and whether each passed. A database's text columns share one or two.
var tested: [4]struct { coll: c.Oid, ok: bool } = undefined;
var ntested: usize = 0;

/// Whether s is ASCII digits and lowercase letters only. Runs on every entry a text descent compares, so
/// 16 bytes at a time.
pub inline fn plain(s: []const u8) bool {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= s.len) : (i += 16) {
        const v: V = s[i..][0..16].*;
        const digit = v -% @as(V, @splat('0')) < @as(V, @splat(10));
        const lower = v -% @as(V, @splat('a')) < @as(V, @splat(26));
        if (!@reduce(.And, @select(bool, digit, digit, lower))) return false;
    }
    for (s[i..]) |b| if (!((b -% '0') < 10 or (b -% 'a') < 26)) return false;
    return true;
}

/// Whether plain strings order bytewise under `coll`: tested on first ask in a backend.
pub fn bytewise(coll: c.Oid) bool {
    for (tested[0..ntested]) |t| if (t.coll == coll) return t.ok;
    const ok = selfTest(coll);
    if (ntested < tested.len) {
        tested[ntested] = .{ .coll = coll, .ok = ok };
        ntested += 1;
    }
    return ok;
}

fn selfTest(coll: c.Oid) bool {
    var cur: [DEPTH]u8 = undefined;
    var prev: [DEPTH]u8 = undefined;
    var plen: usize = 0;
    return walk(coll, &cur, 0, &prev, &plen);
}

/// The plain strings under cur[0..depth] in preorder (a prefix before its extensions, siblings in byte
/// order), which is byte order: each must compare above the one before it.
fn walk(coll: c.Oid, cur: *[DEPTH]u8, depth: usize, prev: *[DEPTH]u8, plen: *usize) bool {
    for (ALPHABET) |ch| {
        cur[depth] = ch;
        const s = cur[0 .. depth + 1];
        if (c.varstr_cmp(prev, @intCast(plen.*), s.ptr, @intCast(s.len), coll) >= 0) return false;
        @memcpy(prev[0..s.len], s);
        plen.* = s.len;
        if (depth + 1 < DEPTH and !walk(coll, cur, depth + 1, prev, plen)) return false;
    }
    return true;
}

test "plain is ASCII digits and lowercase letters" {
    try std.testing.expect(plain("stetrentraitet51678"));
    try std.testing.expect(plain("0123456789abcdefghijklmnopqrstuvwxyz0123456789"));
    try std.testing.expect(!plain("0123456789abcdeF"));
    try std.testing.expect(!plain("0123456789abcdef/"));
    try std.testing.expect(!plain("0123456789abcdef:0123456789abcdef"));
    try std.testing.expect(!plain("`0123456789abcdef"));
    try std.testing.expect(!plain("{0123456789abcdef"));
    try std.testing.expect(plain(""));
    try std.testing.expect(!plain("Bb"));
    try std.testing.expect(!plain("a-b"));
    try std.testing.expect(!plain("a b"));
    try std.testing.expect(!plain("\xc3\xa9"));
}
