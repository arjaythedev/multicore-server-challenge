//! The response byte buffer and the two encoders whose output must match Postgres exactly.
//!
//! `escapeJson` reproduces escape_json_char (backend/utils/adt/json.c): control bytes below 0x20 that
//! lack a short escape become \u00XX in lowercase hex, and the five named escapes plus " and \ are
//! emitted literally. Everything else, UTF-8 included, is copied byte for byte, exactly as Postgres's
//! json output does over the column's text.
//!
//! `writeTimestamp` renders a timestamptz the way SPEC.md requires and the reference server produces:
//! RFC 3339 UTC with exactly three fractional digits, truncated. It works from the raw int64 the column
//! holds (microseconds since 2000-01-01 UTC), so there is no call into Postgres's datetime code.

const std = @import("std");
const c = @import("pg_c");

pub const Buf = struct {
    ptr: [*]u8,
    len: usize = 0,
    cap: usize,

    pub fn init(cap: usize) Buf {
        return .{ .ptr = @ptrCast(c.shim_palloc(cap)), .cap = cap };
    }

    /// A buffer whose first four bytes are reserved for a varlena header, so the finished body is a
    /// bytea Datum in place, with no copy.
    pub fn initBytea(cap: usize) Buf {
        var b = init(cap);
        b.len = 4;
        return b;
    }

    /// Write the 4-byte uncompressed varlena header (SET_VARSIZE_4B, little-endian) and return the Datum.
    pub fn finishBytea(self: *Buf) usize {
        comptime std.debug.assert(@import("builtin").cpu.arch.endian() == .little);
        std.mem.writeInt(u32, self.ptr[0..4], @as(u32, @intCast(self.len)) << 2, .little);
        return @intFromPtr(self.ptr);
    }

    pub inline fn ensure(self: *Buf, extra: usize) void {
        if (self.len + extra <= self.cap) return;
        var ncap = self.cap * 2;
        while (ncap < self.len + extra) ncap *= 2;
        const np: [*]u8 = @ptrCast(c.shim_repalloc(self.ptr, ncap));
        self.ptr = np;
        self.cap = ncap;
    }

    pub inline fn byte(self: *Buf, b: u8) void {
        self.ensure(1);
        self.ptr[self.len] = b;
        self.len += 1;
    }

    pub inline fn raw(self: *Buf, s: []const u8) void {
        self.ensure(s.len);
        @memcpy(self.ptr[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    pub fn int(self: *Buf, v: i64) void {
        var tmp: [20]u8 = undefined;
        const s = std.mem.print(&tmp, "{d}", .{v}) catch unreachable;
        self.raw(s);
    }

    pub inline fn slice(self: *const Buf) []const u8 {
        return self.ptr[0..self.len];
    }
};

const hex = "0123456789abcdef";

/// Append a JSON string (with the surrounding quotes), escaped exactly like Postgres.
pub fn escapeJson(buf: *Buf, s: []const u8) void {
    buf.ensure(s.len + 2);
    buf.byte('"');
    var start: usize = 0;
    var i = nextEscape(s, 0);
    while (i < s.len) : (i = nextEscape(s, i)) {
        const b = s[i];
        if (i > start) buf.raw(s[start..i]);
        switch (b) {
            0x08 => buf.raw("\\b"),
            0x0c => buf.raw("\\f"),
            '\n' => buf.raw("\\n"),
            '\r' => buf.raw("\\r"),
            '\t' => buf.raw("\\t"),
            '"' => buf.raw("\\\""),
            '\\' => buf.raw("\\\\"),
            else => {
                // control byte with no short escape: \u00XX
                buf.raw("\\u00");
                buf.byte(hex[b >> 4]);
                buf.byte(hex[b & 0xf]);
            },
        }
        i += 1;
        start = i;
    }
    if (s.len > start) buf.raw(s[start..]);
    buf.byte('"');
}

inline fn needsEscape(b: u8) bool {
    return b < 0x20 or b == '"' or b == '\\';
}

/// Index of the first byte at or after `from` that needs an escape, or s.len. Text is almost all clean,
/// so it is scanned 32 bytes per step.
fn nextEscape(s: []const u8, from: usize) usize {
    const V = @Vector(32, u8);
    var i = from;
    while (i + 32 <= s.len) : (i += 32) {
        const v: V = s[i..][0..32].*;
        const m = @as(u32, @bitCast(v < @as(V, @splat(0x20)))) |
            @as(u32, @bitCast(v == @as(V, @splat('"')))) |
            @as(u32, @bitCast(v == @as(V, @splat('\\'))));
        if (m != 0) return i + @ctz(m);
    }
    while (i < s.len and !needsEscape(s[i])) i += 1;
    return i;
}

const US_PER_DAY: i64 = 86_400_000_000;
// Days from 0000-03-01 (proleptic Gregorian) to 2000-01-01, the Postgres epoch: 719468 + 10957.
const PG_EPOCH_SHIFT: i64 = 730_425;

inline fn digit(buf: *Buf, v: i64) void {
    buf.ptr[buf.len] = '0' + @as(u8, @intCast(v));
    buf.len += 1;
}

/// `"2025-04-01T12:00:00.000Z"` from a timestamptz Datum (microseconds since 2000-01-01 UTC).
pub fn writeTimestamp(buf: *Buf, micros: i64) void {
    const day = @divFloor(micros, US_PER_DAY);
    const tod = @mod(micros, US_PER_DAY);
    // Howard Hinnant's civil_from_days.
    const z = day + PG_EPOCH_SHIFT;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, if (m <= 2) 1 else 0);
    if (year < 0 or year > 9999) c.shim_ereport_str("timestamp year outside 0000..9999");

    const ms = @divTrunc(tod, 1000);
    const hh = @divTrunc(ms, 3_600_000);
    const mi = @mod(@divTrunc(ms, 60_000), 60);
    const ss = @mod(@divTrunc(ms, 1000), 60);
    const frac = @mod(ms, 1000);

    buf.ensure(26);
    buf.ptr[buf.len] = '"';
    buf.len += 1;
    digit(buf, @divTrunc(year, 1000));
    digit(buf, @mod(@divTrunc(year, 100), 10));
    digit(buf, @mod(@divTrunc(year, 10), 10));
    digit(buf, @mod(year, 10));
    buf.ptr[buf.len] = '-';
    buf.len += 1;
    digit(buf, @divTrunc(m, 10));
    digit(buf, @mod(m, 10));
    buf.ptr[buf.len] = '-';
    buf.len += 1;
    digit(buf, @divTrunc(d, 10));
    digit(buf, @mod(d, 10));
    buf.ptr[buf.len] = 'T';
    buf.len += 1;
    digit(buf, @divTrunc(hh, 10));
    digit(buf, @mod(hh, 10));
    buf.ptr[buf.len] = ':';
    buf.len += 1;
    digit(buf, @divTrunc(mi, 10));
    digit(buf, @mod(mi, 10));
    buf.ptr[buf.len] = ':';
    buf.len += 1;
    digit(buf, @divTrunc(ss, 10));
    digit(buf, @mod(ss, 10));
    buf.ptr[buf.len] = '.';
    buf.len += 1;
    digit(buf, @divTrunc(frac, 100));
    digit(buf, @mod(@divTrunc(frac, 10), 10));
    digit(buf, @mod(frac, 10));
    buf.ptr[buf.len] = 'Z';
    buf.ptr[buf.len + 1] = '"';
    buf.len += 2;
}

test "timestamps match the reference format" {
    var store: [64]u8 = undefined;
    var b = Buf{ .ptr = &store, .cap = store.len };
    writeTimestamp(&b, 0);
    try std.testing.expectEqualStrings("\"2000-01-01T00:00:00.000Z\"", b.slice());
    b.len = 0;
    // 2025-04-01T12:34:56.789999Z, truncated not rounded
    writeTimestamp(&b, 796_826_096_789_999);
    try std.testing.expectEqualStrings("\"2025-04-01T12:34:56.789Z\"", b.slice());
    b.len = 0;
    // before the epoch: 1999-12-31T23:59:59.999Z
    writeTimestamp(&b, -1);
    try std.testing.expectEqualStrings("\"1999-12-31T23:59:59.999Z\"", b.slice());
    b.len = 0;
    // leap day 2024-02-29T00:00:00.000Z
    writeTimestamp(&b, 762_480_000_000_000);
    try std.testing.expectEqualStrings("\"2024-02-29T00:00:00.000Z\"", b.slice());
}

test "escaping matches Postgres escape_json" {
    var store: [128]u8 = undefined;
    var b = Buf{ .ptr = &store, .cap = store.len };
    escapeJson(&b, "a\"b\\c\n\r\t\x08\x0c\x01\x1f é/<");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\r\\t\\b\\f\\u0001\\u001f é/<\"", b.slice());
}

test "escaping finds every special byte at every offset of the vector scan" {
    var store: [512]u8 = undefined;
    var want: [512]u8 = undefined;
    const specials = "\"\\\n\x01\x1f";
    for (0..80) |len| {
        for (0..len) |pos| {
            for (specials) |sp| {
                var src: [80]u8 = undefined;
                for (src[0..len], 0..) |*ch, k| ch.* = 'a' + @as(u8, @intCast(k % 26));
                src[pos] = sp;
                var b = Buf{ .ptr = &store, .cap = store.len };
                escapeJson(&b, src[0..len]);
                // the scalar rule, byte by byte
                var w: usize = 0;
                want[w] = '"';
                w += 1;
                for (src[0..len]) |ch| {
                    const e: []const u8 = switch (ch) {
                        '"' => "\\\"",
                        '\\' => "\\\\",
                        '\n' => "\\n",
                        0x01 => "\\u0001",
                        0x1f => "\\u001f",
                        else => &[_]u8{ch},
                    };
                    @memcpy(want[w .. w + e.len], e);
                    w += e.len;
                }
                want[w] = '"';
                w += 1;
                try std.testing.expectEqualStrings(want[0..w], b.slice());
            }
        }
    }
}
