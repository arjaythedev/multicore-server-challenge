//! Integration tests: favorite edges against PostgreSQL.
//!
//! Skips when the local conduit database is not reachable.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const article_domain = conduit.domain.article;
const favorite_domain = conduit.domain.favorite;
const user_domain = conduit.domain.user;

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

const TEST_DATABASE_URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit";

const AUTHOR_USERNAME = "zix_favorite_author";
const AUTHOR_EMAIL = "zix_favorite_author@example.com";
const OTHER_USERNAME = "zix_favorite_other";
const OTHER_EMAIL = "zix_favorite_other@example.com";

fn deleteTestRows(conn: *postgrez.Conn) void {
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{AUTHOR_USERNAME}) catch {};
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{OTHER_USERNAME}) catch {};
}

// --------------------------------------------------------- //

test "integration: favorite and unfavorite an article" {
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

    const author = try user_domain.insert(conn, allocator, AUTHOR_USERNAME, AUTHOR_EMAIL, "hash");
    const other = try user_domain.insert(conn, allocator, OTHER_USERNAME, OTHER_EMAIL, "hash");

    const no_tags = [_][]const u8{};
    const created = try article_domain.create(
        conn,
        allocator,
        author.id,
        "Zix Favorite Article",
        "desc",
        "body",
        &no_tags,
    );
    try std.testing.expect(created != null);
    const article = created.?;

    const maybe_article_id = try article_domain.idBySlug(conn, allocator, article.slug);
    try std.testing.expect(maybe_article_id != null);
    const article_id = maybe_article_id.?;
    try std.testing.expectEqual(article.id, article_id);

    // Add the favorite.
    try favorite_domain.add(conn, other.id, article_id);

    const as_other = try article_domain.findById(conn, allocator, other.id, article_id);
    try std.testing.expect(as_other != null);
    try std.testing.expect(as_other.?.favorited);
    try std.testing.expectEqual(@as(i64, 1), as_other.?.favorites_count);

    const as_author = try article_domain.findById(conn, allocator, author.id, article_id);
    try std.testing.expect(as_author != null);
    try std.testing.expect(!as_author.?.favorited);
    try std.testing.expectEqual(@as(i64, 1), as_author.?.favorites_count);

    // A duplicate add does not change the count.
    try favorite_domain.add(conn, other.id, article_id);
    const after_duplicate = try article_domain.findById(conn, allocator, other.id, article_id);
    try std.testing.expectEqual(@as(i64, 1), after_duplicate.?.favorites_count);

    // Remove the favorite.
    try favorite_domain.remove(conn, other.id, article_id);
    const after_remove = try article_domain.findById(conn, allocator, other.id, article_id);
    try std.testing.expect(!after_remove.?.favorited);
    try std.testing.expectEqual(@as(i64, 0), after_remove.?.favorites_count);

    // A duplicate remove is a no-op.
    try favorite_domain.remove(conn, other.id, article_id);
    const after_second_remove = try article_domain.findById(conn, allocator, other.id, article_id);
    try std.testing.expectEqual(@as(i64, 0), after_second_remove.?.favorites_count);

    // A missing slug has no article id.
    try std.testing.expect((try article_domain.idBySlug(conn, allocator, "zix-no-such-article")) == null);
}
