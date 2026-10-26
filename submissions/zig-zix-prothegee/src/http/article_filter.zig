//! Article list filter picked from the query string.

const std = @import("std");

const article_domain = @import("../domain/article.zig");

// --------------------------------------------------------- //

/// Pick the first non-empty filter. An empty value is treated as absent.
pub fn parse(
    tag: ?[]const u8,
    author: ?[]const u8,
    favorited: ?[]const u8,
) article_domain.Filter {
    if (tag) |value| {
        if (value.len > 0) return .{ .TAG = value };
    }

    if (author) |value| {
        if (value.len > 0) return .{ .AUTHOR = value };
    }

    if (favorited) |value| {
        if (value.len > 0) return .{ .FAVORITED = value };
    }

    return .NONE;
}

// --------------------------------------------------------- //

test "article_filter: a tag wins when present" {
    switch (parse("zig", "ada", "bob")) {
        .TAG => |tag| try std.testing.expectEqualStrings("zig", tag),
        else => return error.TestUnexpectedResult,
    }
}

test "article_filter: an empty tag falls through to author" {
    switch (parse("", "ada", "bob")) {
        .AUTHOR => |author| try std.testing.expectEqualStrings("ada", author),
        else => return error.TestUnexpectedResult,
    }
}

test "article_filter: empty tag and author fall through to favorited" {
    switch (parse("", "", "bob")) {
        .FAVORITED => |favorited| try std.testing.expectEqualStrings("bob", favorited),
        else => return error.TestUnexpectedResult,
    }
}

test "article_filter: all empty or missing mean no filter" {
    switch (parse("", "", "")) {
        .NONE => {},
        else => return error.TestUnexpectedResult,
    }

    switch (parse(null, null, null)) {
        .NONE => {},
        else => return error.TestUnexpectedResult,
    }
}
