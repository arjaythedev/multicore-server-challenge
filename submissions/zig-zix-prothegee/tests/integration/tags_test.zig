//! Integration tests: tags against PostgreSQL.
//!
//! Skips when the local conduit database is not reachable.
//! The seeded conduit_dev copy is expected when the suite runs for real.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const tag_domain = conduit.domain.tag;

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

const TEST_DATABASE_URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit";

// --------------------------------------------------------- //

test "integration: tag list is sorted and complete" {
    const config = postgrez.parseUrl(TEST_DATABASE_URL) catch return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const conn = postgrez.Conn.connect(std.testing.allocator, threaded.io(), config) catch return error.SkipZigTest;
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const names = try tag_domain.list(conn, arena.allocator());

    try std.testing.expect(names.len >= 200);

    var previous: []const u8 = "";
    for (names, 0..) |name, index| {
        try std.testing.expect(name.len > 0);

        if (index > 0) {
            try std.testing.expect(std.mem.order(u8, previous, name) == .lt);
        }

        previous = name;
    }
}
