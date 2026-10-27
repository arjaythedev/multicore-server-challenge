//! JSON response writer: appends to a Buf; strings are escaped with a vectorised scan.
const std = @import("std");
const Buf = @import("buf.zig").Buf;

const vlen = std.simd.suggestVectorLength(u8) orelse 16;
const V = @Vector(vlen, u8);

/// Append `s` as the contents of a JSON string (no surrounding quotes).
pub fn putEscaped(b: *Buf, s: []const u8) void {
    b.ensure(s.len);
    var i: usize = 0;
    while (true) {
        // Skip clean chunks a vector at a time.
        while (i + vlen <= s.len) {
            const v: V = s[i..][0..vlen].*;
            const bad = (v < @as(V, @splat(0x20))) | (v == @as(V, @splat('"'))) | (v == @as(V, @splat('\\')));
            if (@reduce(.Or, bad)) break;
            b.ptr[b.len..][0..vlen].* = v;
            b.len += vlen;
            i += vlen;
        }
        const start = i;
        // Find the exact byte (scalar) in this chunk or the tail.
        const end = @min(s.len, i + vlen);
        while (i < end) : (i += 1) {
            const c = s[i];
            if (c < 0x20 or c == '"' or c == '\\') break;
        }
        b.putSlice(s[start..i]);
        if (i >= s.len) break;
        if (i == end and end < s.len) continue; // chunk was clean after all; resume vector scan
        const c = s[i];
        if (c >= 0x20 and c != '"' and c != '\\') {
            continue;
        }
        switch (c) {
            '"' => b.putSlice("\\\""),
            '\\' => b.putSlice("\\\\"),
            '\n' => b.putSlice("\\n"),
            '\r' => b.putSlice("\\r"),
            '\t' => b.putSlice("\\t"),
            else => {
                const hex = "0123456789abcdef";
                b.putSlice(&[6]u8{ '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15] });
            },
        }
        i += 1;
        // Escapes may have grown the buffer; reserve the remaining clean input again.
        b.ensure(s.len - i);
    }
}

pub inline fn str(b: *Buf, s: []const u8) void {
    b.ensure(s.len + 2);
    b.put('"');
    putEscaped(b, s);
    b.put('"');
}

pub fn putUint(b: *Buf, v: u64) void {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var x = v;
    while (true) {
        i -= 1;
        tmp[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        if (x == 0) break;
    }
    b.putSlice(tmp[i..]);
}

pub fn putInt(b: *Buf, v: i64) void {
    if (v < 0) {
        b.put('-');
        putUint(b, @as(u64, @intCast(-(v + 1))) + 1);
    } else putUint(b, @intCast(v));
}

/// Postgres timestamptz (binary: microseconds since 2000-01-01 UTC) as RFC 3339 with 3 fractional digits.
pub fn putTimestamp(b: *Buf, pg_micros: i64) void {
    const us_per_day: i64 = 86_400_000_000;
    const days = @divFloor(pg_micros, us_per_day);
    const rem: u64 = @intCast(pg_micros - days * us_per_day);
    // civil from days (days since 2000-01-01 -> days since 0000-03-01 shift)
    const z: i64 = days + 10957 + 719468; // 10957 days from 1970-01-01 to 2000-01-01
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
    pair(o[1..3], yy / 100);
    pair(o[3..5], yy % 100);
    o[5] = '-';
    pair(o[6..8], @intCast(m));
    o[8] = '-';
    pair(o[9..11], @intCast(d));
    o[11] = 'T';
    pair(o[12..14], hh);
    o[14] = ':';
    pair(o[15..17], mm);
    o[17] = ':';
    pair(o[18..20], ss);
    o[20] = '.';
    o[21] = '0' + @as(u8, @intCast(ms / 100));
    pair(o[22..24], ms % 100);
    o[24] = 'Z';
    o[25] = '"';
    b.putSlice(&o);
}

const digit_pairs = blk: {
    var pairs: [100][2]u8 = undefined;
    for (&pairs, 0..) |*p, i| p.* = .{ '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)) };
    break :blk pairs;
};

inline fn pair(out: *[2]u8, n: u64) void {
    out.* = digit_pairs[n];
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
