//! JSON response writer: appends to a Buf; strings are escaped with a vectorised scan.
const std = @import("std");
const Buf = @import("buf.zig").Buf;

const V32 = @Vector(32, u8);

inline fn escapeOne(dst: [*]u8, c: u8) usize {
    const hex = "0123456789abcdef";
    switch (c) {
        '"' => dst[0..2].* = .{ '\\', '"' },
        '\\' => dst[0..2].* = .{ '\\', '\\' },
        '\n' => dst[0..2].* = .{ '\\', 'n' },
        '\r' => dst[0..2].* = .{ '\\', 'r' },
        '\t' => dst[0..2].* = .{ '\\', 't' },
        else => {
            dst[0..6].* = .{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] };
            return 6;
        },
    }
    return 2;
}

pub fn escapeInto(dst0: [*]u8, s: []const u8) usize {
    var dst = dst0;
    var i: usize = 0;
    const lo: V32 = @splat(0x20);
    const quote: V32 = @splat('"');
    const back: V32 = @splat('\\');
    while (i + 32 <= s.len) {
        const v: V32 = s[i..][0..32].*;
        const mask: u32 = @bitCast((v < lo) | (v == quote) | (v == back));
        dst[0..32].* = v;
        if (mask == 0) {
            dst += 32;
            i += 32;
            continue;
        }
        const k = @ctz(mask);
        dst += k;
        i += k;
        dst += escapeOne(dst, s[i]);
        i += 1;
    }
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < 0x20 or c == '"' or c == '\\') {
            dst += escapeOne(dst, c);
        } else {
            dst[0] = c;
            dst += 1;
        }
    }
    return dst - dst0;
}

/// Append `s` as the contents of a JSON string (no surrounding quotes).
pub fn putEscaped(b: *Buf, s: []const u8) void {
    b.ensure(6 * s.len + 32);
    const n = escapeInto(b.ptr + b.len, s);
    b.len += n;
}

pub inline fn str(b: *Buf, s: []const u8) void {
    b.ensure(s.len + 2);
    b.put('"');
    putEscaped(b, s);
    b.put('"');
}

const digits2: [200]u8 = blk: {
    var t: [200]u8 = undefined;
    for (0..100) |i| {
        t[2 * i] = '0' + @as(u8, @intCast(i / 10));
        t[2 * i + 1] = '0' + @as(u8, @intCast(i % 10));
    }
    break :blk t;
};

inline fn put2(dst: []u8, v: u64) void {
    dst[0..2].* = digits2[2 * @as(usize, @intCast(v)) ..][0..2].*;
}

pub fn putUint(b: *Buf, v: u64) void {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var x = v;
    while (x >= 100) {
        const q = x / 100;
        const r: usize = @intCast(x - q * 100);
        i -= 2;
        tmp[i..][0..2].* = digits2[2 * r ..][0..2].*;
        x = q;
    }
    if (x >= 10) {
        i -= 2;
        tmp[i..][0..2].* = digits2[2 * @as(usize, @intCast(x)) ..][0..2].*;
    } else {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(x));
    }
    b.putSlice(tmp[i..]);
}

pub fn putInt(b: *Buf, v: i64) void {
    if (v < 0) {
        b.put('-');
        putUint(b, @as(u64, @intCast(-(v + 1))) + 1);
    } else putUint(b, @intCast(v));
}

/// Calendar date (year, month, day) of a day count since 0000-03-01 (proleptic Gregorian), unsigned arithmetic only.
inline fn civil(z: u64) struct { y: u64, m: u64, d: u64 } {
    const era = z / 146097;
    const doe = z - era * 146097;
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @intFromBool(m <= 2), .m = m, .d = d };
}

threadlocal var last_day: u64 = std.math.maxInt(u64);
threadlocal var last_date: [11]u8 = undefined; // `"YYYY-MM-DD`

/// Postgres timestamptz (binary: microseconds since 2000-01-01 UTC) as RFC 3339 with 3 fractional digits.
pub fn putTimestamp(b: *Buf, pg_micros: i64) void {
    if (pg_micros < 0 or pg_micros >= 2_900_000 * 86_400_000_000) return putTimestampSlow(b, pg_micros);
    b.ensure(32);
    const us: u64 = @intCast(pg_micros);
    const days = us / 86_400_000_000;
    const rem = us - days * 86_400_000_000;
    if (days != last_day) {
        const c = civil(days + 10957 + 719468);
        last_date[0] = '"';
        put2(last_date[1..3], c.y / 100);
        put2(last_date[3..5], c.y % 100);
        last_date[5] = '-';
        put2(last_date[6..8], c.m);
        last_date[8] = '-';
        put2(last_date[9..11], c.d);
        last_day = days;
    }
    const secs = rem / 1_000_000;
    const ms = (rem - secs * 1_000_000) / 1000;
    const hh = secs / 3600;
    const mm = (secs - hh * 3600) / 60;
    const ss = secs - hh * 3600 - mm * 60;
    const o = b.ptr + b.len;
    o[0..11].* = last_date;
    o[11] = 'T';
    put2(o[12..14], hh);
    o[14] = ':';
    put2(o[15..17], mm);
    o[17] = ':';
    put2(o[18..20], ss);
    o[20] = '.';
    const msh = ms / 100;
    o[21] = '0' + @as(u8, @intCast(msh));
    put2(o[22..24], ms - msh * 100);
    o[24] = 'Z';
    o[25] = '"';
    b.len += 26;
}

pub fn putTimestampSlow(b: *Buf, pg_micros: i64) void {
    const us_per_day: i64 = 86_400_000_000;
    const days = @divFloor(pg_micros, us_per_day);
    const rem: u64 = @intCast(pg_micros - days * us_per_day);
    const z: i64 = days + 10957 + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    if (m <= 2) y += 1;
    const secs = rem / 1_000_000;
    const ms = (rem % 1_000_000) / 1000;
    const hh = secs / 3600;
    const mm = (secs / 60) % 60;
    const ss = secs % 60;
    var o: [26]u8 = undefined;
    const yy: u64 = @intCast(@max(0, @min(9999, y)));
    o[0] = '"';
    put2(o[1..3], yy / 100);
    put2(o[3..5], yy % 100);
    o[5] = '-';
    put2(o[6..8], @intCast(m));
    o[8] = '-';
    put2(o[9..11], @intCast(d));
    o[11] = 'T';
    put2(o[12..14], hh);
    o[14] = ':';
    put2(o[15..17], mm);
    o[17] = ':';
    put2(o[18..20], ss);
    o[20] = '.';
    o[21] = '0' + @as(u8, @intCast(ms / 100));
    put2(o[22..24], ms % 100);
    o[24] = 'Z';
    o[25] = '"';
    b.putSlice(&o);
}

test "escape" {
    var b = try Buf.init(16);
    defer b.deinit();
    putEscaped(&b, "plain text that is long enough to need several vector chunks 0123456789 and then \"quoted\" \\ back\nslash\x01 end");
    try std.testing.expectEqualStrings("plain text that is long enough to need several vector chunks 0123456789 and then \\\"quoted\\\" \\\\ back\\nslash\\u0001 end", b.slice());
    b.reset();
    putEscaped(&b, "");
    try std.testing.expectEqual(@as(usize, 0), b.len);
    b.reset();
    putEscaped(&b, "ünïcode ✓ ok");
    try std.testing.expectEqualStrings("ünïcode ✓ ok", b.slice());
}

test "fused escape matches scalar encoding at every vector boundary" {
    var actual = try Buf.init(4);
    defer actual.deinit();
    var expected = try Buf.init(4);
    defer expected.deinit();
    var input: [257]u8 = undefined;
    for (0..128) |shift| {
        for (&input, 0..) |*c, i| c.* = @truncate((i + shift) * 37);
        for (0..input.len + 1) |n| {
            actual.reset();
            expected.reset();
            actual.putSlice("prefix");
            expected.putSlice("prefix");
            putEscaped(&actual, input[0..n]);
            for (input[0..n]) |c| switch (c) {
                '"' => expected.putSlice("\\\""),
                '\\' => expected.putSlice("\\\\"),
                '\n' => expected.putSlice("\\n"),
                '\r' => expected.putSlice("\\r"),
                '\t' => expected.putSlice("\\t"),
                else => if (c < 0x20) {
                    const hex = "0123456789abcdef";
                    expected.putSlice(&.{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
                } else expected.put(c),
            };
            try std.testing.expectEqualSlices(u8, expected.slice(), actual.slice());
        }
    }
}

test "timestamp" {
    var b = try Buf.init(32);
    defer b.deinit();
    // 2025-04-01T12:00:00.123456Z -> micros since 2000-01-01
    const days_2000_to_20250401: i64 = 9222; // 25 years * 365 + 7 leap days + 90 days
    const pg: i64 = days_2000_to_20250401 * 86_400_000_000 + 12 * 3_600_000_000 + 123456;
    putTimestamp(&b, pg);
    try std.testing.expectEqualStrings("\"2025-04-01T12:00:00.123Z\"", b.slice());
    b.reset();
    putTimestamp(&b, 0);
    try std.testing.expectEqualStrings("\"2000-01-01T00:00:00.000Z\"", b.slice());
    b.reset();
    putTimestamp(&b, -1); // 1999-12-31T23:59:59.999999
    try std.testing.expectEqualStrings("\"1999-12-31T23:59:59.999Z\"", b.slice());
    b.reset();
    putTimestamp(&b, 825_638_400_000_000); // 2026-03-01 00:00 -> check leap logic around Feb/Mar
    try std.testing.expectEqualStrings("\"2026-03-01T00:00:00.000Z\"", b.slice());
}
