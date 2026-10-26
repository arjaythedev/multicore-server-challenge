//! Request body parsing and validation for the article endpoints.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const Create = struct {
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tag_list: []const []const u8,
};

pub const Update = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

pub const Error = error{InvalidBody};

// --------------------------------------------------------- //

const CreateFields = struct {
    title: []const u8,
    description: []const u8,
    body: []const u8,
    tagList: ?[]const []const u8 = null,
};

const CreateBody = struct {
    article: CreateFields,
};

const UpdateFields = struct {
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    body: ?[]const u8 = null,
};

const UpdateBody = struct {
    article: UpdateFields,
};

// --------------------------------------------------------- //

/// Parse a create body. Title, description and body must be non-empty. A
/// present tagList must hold non-empty strings.
pub fn parseCreate(allocator: std.mem.Allocator, body: []const u8) Error!Create {
    const parsed = jzon.deserialize(CreateBody, allocator, body, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidBody;
    };

    if (parsed.article.title.len == 0) return error.InvalidBody;
    if (parsed.article.description.len == 0) return error.InvalidBody;
    if (parsed.article.body.len == 0) return error.InvalidBody;

    const tags = parsed.article.tagList orelse &[_][]const u8{};
    for (tags) |tag| {
        if (tag.len == 0) return error.InvalidBody;
    }

    return .{
        .title = parsed.article.title,
        .description = parsed.article.description,
        .body = parsed.article.body,
        .tag_list = tags,
    };
}

/// Parse an update body. Absent and null fields stay null, meaning unchanged.
pub fn parseUpdate(allocator: std.mem.Allocator, body: []const u8) Error!Update {
    const parsed = jzon.deserialize(UpdateBody, allocator, body, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidBody;
    };

    if (parsed.article.title) |title| {
        if (title.len == 0) return error.InvalidBody;
    }

    return .{
        .title = parsed.article.title,
        .description = parsed.article.description,
        .body = parsed.article.body,
    };
}

// --------------------------------------------------------- //

test "article_input: a valid create body parses with tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try parseCreate(
        arena.allocator(),
        "{\"article\":{\"title\":\"Hello\",\"description\":\"Short\",\"body\":\"Text\",\"tagList\":[\"alpha\",\"beta\"]}}",
    );

    try std.testing.expectEqualStrings("Hello", input.title);
    try std.testing.expectEqualStrings("Short", input.description);
    try std.testing.expectEqualStrings("Text", input.body);
    try std.testing.expectEqual(@as(usize, 2), input.tag_list.len);
    try std.testing.expectEqualStrings("alpha", input.tag_list[0]);
}

test "article_input: a create body without tagList has no tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try parseCreate(
        arena.allocator(),
        "{\"article\":{\"title\":\"Hello\",\"description\":\"Short\",\"body\":\"Text\"}}",
    );

    try std.testing.expectEqual(@as(usize, 0), input.tag_list.len);
}

test "article_input: an empty title is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"article\":{\"title\":\"\",\"description\":\"Short\",\"body\":\"Text\"}}",
    ));
}

test "article_input: an empty description is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"article\":{\"title\":\"Hello\",\"description\":\"\",\"body\":\"Text\"}}",
    ));
}

test "article_input: an empty body field is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"article\":{\"title\":\"Hello\",\"description\":\"Short\",\"body\":\"\"}}",
    ));
}

test "article_input: an empty tag is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(
        arena.allocator(),
        "{\"article\":{\"title\":\"Hello\",\"description\":\"Short\",\"body\":\"Text\",\"tagList\":[\"alpha\",\"\"]}}",
    ));
}

test "article_input: a missing article wrapper is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseCreate(arena.allocator(), "{\"title\":\"Hello\"}"));
}

test "article_input: a partial update keeps absent fields null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try parseUpdate(arena.allocator(), "{\"article\":{\"title\":\"New\"}}");

    try std.testing.expectEqualStrings("New", input.title.?);
    try std.testing.expect(input.description == null);
    try std.testing.expect(input.body == null);
}

test "article_input: an update with null fields is unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const input = try parseUpdate(
        arena.allocator(),
        "{\"article\":{\"title\":null,\"description\":null,\"body\":null}}",
    );

    try std.testing.expect(input.title == null);
    try std.testing.expect(input.description == null);
    try std.testing.expect(input.body == null);
}

test "article_input: an empty update title is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectError(error.InvalidBody, parseUpdate(
        arena.allocator(),
        "{\"article\":{\"title\":\"\"}}",
    ));
}
