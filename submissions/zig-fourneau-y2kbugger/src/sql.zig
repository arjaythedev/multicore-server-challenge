//! Every statement, prepared once per connection as `s<index>` (pg.zig).
//! Each endpoint sends its statements as one group: one round trip, one
//! implicit transaction. Results are binary; columns are named by index
//! where they are read (api.zig).

const std = @import("std");
const pg = @import("pg.zig");

const Oid = pg.Oid;

/// `$1` is the viewer (0 when anonymous: no user has id 0).
/// Columns: slug, title, description, created_at, updated_at, tag_list,
/// favorites_count, favorited, username, bio, image, following.
const article_list_select =
    \\SELECT a.slug, a.title, a.description, a.created_at, a.updated_at,
    \\       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
    \\              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
    \\       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
    \\       u.username, u.bio, u.image,
    \\       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
    \\  FROM articles a
    \\  JOIN users u ON u.id = a.author_id
;

/// As `article_list_select`, with the body after the description.
/// Columns: slug, title, description, body, created_at, updated_at,
/// tag_list, favorites_count, favorited, username, bio, image, following.
const article_full_select =
    \\SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
    \\       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
    \\              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
    \\       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
    \\       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
    \\       u.username, u.bio, u.image,
    \\       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
    \\  FROM articles a
    \\  JOIN users u ON u.id = a.author_id
;

const order_page = " ORDER BY a.id DESC LIMIT $2 OFFSET $3";

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
    .list_all = .{ .sql = article_list_select ++ order_page, .params = viewer_page },
    .count_all = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s",
        .params = &.{},
    },
    .list_tag = .{
        .sql = article_list_select ++ " WHERE a.id IN (SELECT at.article_id FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " ++
            "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
        .params = viewer_page_filter,
    },
    .count_tag = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
        .params = &.{.text},
    },
    .list_author = .{
        .sql = article_list_select ++
            " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)" ++ order_page,
        .params = viewer_page_filter,
    },
    .count_author = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM articles a " ++
            "WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
        .params = &.{.text},
    },
    .list_favorited = .{
        .sql = article_list_select ++ " WHERE a.id IN (SELECT f.article_id FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " ++
            "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
        .params = viewer_page_filter,
    },
    .count_favorited = .{
        .sql = "SELECT count(*) FROM (SELECT 1 FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
        .params = &.{.text},
    },
    .list_feed = .{
        .sql = article_list_select ++ " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL " ++
            "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " ++
            "ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x " ++
            "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
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
});
