//! Process-wide composition state, set once at startup and read by handlers.

const std = @import("std");
const config = @import("config.zig");

// --------------------------------------------------------- //

var g_config: config.Config = undefined;

// --------------------------------------------------------- //

/// Store the loaded configuration for the life of the process.
pub fn init(cfg: config.Config) void {
    g_config = cfg;
}

/// The loaded configuration.
pub fn get() *const config.Config {
    return &g_config;
}

// --------------------------------------------------------- //

test "app: init stores the configuration" {
    init(.{
        .database_url = "postgres://conduit:conduit@127.0.0.1:5432/conduit",
        .jwt_secret = "multicore-server-challenge",
        .host = "127.0.0.1",
        .port = 3000,
    });

    try std.testing.expectEqualStrings("multicore-server-challenge", get().jwt_secret);
    try std.testing.expectEqual(@as(u16, 3000), get().port);
}
