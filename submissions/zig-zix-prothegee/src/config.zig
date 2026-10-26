//! Runtime configuration, read from the environment the challenge defines.

const std = @import("std");

// --------------------------------------------------------- //

pub const Config = struct {
    database_url: []const u8,
    jwt_secret: []const u8,
    host: []const u8,
    port: u16,
};

/// Fallbacks used when HOST or PORT is absent.
pub const Defaults = struct {
    host: []const u8 = "127.0.0.1",
    port: []const u8 = "3000",
};

pub const Error = error{
    MissingDatabaseUrl,
    MissingJwtSecret,
    InvalidPort,
};

// --------------------------------------------------------- //

/// Build a Config from optional values, applying `defaults` for HOST and PORT.
pub fn parse(
    database_url: ?[]const u8,
    jwt_secret: ?[]const u8,
    host: ?[]const u8,
    port_text: ?[]const u8,
    defaults: Defaults,
) Error!Config {
    const url = database_url orelse return error.MissingDatabaseUrl;
    const secret = jwt_secret orelse return error.MissingJwtSecret;
    const bound_host = host orelse defaults.host;
    const port = std.fmt.parseInt(u16, port_text orelse defaults.port, 10) catch return error.InvalidPort;

    return .{
        .database_url = url,
        .jwt_secret = secret,
        .host = bound_host,
        .port = port,
    };
}

/// Read DATABASE_URL, JWT_SECRET, HOST and PORT from the process environment.
pub fn load(environ_map: *const std.process.Environ.Map, defaults: Defaults) Error!Config {
    return parse(
        environ_map.get("DATABASE_URL"),
        environ_map.get("JWT_SECRET"),
        environ_map.get("HOST"),
        environ_map.get("PORT"),
        defaults,
    );
}

// --------------------------------------------------------- //

test "config: parse applies the local defaults" {
    const cfg = try parse("postgres://conduit:conduit@127.0.0.1:5432/conduit", "multicore-server-challenge", null, null, .{});

    try std.testing.expectEqualStrings("127.0.0.1", cfg.host);
    try std.testing.expectEqual(@as(u16, 3000), cfg.port);
}

test "config: parse accepts explicit host and port" {
    const cfg = try parse("postgres://x", "secret", "0.0.0.0", "80", .{});

    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqual(@as(u16, 80), cfg.port);
}

test "config: parse uses the supplied defaults" {
    const cfg = try parse("postgres://x", "secret", null, null, .{ .host = "0.0.0.0", .port = "80" });

    try std.testing.expectEqualStrings("0.0.0.0", cfg.host);
    try std.testing.expectEqual(@as(u16, 80), cfg.port);
}

test "config: missing database url is an error" {
    try std.testing.expectError(error.MissingDatabaseUrl, parse(null, "secret", null, null, .{}));
}

test "config: missing jwt secret is an error" {
    try std.testing.expectError(error.MissingJwtSecret, parse("postgres://x", null, null, null, .{}));
}

test "config: non numeric port is an error" {
    try std.testing.expectError(error.InvalidPort, parse("postgres://x", "secret", null, "eighty", .{}));
}

test "config: out of range port is an error" {
    try std.testing.expectError(error.InvalidPort, parse("postgres://x", "secret", null, "70000", .{}));
}
