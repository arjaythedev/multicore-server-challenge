//! JSON payload shapes for the API endpoints.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const UserView = struct {
    email: []const u8,
    token: []const u8,
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
};

pub const ProfileView = struct {
    username: []const u8,
    bio: ?[]const u8,
    image: ?[]const u8,
    following: bool,
};

const UserEnvelope = struct {
    user: UserView,
};

const ProfileEnvelope = struct {
    profile: ProfileView,
};

const ErrorBody = struct {
    body: []const []const u8,
};

const ErrorEnvelope = struct {
    errors: ErrorBody,
};

const TagsEnvelope = struct {
    tags: []const []const u8,
};

// --------------------------------------------------------- //

/// Render `{"user": User}`.
pub fn renderUser(buf: []u8, user: UserView) !usize {
    return jzon.serialize(buf, UserEnvelope{ .user = user }, .{});
}

/// Render `{"errors": {"body": ["message"]}}`.
pub fn renderError(buf: []u8, message: []const u8) !usize {
    const messages = [_][]const u8{message};

    return jzon.serialize(buf, ErrorEnvelope{ .errors = .{ .body = &messages } }, .{});
}

/// Render `{"tags": ["name", ...]}`.
pub fn renderTags(buf: []u8, names: []const []const u8) !usize {
    return jzon.serialize(buf, TagsEnvelope{ .tags = names }, .{});
}

/// Render `{"profile": Profile}`.
pub fn renderProfile(buf: []u8, profile: ProfileView) !usize {
    return jzon.serialize(buf, ProfileEnvelope{ .profile = profile }, .{});
}

// --------------------------------------------------------- //

test "json: a user renders with a token" {
    var buf: [1024]u8 = undefined;

    const len = try renderUser(&buf, .{
        .email = "ada@example.com",
        .token = "tok",
        .username = "ada",
        .bio = null,
        .image = null,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"email\":\"ada@example.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"username\":\"ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"token\":\"tok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"image\":null") != null);
}

test "json: an error renders the body shape" {
    var buf: [256]u8 = undefined;

    const len = try renderError(&buf, "is invalid");
    const text = buf[0..len];

    try std.testing.expectEqualStrings("{\"errors\":{\"body\":[\"is invalid\"]}}", text);
}

test "json: a bio with quotes and backslashes is escaped" {
    var buf: [1024]u8 = undefined;

    const len = try renderUser(&buf, .{
        .email = "a@b.c",
        .token = "t",
        .username = "u",
        .bio = "say \"hi\" \\ end",
        .image = null,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "say \\\"hi\\\" \\\\ end") != null);

    // The rendered document is still valid JSON.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
}

test "json: a full user renders a small document" {
    var buf: [1024]u8 = undefined;

    const len = try renderUser(&buf, .{
        .email = "zoe@example.com",
        .token = "header.payload.signature",
        .username = "zoe",
        .bio = "hello",
        .image = "https://example.com/zoe.png",
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"image\":\"https://example.com/zoe.png\"") != null);
}

test "json: tags render as an array of names" {
    var buf: [256]u8 = undefined;
    const names = [_][]const u8{ "alpha", "beta" };

    const len = try renderTags(&buf, &names);

    try std.testing.expectEqualStrings("{\"tags\":[\"alpha\",\"beta\"]}", buf[0..len]);
}

test "json: an empty tag list renders an empty array" {
    var buf: [64]u8 = undefined;
    const names = [_][]const u8{};

    const len = try renderTags(&buf, &names);

    try std.testing.expectEqualStrings("{\"tags\":[]}", buf[0..len]);
}

test "json: a profile renders with the following flag" {
    var buf: [512]u8 = undefined;

    const len = try renderProfile(&buf, .{
        .username = "ada",
        .bio = null,
        .image = null,
        .following = true,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"profile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"username\":\"ada\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"image\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"following\":true") != null);
}

test "json: a profile with text fields and a false flag" {
    var buf: [512]u8 = undefined;

    const len = try renderProfile(&buf, .{
        .username = "zoe",
        .bio = "hello",
        .image = "https://example.com/zoe.png",
        .following = false,
    });
    const text = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, text, "\"bio\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"following\":false") != null);
}
