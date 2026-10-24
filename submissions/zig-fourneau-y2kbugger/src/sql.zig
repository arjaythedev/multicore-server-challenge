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

/// A page every request of the batch shares with the others asking for
/// the same one (`k`, `l`, `o`): its articles, their tags, favorite counts
/// and authors read once in the statement, the viewer's flags per request.
/// `page` names `q.k` and `q.o` and picks the page's ids on the bare index,
/// at most 100 (the limit's ceiling, a constant so the generic plan expects
/// a page, not a tenth of the table): the per-article work is done for the
/// page's rows only, not for those `OFFSET` skips. The rows come out by
/// request, newest first. Each request's `favorited` and `following` take
/// one probe of each index for its whole page (`fl`), not one an article:
/// half the statement's buffer reads, 17% of its time (a global batch of
/// 10); p95 -10% at 50k users on 4 CPUs.
fn shared_page(comptime page: []const u8) []const u8 {
    return "WITH r AS (SELECT * " ++ batch_pages ++ "), " ++
        "q AS (SELECT DISTINCT r.k, r.l, r.o FROM r), " ++
        "x AS MATERIALIZED (SELECT q.k, q.l, q.o, y.* FROM q CROSS JOIN LATERAL (" ++
        "SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, " ++
        tag_list ++ " AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites, " ++
        "u.username, u.bio, u.image FROM (" ++ page ++ ") p JOIN articles a ON a.id = p.id " ++
        "JOIN users u ON u.id = a.author_id ORDER BY p.id DESC LIMIT q.l) y), " ++
        "pg AS (SELECT x.k, x.l, x.o, array_agg(x.id) AS ids, array_agg(DISTINCT x.author_id) AS authors " ++
        "FROM x GROUP BY x.k, x.l, x.o), " ++
        "fl AS MATERIALIZED (SELECT r.i, " ++
        "ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.v AND f.article_id = ANY(pg.ids)) AS fav, " ++
        "ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v " ++
        "AND fo.followee_id = ANY(pg.authors)) AS fol " ++
        "FROM r JOIN pg ON pg.k = r.k AND pg.l = r.l AND pg.o = r.o) " ++
        "SELECT r.i, x.slug, x.title, x.description, x.created_at, x.updated_at, x.tag_list, x.favorites, " ++
        "x.id = ANY(fl.fav), x.username, x.bio, x.image, x.author_id = ANY(fl.fol) " ++
        "FROM r JOIN x ON x.k = r.k AND x.l = r.l AND x.o = r.o JOIN fl ON fl.i = r.i ORDER BY r.i, x.id DESC";
}

/// A capped count each distinct key of the batch's requests reads once
/// (`counted` names `q.k`), for every request with that key.
fn shared_count(comptime counted: []const u8) []const u8 {
    return "WITH r AS (SELECT * " ++ batch_keys ++ "), q AS (SELECT DISTINCT r.k FROM r), " ++
        "c AS MATERIALIZED (SELECT q.k, (SELECT count(*) FROM (" ++ counted ++ " LIMIT 1000) s) AS n FROM q) " ++
        "SELECT r.i, c.n FROM r JOIN c ON c.k = r.k";
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
    user_insert,
    user_update,
    follow_insert,
    follow_delete,
    profile_by_username,
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
    comment_insert,
    comment_owner,
    comment_delete,
    batch_article,
    batch_comments,
    batch_profile,
    batch_user,
    batch_login,
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

pub const statements = std.enums.EnumArray(S, pg.Statement).init(.{
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
    .article_by_slug = .{ .sql = article_full_select ++ " WHERE a.slug = $2", .params = &.{ .int8, .text } },
    .article_by_id = .{ .sql = article_full_select ++ " WHERE a.id = $2", .params = &.{ .int8, .int8 } },
    .article_insert = .{
        .sql = "INSERT INTO articles (id, slug, author_id, title, description, body) " ++
            "SELECT n.id, " ++ slugify ++ " || '-' || n.id, $1, $2, $3, $4 " ++
            "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n",
        .params = &.{ .int8, .text, .text, .text },
    },
    // Only the names missing, so an existing one takes no id from the
    // sequence; in name order, so two groups creating the same new tags
    // lock them in one order and cannot deadlock (which would cost both a
    // second, Postgres's deadlock_timeout, and a retry alone).
    .tags_insert = .{
        .sql = "INSERT INTO tags (name) SELECT n.name FROM (SELECT DISTINCT unnest($1::text[]) AS name) n " ++
            "WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = n.name) ORDER BY n.name " ++
            "ON CONFLICT (name) DO NOTHING",
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
    // Each distinct slug of the batch read once: the article, its tags,
    // favorite count and author; the viewer's flags per request. A batch
    // repeats the articles of the lists its users just saw: 52 buffers a
    // request against 61, and 1-3% more requests a second at saturation.
    .batch_article = .{
        .sql = "WITH r AS (SELECT * " ++ batch_keys ++ "), q AS (SELECT DISTINCT r.k FROM r), " ++
            "x AS MATERIALIZED (SELECT q.k, a.id, a.author_id, a.slug, a.title, a.description, a.body, " ++
            "a.created_at, a.updated_at, " ++ tag_list ++ " AS tag_list, " ++
            "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites, " ++
            "u.username, u.bio, u.image FROM q JOIN articles a ON a.slug = q.k JOIN users u ON u.id = a.author_id) " ++
            "SELECT r.i, x.slug, x.title, x.description, x.body, x.created_at, x.updated_at, x.tag_list, " ++
            "x.favorites, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = x.id AND f.user_id = r.v), " ++
            "x.username, x.bio, x.image, " ++
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = x.author_id) " ++
            "FROM r JOIN x ON x.k = r.k",
        .params = batch_key_params,
    },
    // The article found once, its comments joined to it: a request's rows
    // are none (no such article), one of nulls (no comments), or one a
    // comment. Its existence apart was a second statement and a second
    // lookup of the slug (-15% of the two, a batch of 10).
    .batch_comments = .{
        .sql = "SELECT r.i, x.* " ++ batch_keys ++ " JOIN articles a ON a.slug = r.k LEFT JOIN LATERAL (" ++
            "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " ++
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = c.author_id) " ++
            "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id " ++
            "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true",
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
    .batch_login = .{
        .sql = "SELECT r.i, u.id, u.username, u.email, u.bio, u.image, u.password_hash " ++
            batch_keys ++ " JOIN users u ON u.email = r.k",
        .params = batch_key_params,
    },
    // What no viewer changes (the tags, the global count) is read once for
    // the batch's requests, all of them waiting before the statement runs;
    // nothing is kept after it.
    // The names as one array, in one row (`-1`) every request of the batch
    // keeps: 200 rows a request were 200 messages to send and read, and a
    // row a request had Postgres write the 200 names out for each.
    .batch_tags = .{
        .sql = "SELECT -1, array_agg(t.name ORDER BY t.name) FROM tags t",
        .params = &.{},
    },
    .batch_list_all = .{
        .sql = shared_page("SELECT a.id FROM articles a ORDER BY a.id DESC OFFSET q.o LIMIT 100"),
        .params = batch_page_params,
    },
    .batch_count_all = .{
        .sql = "SELECT r.i, c.n " ++ batch_keys ++
            " CROSS JOIN (SELECT count(*) AS n FROM (SELECT 1 FROM articles a LIMIT 1000) s) c",
        .params = batch_key_params,
    },
    .batch_list_tag = .{
        .sql = shared_page("SELECT at.article_id AS id FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = q.k) " ++
            "ORDER BY at.article_id DESC OFFSET q.o LIMIT 100"),
        .params = batch_page_params,
    },
    .batch_count_tag = .{
        .sql = shared_count("SELECT 1 FROM article_tags at " ++
            "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = q.k)"),
        .params = batch_key_params,
    },
    .batch_list_author = .{
        .sql = shared_page("SELECT a.id FROM articles a " ++
            "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = q.k) " ++
            "ORDER BY a.id DESC OFFSET q.o LIMIT 100"),
        .params = batch_page_params,
    },
    .batch_count_author = .{
        .sql = shared_count("SELECT 1 FROM articles a " ++
            "WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = q.k)"),
        .params = batch_key_params,
    },
    .batch_list_favorited = .{
        .sql = shared_page("SELECT f.article_id AS id FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = q.k) " ++
            "ORDER BY f.article_id DESC OFFSET q.o LIMIT 100"),
        .params = batch_page_params,
    },
    .batch_count_favorited = .{
        .sql = shared_count("SELECT 1 FROM favorites f " ++
            "WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = q.k)"),
        .params = batch_key_params,
    },
    // Every author of the feed is one the viewer follows, in the same
    // snapshot: `following` is true.
    // Feeds overlap (the authors most followed write the most): each
    // request's ids picked on its own, each distinct article read once.
    // An article's tags as their ids, and the first row (`-1`, every
    // request's) every tag's id and name, in Postgres's order of the names,
    // as `/api/tags` reads them: a lookup of each name by its key was a
    // fifth of the feed's index descents (-13% of its time, a batch of 9).
    .batch_list_feed = .{
        .sql = "WITH r AS (SELECT * " ++ batch_pages ++ "), " ++
            "ids AS MATERIALIZED (SELECT r.i, r.v, p.id FROM r CROSS JOIN LATERAL (" ++
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL " ++
            "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " ++
            "ORDER BY a2.id DESC LIMIT (r.l + r.o)) x " ++
            "WHERE fo.follower_id = r.v ORDER BY x.id DESC OFFSET r.o LIMIT r.l) p), " ++
            "x AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, " ++
            "ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id) AS tag_ids, " ++
            "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites, " ++
            "u.username, u.bio, u.image FROM (SELECT DISTINCT ids.id FROM ids) d " ++
            "JOIN articles a ON a.id = d.id JOIN users u ON u.id = a.author_id) " ++
            "SELECT -1, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, g.ids, " ++
            "NULL::int8, NULL::bool, NULL::text, NULL::text, NULL::text, NULL::bool, g.names, NULL::int8 " ++
            "FROM (SELECT array_agg(t.id ORDER BY t.name) AS ids, array_agg(t.name ORDER BY t.name) AS names " ++
            "FROM tags t) g " ++
            "UNION ALL SELECT ids.i, x.slug, x.title, x.description, x.created_at, x.updated_at, x.tag_ids, " ++
            "x.favorites, EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = x.id AND f.user_id = ids.v), " ++
            "x.username, x.bio, x.image, true, NULL, ids.id " ++
            "FROM ids JOIN x ON x.id = ids.id ORDER BY 1, 15 DESC",
        .params = batch_page_params,
    },
    .batch_count_feed = .{
        .sql = batch_count("SELECT 1 FROM articles a WHERE a.author_id IN " ++
            "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)"),
        .params = batch_key_params,
    },
});
