const std = @import("std");

pub fn pathSegment(allocator: std.mem.Allocator, encoded: []const u8) ![:0]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (encoded.len - i < 3) return error.InvalidPath;
            const high = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidPath;
            const low = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidPath;
            i += 2;
            break :blk high * 16 + low;
        } else encoded[i];
        if (byte == 0) return error.Validation;
        try decoded.append(allocator, byte);
    }
    if (decoded.items.len == 0 or !std.unicode.utf8ValidateSlice(decoded.items)) return error.Validation;
    return allocator.dupeSentinel(u8, decoded.items, 0);
}

test "username path decoding is single-pass, preserves plus and validates text" {
    const a = std.testing.allocator;
    const decoded = try pathSegment(a, "a+%20%2F%C3%A9%252F");
    defer a.free(decoded);
    try std.testing.expectEqualStrings("a+ /é%2F", decoded);
    try std.testing.expectError(error.InvalidPath, pathSegment(a, "bad%2"));
    try std.testing.expectError(error.InvalidPath, pathSegment(a, "bad%GG"));
    try std.testing.expectError(error.Validation, pathSegment(a, "bad%00"));
    try std.testing.expectError(error.Validation, pathSegment(a, "%FF"));
}

pub const Query = struct {
    limit: i64 = 20,
    offset: i64 = 0,
    filter: enum { all, tag, author, favorited } = .all,
    value: ?[:0]const u8 = null,
};

fn queryPart(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var i: usize = 0;
    while (i < encoded.len) : (i += 1) {
        const byte = if (encoded[i] == '%') blk: {
            if (encoded.len - i < 3) return error.InvalidEncoding;
            const high = std.fmt.charToDigit(encoded[i + 1], 16) catch return error.InvalidEncoding;
            const low = std.fmt.charToDigit(encoded[i + 2], 16) catch return error.InvalidEncoding;
            i += 2;
            break :blk high * 16 + low;
        } else if (encoded[i] == '+') ' ' else encoded[i];
        try bytes.append(allocator, byte);
    }
    return bytes.toOwnedSlice(allocator);
}

fn unsigned(text: []const u8) !i64 {
    if (text.len == 0) return error.Validation;
    for (text) |ch| if (ch < '0' or ch > '9') return error.Validation;
    return std.fmt.parseInt(i64, text, 10) catch error.Validation;
}

// Match Go URL.Query's first-value semantics, including ignored malformed pairs.
// The caller supplies a request arena; decoded fields live until request completion.
pub fn query(allocator: std.mem.Allocator, raw: []const u8, include_filters: bool) !Query {
    const keys = [_][]const u8{ "limit", "offset", "tag", "author", "favorited" };
    var values: [keys.len]?[]const u8 = @splat(null);
    var pairs = std.mem.splitScalar(u8, raw, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0 or std.mem.indexOfScalar(u8, pair, ';') != null) continue;
        const end = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = queryPart(allocator, pair[0..end]) catch |err| switch (err) {
            error.InvalidEncoding => continue,
            else => return err,
        };
        const index = for (keys, 0..) |candidate, i| {
            if (std.mem.eql(u8, key, candidate)) break i;
        } else continue;
        if (values[index] != null or (!include_filters and index >= 2)) continue;
        values[index] = queryPart(allocator, if (end < pair.len) pair[end + 1 ..] else "") catch |err| switch (err) {
            error.InvalidEncoding => continue,
            else => return err,
        };
    }
    var result: Query = .{};
    if (values[0]) |value| result.limit = try unsigned(value);
    if (values[1]) |value| result.offset = try unsigned(value);
    if (result.limit < 1 or result.limit > 100) return error.Validation;
    for (values[2..], 0..) |value, i| {
        if (value) |text| {
            if (text.len == 0) continue;
            if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.Validation;
            result.filter = switch (i) {
                0 => .tag,
                1 => .author,
                else => .favorited,
            };
            result.value = try allocator.dupeSentinel(u8, text, 0);
            break;
        }
    }
    return result;
}

test "pagination and filters preserve first values, precedence and numeric bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const selected = try query(a, "limit=05&limit=0&offset=9223372036854775807&tag=&tag=ignored&author=a%2Bb+c&favorited=x", true);
    try std.testing.expectEqual(@as(i64, 5), selected.limit);
    try std.testing.expectEqual(std.math.maxInt(i64), selected.offset);
    try std.testing.expectEqualStrings("a+b c", selected.value.?);
    try std.testing.expect(selected.filter == .author);
    for ([_][]const u8{ "limit=0", "limit=101", "limit", "limit=%2B5", "offset=-1", "offset=9223372036854775808" }) |raw| {
        try std.testing.expectError(error.Validation, query(a, raw, true));
    }
    try std.testing.expectEqual(@as(i64, 20), (try query(a, "limit=%GG&limit=20;bad&unknown=1", true)).limit);
}
