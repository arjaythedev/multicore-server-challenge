//! Integration tests: profiles and follows against PostgreSQL.
//!
//! Skips when the local conduit database is not reachable.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const profile_domain = conduit.domain.profile;
const user_domain = conduit.domain.user;

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

const TEST_DATABASE_URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit";

const VIEWER_USERNAME = "zix_profile_viewer";
const VIEWER_EMAIL = "zix_profile_viewer@example.com";
const TARGET_USERNAME = "zix_profile_target";
const TARGET_EMAIL = "zix_profile_target@example.com";

fn deleteTestRows(conn: *postgrez.Conn) void {
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{VIEWER_USERNAME}) catch {};
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{TARGET_USERNAME}) catch {};
}

// --------------------------------------------------------- //

test "integration: profile read and follow edges" {
    const config = postgrez.parseUrl(TEST_DATABASE_URL) catch return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    const conn = postgrez.Conn.connect(std.testing.allocator, threaded.io(), config) catch return error.SkipZigTest;
    defer conn.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    deleteTestRows(conn);
    defer deleteTestRows(conn);

    const viewer = try user_domain.insert(conn, allocator, VIEWER_USERNAME, VIEWER_EMAIL, "hash");
    const target = try user_domain.insert(conn, allocator, TARGET_USERNAME, TARGET_EMAIL, "hash");

    try std.testing.expect(viewer.id > 0);
    try std.testing.expect(target.id > 0);

    // Anonymous read has no follow edge.
    const anonymous = try profile_domain.findByUsername(conn, allocator, 0, TARGET_USERNAME);
    try std.testing.expect(anonymous != null);
    try std.testing.expect(!anonymous.?.following);

    // The viewer is not following yet.
    const before = try profile_domain.findByUsername(conn, allocator, viewer.id, TARGET_USERNAME);
    try std.testing.expect(before != null);
    try std.testing.expect(!before.?.following);

    // Follow reports following true and persists the edge.
    const followed = try profile_domain.follow(conn, allocator, viewer.id, TARGET_USERNAME);
    try std.testing.expect(followed != null);
    try std.testing.expect(followed.?.following);
    try std.testing.expectEqualStrings(TARGET_USERNAME, followed.?.username);

    const after = try profile_domain.findByUsername(conn, allocator, viewer.id, TARGET_USERNAME);
    try std.testing.expect(after != null);
    try std.testing.expect(after.?.following);

    // Unfollow reports following false and removes the edge.
    const unfollowed = try profile_domain.unfollow(conn, allocator, viewer.id, TARGET_USERNAME);
    try std.testing.expect(unfollowed != null);
    try std.testing.expect(!unfollowed.?.following);

    const cleared = try profile_domain.findByUsername(conn, allocator, viewer.id, TARGET_USERNAME);
    try std.testing.expect(cleared != null);
    try std.testing.expect(!cleared.?.following);

    // Unknown profiles are null for every operation.
    try std.testing.expect((try profile_domain.findByUsername(conn, allocator, viewer.id, "zix_no_such_profile")) == null);
    try std.testing.expect((try profile_domain.follow(conn, allocator, viewer.id, "zix_no_such_profile")) == null);
    try std.testing.expect((try profile_domain.unfollow(conn, allocator, viewer.id, "zix_no_such_profile")) == null);
}
