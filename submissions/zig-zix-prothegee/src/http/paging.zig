//! List paging parsed from the query string.

const std = @import("std");

// --------------------------------------------------------- //

pub const Paging = struct {
    limit: i64,
    offset: i64,
};

pub const Error = error{InvalidPaging};

const LIMIT_DEFAULT: i64 = 20;
const LIMIT_MIN: i64 = 1;
const LIMIT_MAX: i64 = 100;
const OFFSET_DEFAULT: i64 = 0;

// --------------------------------------------------------- //

fn parseLimit(text: ?[]const u8) Error!i64 {
    const raw = text orelse return LIMIT_DEFAULT;

    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidPaging;
    if (value < LIMIT_MIN or value > LIMIT_MAX) return error.InvalidPaging;

    return value;
}

fn parseOffset(text: ?[]const u8) Error!i64 {
    const raw = text orelse return OFFSET_DEFAULT;

    const value = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidPaging;
    if (value < 0) return error.InvalidPaging;

    return value;
}

// --------------------------------------------------------- //

/// Parse `limit` and `offset`. Missing values use the spec defaults.
pub fn parse(limit_text: ?[]const u8, offset_text: ?[]const u8) Error!Paging {
    return .{
        .limit = try parseLimit(limit_text),
        .offset = try parseOffset(offset_text),
    };
}

// --------------------------------------------------------- //

test "paging: missing values use the defaults" {
    const paging = try parse(null, null);

    try std.testing.expectEqual(@as(i64, 20), paging.limit);
    try std.testing.expectEqual(@as(i64, 0), paging.offset);
}

test "paging: valid values are kept" {
    const paging = try parse("10", "5");

    try std.testing.expectEqual(@as(i64, 10), paging.limit);
    try std.testing.expectEqual(@as(i64, 5), paging.offset);
}

test "paging: the bounds are inclusive" {
    const low = try parse("1", "0");
    const high = try parse("100", "1000");

    try std.testing.expectEqual(@as(i64, 1), low.limit);
    try std.testing.expectEqual(@as(i64, 0), low.offset);
    try std.testing.expectEqual(@as(i64, 100), high.limit);
    try std.testing.expectEqual(@as(i64, 1000), high.offset);
}

test "paging: a zero limit is invalid" {
    try std.testing.expectError(error.InvalidPaging, parse("0", null));
}

test "paging: a limit above 100 is invalid" {
    try std.testing.expectError(error.InvalidPaging, parse("101", null));
}

test "paging: a negative offset is invalid" {
    try std.testing.expectError(error.InvalidPaging, parse(null, "-1"));
}

test "paging: a non-numeric value is invalid" {
    try std.testing.expectError(error.InvalidPaging, parse("ten", null));
    try std.testing.expectError(error.InvalidPaging, parse(null, "five"));
}

test "paging: an overflowing value is invalid" {
    try std.testing.expectError(error.InvalidPaging, parse("99999999999999999999", null));
}

test "paging: an empty value is invalid" {
    try std.testing.expectError(error.InvalidPaging, parse("", null));
}
