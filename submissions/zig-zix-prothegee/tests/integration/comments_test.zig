//! Integration tests: comments against PostgreSQL.
//!
//! Skips when the local conduit database is not reachable.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const article_domain = conduit.domain.article;
const comment_domain = conduit.domain.comment;
const profile_domain = conduit.domain.profile;
const user_domain = conduit.domain.user;

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

const TEST_DATABASE_URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit";

const AUTHOR_USERNAME = "zix_comment_author";
const AUTHOR_EMAIL = "zix_comment_author@example.com";
const OTHER_USERNAME = "zix_comment_other";
const OTHER_EMAIL = "zix_comment_other@example.com";

fn deleteTestRows(conn: *postgrez.Conn) void {
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{AUTHOR_USERNAME}) catch {};
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{OTHER_USERNAME}) catch {};
}

// --------------------------------------------------------- //

test "integration: comment lifecycle and following flag" {
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
        "Zix Comment Article",
        "desc",
        "body",
        &no_tags,
    );
    try std.testing.expect(created != null);
    const article = created.?;

    const second = try article_domain.create(
        conn,
        allocator,
        author.id,
        "Zix Comment Other Article",
        "desc",
        "body",
        &no_tags,
    );
    try std.testing.expect(second != null);
    const other_article = second.?;

    const first = try comment_domain.create(conn, allocator, article.id, author.id, "First comment");
    try std.testing.expect(first != null);
    const comment = first.?;

    try std.testing.expect(comment.id > 0);
    try std.testing.expectEqualStrings("First comment", comment.body);
    try std.testing.expectEqualStrings(AUTHOR_USERNAME, comment.username);
    try std.testing.expect(!comment.following);
    try std.testing.expectEqual(@as(usize, 24), comment.created_at.len);
    try std.testing.expect(comment.created_at[23] == 'Z');

    // The list has the one comment.
    const listed = try comment_domain.list(conn, allocator, other.id, article.id);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("First comment", listed[0].body);
    try std.testing.expect(!listed[0].following);

    // Following the author flips the flag for that viewer.
    _ = try profile_domain.follow(conn, allocator, other.id, AUTHOR_USERNAME);

    const followed = try comment_domain.list(conn, allocator, other.id, article.id);
    try std.testing.expectEqual(@as(usize, 1), followed.len);
    try std.testing.expect(followed[0].following);

    // A newer comment comes first.
    const second_comment = try comment_domain.create(conn, allocator, article.id, author.id, "Second comment");
    try std.testing.expect(second_comment != null);

    const ordered = try comment_domain.list(conn, allocator, other.id, article.id);
    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqualStrings("Second comment", ordered[0].body);
    try std.testing.expectEqualStrings("First comment", ordered[1].body);

    // One comment by id.
    const found = try comment_domain.findById(conn, allocator, other.id, comment.id);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("First comment", found.?.body);

    // The owner lookup is scoped to the article slug.
    try std.testing.expectEqual(
        author.id,
        (try comment_domain.ownerBySlugAndId(conn, allocator, article.slug, comment.id)).?,
    );
    try std.testing.expect(
        (try comment_domain.ownerBySlugAndId(conn, allocator, other_article.slug, comment.id)) == null,
    );

    // Delete and confirm.
    try comment_domain.delete(conn, comment.id);

    const after_delete = try comment_domain.list(conn, allocator, other.id, article.id);
    try std.testing.expectEqual(@as(usize, 1), after_delete.len);
    try std.testing.expectEqualStrings("Second comment", after_delete[0].body);
}
