//! Every statement, prepared once per connection as `s<index>` (pg.zig).
//! Each endpoint sends its statements as one group: one round trip, one
//! implicit transaction. Results are binary; columns are named by index
//! where they are read (api.zig).

const std = @import("std");
const pg = @import("pg.zig");

const Oid = pg.Oid;

/// An article's tags by name, each looked up by its key: the reference's
/// join hashed all 200 tags for every article of a list.
const tag_list =
    \\ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at
    \\       WHERE at.article_id = a.id ORDER BY name)
;

/// `viewer` is the viewer's id (0 when anonymous: no user has id 0): `$1`
/// in a request's own statement, `r.v` in a batch.
fn article_flags(comptime viewer: []const u8) []const u8 {
    return "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id), " ++
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = " ++ viewer ++ "), " ++
        "u.username, u.bio, u.image";
}

fn following_of(comptime viewer: []const u8) []const u8 {
    return "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = " ++ viewer ++
        " AND fo.followee_id = a.author_id)";
}

const following = following_of("$1");

/// A page of articles, the rows `page` names (`id`, newest first, at most
/// 100: the limit's ceiling, a constant so the generic plan expects a
/// page, not a tenth of the table); the per-article work done for the page's
/// rows only, not for those `OFFSET` skips.
/// Columns: slug, title, description, created_at, updated_at, tag_list,
/// favorites_count, favorited, username, bio, image, following.
fn list_select_of(
    comptime viewer: []const u8,
    comptime limit: []const u8,
    comptime page: []const u8,
    comptime follow: []const u8,
) []const u8 {
    return "SELECT a.slug, a.title, a.description, a.created_at, a.updated_at, " ++ tag_list ++
        ", " ++ article_flags(viewer) ++ ", " ++ follow ++
        " FROM (" ++ page ++ ") p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id" ++
        " ORDER BY p.id DESC LIMIT " ++ limit;
}

fn list_select(comptime page: []const u8, comptime follow: []const u8) []const u8 {
    return list_select_of("$1", "$2", page, follow);
}

/// Columns: slug, title, description, body, created_at, updated_at,
/// tag_list, favorites_count, favorited, username, bio, image, following.
fn article_full_select_of(comptime viewer: []const u8) []const u8 {
    return "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " ++
        tag_list ++ ", " ++ article_flags(viewer) ++ ", " ++ following_of(viewer) ++
        " FROM articles a JOIN users u ON u.id = a.author_id";
}

const article_full_select = article_full_select_of("$1");

// ---------- batches (batch.zig): every request a row of `r` ----------
//
// `$1` the requests' indexes (int4[]), `$2` viewers (int8[]), and for
// pages `$3` limits, `$4` offsets (int8[]) and `$5` keys (text[]); for the
// rest `$3` keys. Each row's first column is its request's index.

const batch_keys = "FROM unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)";
const batch_pages = "FROM unnest($1::int4[], $2::int8[], $3::int8[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)";

fn batch_page(comptime page: []const u8, comptime follow: []const u8) []const u8 {
    return "SELECT r.i, x.* " ++ batch_pages ++ " CROSS JOIN LATERAL (" ++
        list_select_of("r.v", "r.l", page, follow) ++ ") x";
}

/// A capped count per request: the subquery names `r`, so it is run for
/// each request, not once for the statement.
fn batch_count(comptime counted: []const u8) []const u8 {
    return "SELECT r.i, (SELECT count(*) FROM (" ++ counted ++ " LIMIT 1000) s) " ++ batch_keys;
}

const batch_page_params = &[_]Oid{ .int4_array, .int8_array, .int8_array, .int8_array, .text_array };
const batch_key_params = &[_]Oid{ .int4_array, .int8_array, .text_array };

const slugify = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";
const current_article = "currval(pg_get_serial_sequence('articles', 'id'))";

pub const S = enum(u16) {
    tags,
    user_by_id,
    user_by_email,
    user_insert,
    user_update,
    profile,
    follow_insert,
    follow_delete,
    profile_by_username,
    list_all,
    count_all,
    list_tag,
    count_tag,
    list_author,
    count_author,
    list_favorited,
    count_favorited,
    list_feed,
    count_feed,
    article_by_slug,
    article_by_id,
    article_insert,
    tags_insert,
    article_tags_insert,
    article_by_current,
    article_owner,
    article_update,
    article_delete,
    favorite_insert,
    favorite_delete,
    article_exists,
    comments_by_slug,
    comment_insert,
    comment_owner,
    comment_delete,
    batch_article,
    batch_article_exists,
    batch_comments,
    batch_profile,
    batch_user,
    batch_tags,
    batch_list_all,
    batch_count_all,
    batch_list_tag,
    batch_count_tag,
    batch_list_author,
    batch_count_author,
    batch_list_favorited,
    batch_count_favorited,
    batch_list_feed,
    batch_count_feed,
};

const viewer_page = &[_]Oid{ .int8, .int8, .int8 };
const viewer_page_filter = &[_]Oid{ .int8, .int8, .int8, .text };

pub const statements = std.enums.EnumArray(S, pg.Statement).init(.{
    .tags = .{ .sql = "SELECT name FROM tags ORDER BY name", .params = &.{} },
    .user_by_id = .{
        .sql = "SELECT username, email, bio, image FROM users WHERE id = $1",
        .params = &.{.int8},
    },
    .user_by_email = .{
        .sql = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
        .params = &.{.text},
    },
    .user_insert = .{
        .sql = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) " ++
            "RETURNING id, username, email, bio, image",
        .params = &.{ .text, .text, .text },
    },
    .user_update = .{
        .sql = "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " ++
            "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), " ++
            "image = COALESCE($6, image) WHERE id = $1 RETURNING username, email, bio, image",
        .params = &.{ .int8, .text, .text, .text, .text, .text },
    },
    .profile = .{
        .sql = "SELECT u.username, u.bio, u.image, " ++
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) " ++
            "FROM users u WHERE u.username = $2",
        .params = &.{ .int8, .text },
    },
    .follow_insert = .{
        .sql = "INSERT INTO follows (follower_id, followee_id) " ++
            "SELECT $1, u.id FROM users u WHERE u.username = $2 ON CONFLICT DO NOTHING",
        .params = &.{ .int8, .text },
    },
    .follow_delete = .{
        .sql = "DELETE FROM follows WHERE follower_id = $1 " ++
            "AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2)",
        .params = &.{ .int8, .text },
    },
    .profile_by_username = .{
        .sql = "SELECT username, bio, image FROM users WHERE username = $1",
        .params = &.{.text},
    },
    .list_all = .{
        .sql = list_select("SELECT a.id FROM articles a ORDER BY a.id DESC OFFSET $3 LIMIT 100", following),
        .params = viewer_page,
    },
    .count_all = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s",
        .params = &.{},
    },
    .list_tag = .{
        .sql = list_select("SELECT at.article_id AS id FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " ++
            "ORDER BY at.article_id DESC OFFSET $3 LIMIT 100", following),
        .params = viewer_page_filter,
    },
    .count_tag = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
        .params = &.{.text},
    },
    .list_author = .{
        .sql = list_select("SELECT a.id FROM articles a " ++
            "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) " ++
            "ORDER BY a.id DESC OFFSET $3 LIMIT 100", following),
        .params = viewer_page_filter,
    },
    .count_author = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM articles a " ++
            "WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
        .params = &.{.text},
    },
    .list_favorited = .{
        .sql = list_select("SELECT f.article_id AS id FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " ++
            "ORDER BY f.article_id DESC OFFSET $3 LIMIT 100", following),
        .params = viewer_page_filter,
    },
    .count_favorited = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
        .params = &.{.text},
    },
    // Every author of the feed is one the viewer follows, in the same
    // snapshot: `following` is true.
    .list_feed = .{
        .sql = list_select("SELECT x.id FROM follows fo CROSS JOIN LATERAL " ++
            "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " ++
            "ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x " ++
            "WHERE fo.follower_id = $1 ORDER BY x.id DESC OFFSET $3 LIMIT 100", "true"),
        .params = viewer_page,
    },
    .count_feed = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN " ++
            "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
        .params = &.{.int8},
    },
    .article_by_slug = .{ .sql = article_full_select ++ " WHERE a.slug = $2", .params = &.{ .int8, .text } },
    .article_by_id = .{ .sql = article_full_select ++ " WHERE a.id = $2", .params = &.{ .int8, .int8 } },
    .article_insert = .{
        .sql = "INSERT INTO articles (id, slug, author_id, title, description, body) " ++
            "SELECT n.id, " ++ slugify ++ " || '-' || n.id, $1, $2, $3, $4 " ++
            "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n",
        .params = &.{ .int8, .text, .text, .text },
    },
    .tags_insert = .{
        .sql = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
        .params = &.{.text_array},
    },
    .article_tags_insert = .{
        .sql = "INSERT INTO article_tags (article_id, tag_id) SELECT " ++ current_article ++
            ", t.id FROM tags t WHERE t.name = ANY($1::text[])",
        .params = &.{.text_array},
    },
    .article_by_current = .{
        // In a subquery: evaluated once (an InitPlan), so the key's index
        // finds the row. As a bare comparison `currval` is volatile, and
        // was evaluated per row: a scan of every article, 2.4 s.
        .sql = article_full_select ++ " WHERE a.id = (SELECT " ++ current_article ++ ")",
        .params = &.{.int8},
    },
    .article_owner = .{
        .sql = "SELECT id, author_id FROM articles WHERE slug = $1",
        .params = &.{.text},
    },
    .article_update = .{
        .sql = "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), " ++
            "body = COALESCE($4, body), slug = CASE WHEN $2::text IS NULL THEN slug ELSE " ++
            slugify ++ " || '-' || id END, updated_at = now() WHERE id = $1",
        .params = &.{ .int8, .text, .text, .text },
    },
    .article_delete = .{
        .sql = "DELETE FROM articles WHERE slug = $1 AND author_id = $2",
        .params = &.{ .text, .int8 },
    },
    .favorite_insert = .{
        .sql = "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a " ++
            "WHERE a.slug = $2 ON CONFLICT DO NOTHING",
        .params = &.{ .int8, .text },
    },
    .favorite_delete = .{
        .sql = "DELETE FROM favorites WHERE user_id = $1 " ++
            "AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
        .params = &.{ .int8, .text },
    },
    .article_exists = .{ .sql = "SELECT 1 FROM articles WHERE slug = $1", .params = &.{.text} },
    .comments_by_slug = .{
        .sql = "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " ++
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) " ++
            "FROM comments c JOIN users u ON u.id = c.author_id " ++
            "WHERE c.article_id = (SELECT a.id FROM articles a WHERE a.slug = $2) " ++
            "ORDER BY c.created_at DESC, c.id DESC LIMIT 100",
        .params = &.{ .int8, .text },
    },
    .comment_insert = .{
        .sql = "WITH c AS (INSERT INTO comments (article_id, author_id, body) " ++
            "SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 " ++
            "RETURNING id, body, created_at, updated_at, author_id) " ++
            "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image " ++
            "FROM c JOIN users u ON u.id = c.author_id",
        .params = &.{ .int8, .text, .text },
    },
    .comment_owner = .{
        .sql = "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " ++
            "WHERE c.id = $1 AND a.slug = $2",
        .params = &.{ .int8, .text },
    },
    .comment_delete = .{
        .sql = "DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id " ++
            "AND a.slug = $2 AND c.author_id = $3",
        .params = &.{ .int8, .text, .int8 },
    },
    .batch_article = .{
        .sql = "SELECT r.i, x.* " ++ batch_keys ++ " CROSS JOIN LATERAL (" ++
            article_full_select_of("r.v") ++ " WHERE a.slug = r.k) x",
        .params = batch_key_params,
    },
    .batch_article_exists = .{
        .sql = "SELECT r.i FROM unnest($1::int4[], $2::text[]) AS r(i, k) " ++
            "WHERE EXISTS (SELECT 1 FROM articles a WHERE a.slug = r.k)",
        .params = &.{ .int4_array, .text_array },
    },
    .batch_comments = .{
        .sql = "SELECT r.i, x.* " ++ batch_keys ++ " CROSS JOIN LATERAL (" ++
            "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " ++
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = c.author_id) " ++
            "FROM comments c JOIN users u ON u.id = c.author_id " ++
            "WHERE c.article_id = (SELECT a.id FROM articles a WHERE a.slug = r.k) " ++
            "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x",
        .params = batch_key_params,
    },
    .batch_profile = .{
        .sql = "SELECT r.i, u.username, u.bio, u.image, " ++
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) " ++
            batch_keys ++ " JOIN users u ON u.username = r.k",
        .params = batch_key_params,
    },
    .batch_user = .{
        .sql = "SELECT r.i, u.username, u.email, u.bio, u.image " ++
            "FROM unnest($1::int4[], $2::int8[]) AS r(i, v) JOIN users u ON u.id = r.v",
        .params = &.{ .int4_array, .int8_array },
    },
    // `r.i >= 0` names the request: the tags are read for each.
    .batch_tags = .{
        .sql = "SELECT r.i, x.name FROM unnest($1::int4[]) AS r(i) CROSS JOIN LATERAL " ++
            "(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) x",
        .params = &.{.int4_array},
    },
    .batch_list_all = .{
        .sql = batch_page("SELECT a.id FROM articles a WHERE r.i >= 0 " ++
            "ORDER BY a.id DESC OFFSET r.o LIMIT 100", following_of("r.v")),
        .params = batch_page_params,
    },
    .batch_count_all = .{
        .sql = batch_count("SELECT 1 FROM articles a WHERE r.i >= 0"),
        .params = batch_key_params,
    },
    .batch_list_tag = .{
        .sql = batch_page("SELECT at.article_id AS id FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) " ++
            "ORDER BY at.article_id DESC OFFSET r.o LIMIT 100", following_of("r.v")),
        .params = batch_page_params,
    },
    .batch_count_tag = .{
        .sql = batch_count("SELECT 1 FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k)"),
        .params = batch_key_params,
    },
    .batch_list_author = .{
        .sql = batch_page("SELECT a.id FROM articles a " ++
            "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = r.k) " ++
            "ORDER BY a.id DESC OFFSET r.o LIMIT 100", following_of("r.v")),
        .params = batch_page_params,
    },
    .batch_count_author = .{
        .sql = batch_count("SELECT 1 FROM articles a " ++
            "WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = r.k)"),
        .params = batch_key_params,
    },
    .batch_list_favorited = .{
        .sql = batch_page("SELECT f.article_id AS id FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.k) " ++
            "ORDER BY f.article_id DESC OFFSET r.o LIMIT 100", following_of("r.v")),
        .params = batch_page_params,
    },
    .batch_count_favorited = .{
        .sql = batch_count("SELECT 1 FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.k)"),
        .params = batch_key_params,
    },
    // Every author of the feed is one the viewer follows, in the same
    // snapshot: `following` is true.
    .batch_list_feed = .{
        .sql = batch_page("SELECT x.id FROM follows fo CROSS JOIN LATERAL " ++
            "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " ++
            "ORDER BY a2.id DESC LIMIT (r.l + r.o)) x " ++
            "WHERE fo.follower_id = r.v ORDER BY x.id DESC OFFSET r.o LIMIT 100", "true"),
        .params = batch_page_params,
    },
    .batch_count_feed = .{
        .sql = batch_count("SELECT 1 FROM articles a WHERE a.author_id IN " ++
            "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)"),
        .params = batch_key_params,
    },
});
