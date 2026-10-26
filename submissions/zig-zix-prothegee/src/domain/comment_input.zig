//! Request body parsing for the comment endpoints.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const Create = struct {
    body: []const u8,
};

pub const Error = error{InvalidBody};

// --------------------------------------------------------- //

const CreateFields = struct {
    body: []const u8,
};

const CreateBody = struct {
    comment: CreateFields,
};

// --------------------------------------------------------- //

/// Parse a create body. The comment body must be non-empty.
pub fn parseCreate(allocator: std.mem.Allocator, body: []const u8) Error!Create {
    const parsed = jzon.deserialize(CreateBody, allocator, body, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidBody;
    };

    if (parsed.comment.body.len == 0) return error.InvalidBody;

    return .{ .body = parsed.comment.body };
}

// --------------------------------------------------------- //

test "comment_input: a valid body parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try parseCreate(arena.allocator(), "{\"comment\":{\"body\":\"Hello\"}}");

    try std.testing.expectEqualStrings("Hello", input.body);
}

test "comment_input: an empty body is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"comment\":{\"body\":\"\"}}",
    ));
}

test "comment_input: a missing body is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"comment\":{}}",
    ));
}

test "comment_input: a missing wrapper is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"body\":\"Hello\"}",
    ));
}

test "comment_input: an unknown field is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try parseCreate(
        arena.allocator(),
        "{\"comment\":{\"body\":\"Hello\",\"unknown\":123}}",
    );

    try std.testing.expectEqualStrings("Hello", input.body);
}
