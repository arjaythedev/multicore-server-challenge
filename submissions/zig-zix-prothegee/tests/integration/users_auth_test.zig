//! Integration tests: users and auth against PostgreSQL.
//!
//! Skips when the local conduit database is not reachable.
//! The seeded conduit_dev copy is expected when the suite runs for real.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const user_domain = conduit.domain.user;
const password = conduit.auth.password;

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

const TEST_DATABASE_URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit";

const PRIMARY_USERNAME = "zix_it_user";
const PRIMARY_EMAIL = "zix_it_user@example.com";
const OTHER_USERNAME = "zix_it_other";
const OTHER_EMAIL = "zix_it_other@example.com";

fn deleteTestRows(conn: *postgrez.Conn) void {
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{PRIMARY_USERNAME}) catch {};
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{OTHER_USERNAME}) catch {};
}

// --------------------------------------------------------- //

test "integration: user lifecycle over Postgres" {
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

    // Register with a real bcrypt hash.
    var hash_buf: [password.HASH_MAX]u8 = undefined;
    const hash = try password.hash(threaded.io(), allocator, "password123", &hash_buf);

    const created = try user_domain.insert(conn, allocator, PRIMARY_USERNAME, PRIMARY_EMAIL, hash);
    try std.testing.expect(created.id > 0);
    try std.testing.expectEqualStrings(PRIMARY_USERNAME, created.username);

    // A duplicate username and a duplicate email both map to Duplicate.
    try std.testing.expectError(
        error.Duplicate,
        user_domain.insert(conn, allocator, PRIMARY_USERNAME, OTHER_EMAIL, hash),
    );
    try std.testing.expectError(
        error.Duplicate,
        user_domain.insert(conn, allocator, OTHER_USERNAME, PRIMARY_EMAIL, hash),
    );

    // Login lookup verifies the stored hash.
    const found = try user_domain.findByEmail(conn, allocator, PRIMARY_EMAIL);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(created.id, found.?.id);
    try password.verify(allocator, "password123", found.?.password_hash);
    try std.testing.expectError(
        error.PasswordVerificationFailed,
        password.verify(allocator, "wrong-password", found.?.password_hash),
    );

    // Every field absent is a no-op.
    const unchanged = try user_domain.update(conn, allocator, created.id, null, null, null, null, null);
    try std.testing.expect(unchanged != null);
    try std.testing.expectEqualStrings(PRIMARY_USERNAME, unchanged.?.username);
    try std.testing.expect(unchanged.?.bio == null);

    // An empty bio is stored as an empty string, not NULL.
    const empty_bio = try user_domain.update(conn, allocator, created.id, null, null, null, "", null);
    try std.testing.expect(empty_bio != null);
    try std.testing.expect(empty_bio.?.bio != null);
    try std.testing.expectEqualStrings("", empty_bio.?.bio.?);

    // A new password replaces the stored hash.
    var new_hash_buf: [password.HASH_MAX]u8 = undefined;
    const new_hash = try password.hash(threaded.io(), allocator, "password456", &new_hash_buf);

    const changed = try user_domain.update(conn, allocator, created.id, null, null, new_hash, null, null);
    try std.testing.expect(changed != null);

    const relogin = try user_domain.findByEmail(conn, allocator, PRIMARY_EMAIL);
    try std.testing.expect(relogin != null);
    try password.verify(allocator, "password456", relogin.?.password_hash);
    try std.testing.expectError(
        error.PasswordVerificationFailed,
        password.verify(allocator, "password123", relogin.?.password_hash),
    );

    // Updating to an existing username is a duplicate.
    _ = try user_domain.insert(conn, allocator, OTHER_USERNAME, OTHER_EMAIL, hash);
    try std.testing.expectError(
        error.Duplicate,
        user_domain.update(conn, allocator, created.id, null, OTHER_USERNAME, null, null, null),
    );

    // A deleted user is no longer found, so its token would be rejected.
    _ = conn.exec("DELETE FROM users WHERE id = $1", .{created.id}) catch {};
    try std.testing.expect((try user_domain.findById(conn, allocator, created.id)) == null);

    // Missing rows are null.
    try std.testing.expect((try user_domain.findById(conn, allocator, 9_000_000_000)) == null);
    try std.testing.expect((try user_domain.findByEmail(conn, allocator, "nobody@example.com")) == null);
}
