//! Integration tests: articles, filters, and the feed against PostgreSQL.
//!
//! Skips when the local conduit database is not reachable.

const std = @import("std");
const zix = @import("zix");

const conduit = @import("conduit");

const article_domain = conduit.domain.article;
const profile_domain = conduit.domain.profile;
const user_domain = conduit.domain.user;

const postgrez = zix.Driver.postgrez;

// --------------------------------------------------------- //

const TEST_DATABASE_URL = "postgres://conduit:conduit@127.0.0.1:5432/conduit";

const AUTHOR_USERNAME = "zix_article_author";
const AUTHOR_EMAIL = "zix_article_author@example.com";
const OTHER_USERNAME = "zix_article_other";
const OTHER_EMAIL = "zix_article_other@example.com";

const TAG_ALPHA = "zix-it-alpha";
const TAG_BETA = "zix-it-beta";

fn deleteTestRows(conn: *postgrez.Conn) void {
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{AUTHOR_USERNAME}) catch {};
    _ = conn.exec("DELETE FROM users WHERE username = $1", .{OTHER_USERNAME}) catch {};
    _ = conn.exec("DELETE FROM tags WHERE name = $1", .{TAG_ALPHA}) catch {};
    _ = conn.exec("DELETE FROM tags WHERE name = $1", .{TAG_BETA}) catch {};
}

fn hasSlug(articles: []const article_domain.Article, slug: []const u8) bool {
    for (articles) |article| {
        if (std.mem.eql(u8, article.slug, slug)) return true;
    }

    return false;
}

// --------------------------------------------------------- //

test "integration: article lifecycle, filters, and feed" {
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

    const tags = [_][]const u8{ TAG_BETA, TAG_ALPHA };
    const created = try article_domain.create(
        conn,
        allocator,
        author.id,
        "Zix Integration Article",
        "A short description",
        "The body text",
        &tags,
    );
    try std.testing.expect(created != null);
    const article = created.?;

    try std.testing.expect(article.id > 0);
    try std.testing.expect(std.mem.startsWith(u8, article.slug, "zix-integration-article-"));
    try std.testing.expectEqualStrings("Zix Integration Article", article.title);
    try std.testing.expectEqualStrings("The body text", article.body);
    try std.testing.expectEqual(@as(usize, 2), article.tag_list.tags.len);
    try std.testing.expectEqualStrings(TAG_ALPHA, article.tag_list.tags[0]);
    try std.testing.expectEqualStrings(TAG_BETA, article.tag_list.tags[1]);
    try std.testing.expectEqual(@as(i64, 0), article.favorites_count);
    try std.testing.expect(!article.favorited);
    try std.testing.expectEqualStrings(AUTHOR_USERNAME, article.username);
    try std.testing.expect(!article.following);
    try std.testing.expectEqual(@as(usize, 24), article.created_at.len);
    try std.testing.expect(article.created_at[23] == 'Z');

    // Detail by slug.
    const detail = try article_domain.findBySlug(conn, allocator, author.id, article.slug);
    try std.testing.expect(detail != null);
    try std.testing.expectEqualStrings(article.slug, detail.?.slug);

    // The list is newest first, so the new article is first.
    const page = try article_domain.list(conn, allocator, author.id, .NONE, 20, 0);
    try std.testing.expect(page.articles.len > 0);
    try std.testing.expectEqualStrings(article.slug, page.articles[0].slug);
    try std.testing.expect(page.count >= 1);

    // Tag and author filters find it.
    const tag_page = try article_domain.list(conn, allocator, author.id, .{ .TAG = TAG_ALPHA }, 20, 0);
    try std.testing.expect(hasSlug(tag_page.articles, article.slug));

    const author_page = try article_domain.list(conn, allocator, author.id, .{ .AUTHOR = AUTHOR_USERNAME }, 20, 0);
    try std.testing.expect(hasSlug(author_page.articles, article.slug));

    // The other user follows the author, so the feed shows the article.
    _ = try profile_domain.follow(conn, allocator, other.id, AUTHOR_USERNAME);
    const feed = try article_domain.feed(conn, allocator, other.id, 20, 0);
    try std.testing.expect(hasSlug(feed.articles, article.slug));
    try std.testing.expect(feed.count >= 1);

    for (feed.articles) |row| {
        if (std.mem.eql(u8, row.slug, article.slug)) {
            try std.testing.expect(row.following);
        }
    }

    // Update the title, which regenerates the slug.
    const updated = try article_domain.update(conn, allocator, article.id, author.id, "Zix Updated Article", null, null);
    try std.testing.expect(updated != null);
    try std.testing.expect(std.mem.startsWith(u8, updated.?.slug, "zix-updated-article-"));
    try std.testing.expectEqualStrings("Zix Updated Article", updated.?.title);
    try std.testing.expectEqualStrings("A short description", updated.?.description);
    try std.testing.expectEqual(@as(usize, 2), updated.?.tag_list.tags.len);

    // The old slug is gone, the new slug resolves.
    try std.testing.expect((try article_domain.findBySlug(conn, allocator, author.id, article.slug)) == null);
    const by_new = try article_domain.findBySlug(conn, allocator, author.id, updated.?.slug);
    try std.testing.expect(by_new != null);

    // Delete and confirm.
    try article_domain.delete(conn, article.id);
    try std.testing.expect((try article_domain.findBySlug(conn, allocator, author.id, updated.?.slug)) == null);
}
