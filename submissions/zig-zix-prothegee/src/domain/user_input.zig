//! Request body parsing and validation for the user and auth endpoints.

const std = @import("std");
const zix = @import("zix");

const jzon = zix.jzon;

// --------------------------------------------------------- //

pub const Register = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
};

pub const Login = struct {
    email: []const u8,
    password: []const u8,
};

pub const Update = struct {
    email: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    bio: ?[]const u8 = null,
    image: ?[]const u8 = null,
};

pub const Error = error{InvalidBody};

// --------------------------------------------------------- //

const RegisterFields = struct {
    username: []const u8,
    email: []const u8,
    password: []const u8,
};

const RegisterBody = struct {
    user: RegisterFields,
};

const LoginFields = struct {
    email: []const u8,
    password: []const u8,
};

const LoginBody = struct {
    user: LoginFields,
};

const UpdateBody = struct {
    user: Update,
};

// --------------------------------------------------------- //

/// Parse a registration body. All three fields must be non-empty strings.
pub fn parseRegister(allocator: std.mem.Allocator, body: []const u8) Error!Register {
    const parsed = jzon.deserialize(RegisterBody, allocator, body, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidBody;
    };

    if (parsed.user.username.len == 0) return error.InvalidBody;
    if (parsed.user.email.len == 0) return error.InvalidBody;
    if (parsed.user.password.len == 0) return error.InvalidBody;

    return .{
        .username = parsed.user.username,
        .email = parsed.user.email,
        .password = parsed.user.password,
    };
}

/// Parse a login body. Both fields must be non-empty strings.
pub fn parseLogin(allocator: std.mem.Allocator, body: []const u8) Error!Login {
    const parsed = jzon.deserialize(LoginBody, allocator, body, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidBody;
    };

    if (parsed.user.email.len == 0) return error.InvalidBody;
    if (parsed.user.password.len == 0) return error.InvalidBody;

    return .{
        .email = parsed.user.email,
        .password = parsed.user.password,
    };
}

/// Parse an update body. Absent and null fields stay null, meaning unchanged.
pub fn parseUpdate(allocator: std.mem.Allocator, body: []const u8) Error!Update {
    const parsed = jzon.deserialize(UpdateBody, allocator, body, .{ .unknown = .SKIP, .strings = .BORROW }) catch {
        return error.InvalidBody;
    };

    return parsed.user;
}

// --------------------------------------------------------- //

test "user_input: a valid registration parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":\"ada\",\"email\":\"ada@example.com\",\"password\":\"password123\"}}",
    );

    try std.testing.expectEqualStrings("ada", input.username);
    try std.testing.expectEqualStrings("ada@example.com", input.email);
    try std.testing.expectEqualStrings("password123", input.password);
}

test "user_input: an empty username is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidBody, parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":\"\",\"email\":\"ada@example.com\",\"password\":\"password123\"}}",
    ));
}

test "user_input: a null password is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidBody, parseRegister(
        arena.allocator(),
        "{\"user\":{\"username\":\"ada\",\"email\":\"ada@example.com\",\"password\":null}}",
    ));
}

test "user_input: a missing user wrapper is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidBody, parseRegister(
        arena.allocator(),
        "{\"username\":\"ada\"}",
    ));
}

test "user_input: an empty body is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidBody, parseRegister(arena.allocator(), ""));
}

test "user_input: a valid login parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseLogin(
        arena.allocator(),
        "{\"user\":{\"email\":\"ada@example.com\",\"password\":\"password123\"}}",
    );

    try std.testing.expectEqualStrings("ada@example.com", input.email);
    try std.testing.expectEqualStrings("password123", input.password);
}

test "user_input: a login without a password is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidBody, parseLogin(
        arena.allocator(),
        "{\"user\":{\"email\":\"ada@example.com\"}}",
    ));
}

test "user_input: an update keeps absent fields null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseUpdate(
        arena.allocator(),
        "{\"user\":{\"bio\":\"hello\"}}",
    );

    try std.testing.expectEqualStrings("hello", input.bio.?);
    try std.testing.expect(input.email == null);
    try std.testing.expect(input.username == null);
    try std.testing.expect(input.password == null);
    try std.testing.expect(input.image == null);
}

test "user_input: an update treats null as unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseUpdate(
        arena.allocator(),
        "{\"user\":{\"bio\":null,\"email\":\"new@example.com\"}}",
    );

    try std.testing.expect(input.bio == null);
    try std.testing.expectEqualStrings("new@example.com", input.email.?);
}

test "user_input: an unknown field is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const input = try parseUpdate(
        arena.allocator(),
        "{\"user\":{\"bio\":\"hi\",\"unknown\":123}}",
    );

    try std.testing.expectEqualStrings("hi", input.bio.?);
}
