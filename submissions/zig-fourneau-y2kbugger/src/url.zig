//! A request target's parts as Go's `net/http` gives them to the reference
//! server: path segments percent-decoded, query values decoded with `+` as
//! a space, the first of a repeated key winning.

const std = @import("std");
const assert = std.debug.assert;

/// `text` with every %XX decoded into `out`; with `plus_is_space`, `+` is a
/// space (a query's form encoding). Null: a malformed escape, or no room.
pub fn decode(text: []const u8, out: []u8, plus_is_space: bool) ?[]const u8 {
    var used: usize = 0;
    var index: usize = 0;
    // Bounded: each pass consumes a byte or an escape.
    for (0..text.len + 1) |_| {
        if (index == text.len) break;
        if (used == out.len) return null;
        const byte = text[index];
        if (byte == '%') {
            if (index + 3 > text.len) return null;
            const high = hex(text[index + 1]) orelse return null;
            const low = hex(text[index + 2]) orelse return null;
            out[used] = high << 4 | low;
            index += 3;
        } else {
            out[used] = if (plus_is_space and byte == '+') ' ' else byte;
            index += 1;
        }
        used += 1;
    } else unreachable;
    return out[0..used];
}

fn hex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// The first value of `key` in a raw query (`a=1&b=2`), decoded into
/// `out`; `.absent` if the key is not there; `.invalid` if malformed.
pub const Lookup = union(enum) { absent, value: []const u8, invalid };

pub fn query_value(query: []const u8, key: []const u8, out: []u8) Lookup {
    var pairs = std.mem.splitScalar(u8, query, '&');
    var key_buffer: [64]u8 = undefined;
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (equals) |index| pair[0..index] else pair;
        const raw_value = if (equals) |index| pair[index + 1 ..] else "";
        const decoded_key = decode(raw_key, &key_buffer, true) orelse continue;
        if (!std.mem.eql(u8, decoded_key, key)) continue;
        const value = decode(raw_value, out, true) orelse return .invalid;
        return .{ .value = value };
    }
    return .absent;
}

const testing = std.testing;

test "url: decoding and query values" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("a b+c", decode("a%20b+c", &buffer, false).?);
    try testing.expectEqualStrings("a b c", decode("a%20b+c", &buffer, true).?);
    try testing.expect(decode("%2", &buffer, false) == null);
    try testing.expect(decode("%zz", &buffer, false) == null);
    const query = "limit=05&offset=&tag=a+b&limit=7&plus=%2B5";
    try testing.expectEqualStrings("05", query_value(query, "limit", &buffer).value);
    try testing.expectEqualStrings("", query_value(query, "offset", &buffer).value);
    try testing.expectEqualStrings("a b", query_value(query, "tag", &buffer).value);
    try testing.expectEqualStrings("+5", query_value(query, "plus", &buffer).value);
    try testing.expect(query_value(query, "author", &buffer) == .absent);
}
