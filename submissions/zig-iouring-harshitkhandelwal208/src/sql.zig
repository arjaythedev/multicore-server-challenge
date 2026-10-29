//! Every statement the server runs, one round trip per request. Written for generic (cached) plans:
//!  * list pages pick their ids first (bounded inner LIMIT keeps the planner's row estimate small), then decorate
//!    only the rows that are returned;
//!  * per-row membership tests are scalar probes (hashed sub-plans would materialise the viewer's whole set);
//!  * tag names come from the tags primary key, not a join that hashes all 200 tags per article;
//!  * comment threads (up to 100 rows) test "does the viewer follow this author" against the viewer's followee set,
//!    hashed once, instead of probing `follows` once per comment.
const std = @import("std");
const pg = @import("pg.zig");
const mutations = @import("mutation.zig");

const I8 = pg.oid.int8;
const I4 = pg.oid.int4;
const TX = pg.oid.text;
const TA = pg.oid.text_array;
const I8A = pg.oid.int8_array;
const I4A = pg.oid.int4_array;

pub const Stmt = enum(u16) {
    tx_begin,
    tx_commit,
    tags,
    user_by_id,
    user_login,
    user_insert,
    user_update,
    profile,
    follow,
    unfollow,
    list_global,
    list_tag,
    list_author,
    list_fav,
    feed,
    article,
    comments,
    comment_insert,
    comment_delete,
    art_insert,
    art_tags,
    art_attach,
    art_new,
    art_update,
    art_delete,
    fav_add,
    fav_del,
};

pub const Def = struct { sql: []const u8, params: []const u32 };

// --- article row layout (list endpoints: 13 columns; full: + body) ---------------------------------------
// 0 id, 1 slug, 2 title, 3 description, 4 created_at, 5 updated_at, 6 tag_list, 7 favorites_count,
// 8 favorited, 9 username, 10 bio, 11 image, 12 following, 13 body (full only)

const decor_tags =
    "ARRAY(SELECT n FROM (SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS n FROM article_tags at WHERE at.article_id = a.id) s ORDER BY n) AS c6";
const decor_favcount = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS c7";
const decor_favorited =
    "COALESCE((SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id), false) AS c8";
const decor_following =
    "COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id), false) AS c12";

fn cols(comptime following: []const u8, comptime body: bool) []const u8 {
    return "a.id AS c0, a.slug AS c1, a.title AS c2, a.description AS c3, a.created_at AS c4, a.updated_at AS c5, " ++
        decor_tags ++ ", " ++ decor_favcount ++ ", " ++ decor_favorited ++ ", u.username AS c9, u.bio AS c10, u.image AS c11, " ++
        following ++ (if (body) ", a.body AS c13" else "");
}

fn favCols(comptime on: bool) []const u8 {
    // A concurrent idempotent conflict can finish without RETURNING a row.
    // Reconcile the viewer's snapshot membership with the requested state instead.
    const fav_count = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - " ++
        "(SELECT count(*) FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id)" ++
        (if (on) " + 1 AS c7" else " AS c7");
    const favorited = if (on) "true AS c8" else "false AS c8";
    return "a.id AS c0, a.slug AS c1, a.title AS c2, a.description AS c3, a.created_at AS c4, a.updated_at AS c5, " ++
        decor_tags ++ ", " ++ fav_count ++ ", " ++ favorited ++ ", u.username AS c9, u.bio AS c10, u.image AS c11, " ++
        decor_following ++ ", a.body AS c13";
}

const list_cols = cols(decor_following, false);
const full_cols = cols(decor_following, true);
const feed_cols = cols("true AS c12", false);

const page_cols = "id, slug, title, description, created_at, updated_at, author_id";

/// `WITH c AS (count) SELECT c.n, p.* FROM c LEFT JOIN LATERAL (page) p ON true`: always one row at least, so the
/// capped count survives an empty page.
fn list(comptime count_sql: []const u8, comptime page_from: []const u8, comptime select_cols: []const u8) []const u8 {
    return "WITH c AS (" ++ count_sql ++ ") SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT " ++ select_cols ++
        " FROM " ++ page_from ++ " JOIN users u ON u.id = a.author_id ORDER BY a.id DESC LIMIT $2) p ON true";
}

const list_global_sql = list(
    "SELECT count(*)::int8 AS n FROM (SELECT 1 FROM articles WHERE $1 IS NOT NULL LIMIT 1000) s",
    "(SELECT " ++ page_cols ++ " FROM articles ORDER BY id DESC OFFSET $3 LIMIT 100) a",
    list_cols,
);

const list_tag_sql = list(
    "SELECT count(*)::int8 AS n FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s",
    "(SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC OFFSET $3 LIMIT 100) p0 JOIN articles a ON a.id = p0.article_id",
    list_cols,
);

const list_author_sql = list(
    "SELECT count(*)::int8 AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) LIMIT 1000) s",
    "(SELECT " ++ page_cols ++ " FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY id DESC OFFSET $3 LIMIT 100) a",
    list_cols,
);

const list_fav_sql = list(
    "SELECT count(*)::int8 AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s",
    "(SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC OFFSET $3 LIMIT 100) p0 JOIN articles a ON a.id = p0.article_id",
    list_cols,
);

const feed_base = list(
    "SELECT count(*)::int8 AS n FROM ff CROSS JOIN LATERAL (SELECT 1 FROM articles a WHERE a.author_id = ANY(ff.ids) LIMIT 1000) s",
    "(SELECT x.id FROM ff CROSS JOIN LATERAL unnest(ff.ids) fo(id) CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x ORDER BY x.id DESC OFFSET $3 LIMIT $2) p0 JOIN articles a ON a.id = p0.id",
    feed_cols,
);
const feed_sql = "WITH ff AS MATERIALIZED (SELECT ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id = $1) AS ids), " ++ feed_base[5..];

const slugify = "trim(both '-' from lower(regexp_replace($6, '[^A-Za-z0-9]+', '-', 'g')))";

pub const defs = blk: {
    var d: [std.meta.fieldNames(Stmt).len]Def = undefined;
    d[@backingInt(Stmt.tx_begin)] = .{ .sql = "BEGIN", .params = &.{} };
    d[@backingInt(Stmt.tx_commit)] = .{ .sql = "COMMIT", .params = &.{} };
    d[@backingInt(Stmt.tags)] = .{ .sql = "SELECT name FROM tags WHERE $1 IS NOT NULL ORDER BY name", .params = &.{I8} }; // $1: the viewer, unused. (Waiting `tags` requests are answered from one execution of this statement; see flushReads.)
    d[@backingInt(Stmt.user_by_id)] = .{ .sql = "SELECT id, username, email, bio, image FROM users WHERE id = $1", .params = &.{I8} };
    d[@backingInt(Stmt.user_login)] = .{ .sql = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", .params = &.{TX} };
    d[@backingInt(Stmt.user_insert)] = .{
        .sql = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
        .params = &.{ TX, TX, TX },
    };
    d[@backingInt(Stmt.user_update)] = .{
        .sql = "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image",
        .params = &.{ I8, TX, TX, TX, TX, TX },
    };
    d[@backingInt(Stmt.profile)] = .{
        .sql = "SELECT u.id, u.username, u.bio, u.image, COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id), false) FROM users u WHERE u.username = $2",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.follow)] = .{
        .sql = "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING) SELECT username, bio, image FROM u",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.unfollow)] = .{
        .sql = "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u)) SELECT username, bio, image FROM u",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.list_global)] = .{ .sql = list_global_sql, .params = &.{ I8, I4, I4 } };
    d[@backingInt(Stmt.list_tag)] = .{ .sql = list_tag_sql, .params = &.{ I8, I4, I4, TX } };
    d[@backingInt(Stmt.list_author)] = .{ .sql = list_author_sql, .params = &.{ I8, I4, I4, TX } };
    d[@backingInt(Stmt.list_fav)] = .{ .sql = list_fav_sql, .params = &.{ I8, I4, I4, TX } };
    d[@backingInt(Stmt.feed)] = .{ .sql = feed_sql, .params = &.{ I8, I4, I4 } };
    d[@backingInt(Stmt.article)] = .{
        .sql = "SELECT " ++ full_cols ++ " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.comments)] = .{
        .sql = "SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, (c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) AS following FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true WHERE a.slug = $2",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.comment_insert)] = .{
        .sql = "WITH a AS (SELECT id FROM articles WHERE slug = $2), c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $1, $3 FROM a RETURNING id, body, created_at, updated_at, author_id) SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
        .params = &.{ I8, TX, TX },
    };
    d[@backingInt(Stmt.comment_delete)] = .{
        .sql = "WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $2 AND a.slug = $3), d AS (DELETE FROM comments WHERE id = (SELECT id FROM c) AND author_id = $1 RETURNING id) SELECT c.author_id, EXISTS (SELECT 1 FROM d) FROM c",
        .params = &.{ I8, I8, TX },
    };
    d[@backingInt(Stmt.art_insert)] = .{
        .sql = "INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, $2 || '-' || n.id, $1, $3, $4, $5 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n",
        .params = &.{ I8, TX, TX, TX, TX },
    };
    d[@backingInt(Stmt.art_tags)] = .{
        .sql = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
        .params = &.{TA},
    };
    d[@backingInt(Stmt.art_attach)] = .{
        .sql = "INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
        .params = &.{TA},
    };
    d[@backingInt(Stmt.art_new)] = .{
        .sql = "SELECT " ++ full_cols ++ " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))",
        .params = &.{I8},
    };
    // $1 viewer, $2 slug, $3 title, $4 description, $5 body, $6 slug base (from the new title)
    d[@backingInt(Stmt.art_update)] = .{
        .sql = "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2), u AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE $6 || '-' || id END, updated_at = now() WHERE id = (SELECT id FROM a0) AND author_id = $1 RETURNING id, slug, title, description, body, created_at, updated_at, author_id) SELECT a0.id AS k0, a0.author_id AS k1, " ++
            "u.id AS c0, u.slug AS c1, u.title AS c2, u.description AS c3, u.created_at AS c4, u.updated_at AS c5, " ++
            "ARRAY(SELECT n FROM (SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS n FROM article_tags at WHERE at.article_id = a0.id) s ORDER BY n) AS c6, " ++
            "(SELECT count(*) FROM favorites f WHERE f.article_id = a0.id) AS c7, " ++
            "COALESCE((SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a0.id), false) AS c8, " ++
            "au.username AS c9, au.bio AS c10, au.image AS c11, " ++
            "COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a0.author_id), false) AS c12, u.body AS c13 " ++
            "FROM a0 LEFT JOIN u ON true LEFT JOIN users au ON au.id = a0.author_id",
        .params = &.{ I8, TX, TX, TX, TX, TX },
    };
    d[@backingInt(Stmt.art_delete)] = .{
        .sql = "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2), d AS (DELETE FROM articles WHERE id = (SELECT id FROM a0) AND author_id = $1 RETURNING id) SELECT a0.author_id, EXISTS (SELECT 1 FROM d) FROM a0",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.fav_add)] = .{
        .sql = "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), ins AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM a0 ON CONFLICT DO NOTHING RETURNING 1) SELECT " ++ favCols(true) ++ " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM a0)",
        .params = &.{ I8, TX },
    };
    d[@backingInt(Stmt.fav_del)] = .{
        .sql = "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), del AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM a0) RETURNING 1) SELECT " ++ favCols(false) ++ " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM a0)",
        .params = &.{ I8, TX },
    };
    break :blk d;
};

// --- batched variants with shared work ----------------------------------------------------------------------
// A batch holds requests that were all waiting when it was sent. Inside one statement the work that several of them
// have in common is done once: the capped count for each distinct filter (the global one is the same for everybody),
// and the decoration (tags, favourite count, author) of each distinct article. What is specific to a request (its
// page of ids and the viewer's favourited / following flags) is still computed per request, and nothing outlives the
// statement. Output rows keep the layout of the single-request statements, prefixed with the request's ordinal.

const dec_cols_common =
    "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, " ++
    "ARRAY(SELECT n FROM (SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS n FROM article_tags at WHERE at.article_id = a.id) s ORDER BY n) AS tag_list, " ++
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fav_count, u.username, u.bio, u.image";

const flag_favorited = "COALESCE((SELECT true FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = dec.id), false)";
const flag_following = "COALESCE((SELECT true FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = dec.author_id), false)";

/// `pk` is the column that, with `lim` and `off`, identifies a page ("" when every request asks the same list). Requests
/// of the batch that ask for the same page share one run of `page` (a lateral subquery over `r`, selecting `id`); what is
/// specific to a request, whether the viewer favourited / follows, takes one probe of each index for the request's whole
/// page (`fl`), not one per article.
fn listBatch(comptime has_key: bool, comptime cnt: []const u8, comptime cnt_join: []const u8, comptime pk: []const u8, comptime page: []const u8, comptime follow_flags: bool) []const u8 {
    const pk_cols = if (pk.len != 0) pk ++ ", " else "";
    const pk_r = if (pk.len != 0) "r." ++ pk ++ ", " else "";
    const same_page = "sel.lim = r.lim AND sel.off = r.off" ++ (if (pk.len != 0) " AND sel." ++ pk ++ " = r." ++ pk else "");
    const same_pgi = "pgi.lim = r.lim AND pgi.off = r.off" ++ (if (pk.len != 0) " AND pgi." ++ pk ++ " = r." ++ pk else "");
    return "WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::int4[], $3::int4[]" ++ (if (has_key) ", $4::text[]" else "") ++
        ") WITH ORDINALITY AS r(viewer, lim, off, " ++ (if (has_key) "key, " else "") ++ "i)), " ++
        cnt ++ ", " ++
        "pg0 AS MATERIALIZED (SELECT DISTINCT " ++ pk_cols ++ "lim, off FROM r), " ++
        "sel AS MATERIALIZED (SELECT " ++ pk_r ++ "r.lim, r.off, q.id FROM pg0 r CROSS JOIN LATERAL (" ++ page ++ ") q), " ++
        "dec AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT id FROM sel) d CROSS JOIN LATERAL (SELECT " ++ dec_cols_common ++
        " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = d.id OFFSET 0) x), " ++
        "pgi AS MATERIALIZED (SELECT " ++ (if (pk.len != 0) "sel." ++ pk ++ ", " else "") ++ "sel.lim, sel.off, array_agg(sel.id) AS ids, array_agg(DISTINCT dec.author_id) AS authors " ++
        "FROM sel JOIN dec ON dec.id = sel.id GROUP BY " ++ (if (pk.len != 0) "sel." ++ pk ++ ", " else "") ++ "sel.lim, sel.off), " ++
        "fl AS MATERIALIZED (SELECT r.i, " ++
        "ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = ANY(pgi.ids)) AS fav" ++
        (if (follow_flags) ", ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = ANY(pgi.authors)) AS fol" else "") ++
        " FROM r LEFT JOIN pgi ON " ++ same_pgi ++ ") " ++
        "SELECT r.i, cnt.n, dec.id, dec.slug, dec.title, dec.description, dec.created_at, dec.updated_at, dec.tag_list, dec.fav_count, " ++
        "COALESCE(dec.id = ANY(fl.fav), false), dec.username, dec.bio, dec.image, " ++
        (if (follow_flags) "COALESCE(dec.author_id = ANY(fl.fol), false)" else "true") ++
        " FROM r " ++ cnt_join ++ " JOIN fl ON fl.i = r.i LEFT JOIN sel ON " ++ same_page ++ " LEFT JOIN dec ON dec.id = sel.id ORDER BY r.i, sel.id DESC";
}

fn countPerKey(comptime key_col: []const u8, comptime from_where: []const u8) []const u8 {
    return "cnt AS MATERIALIZED (SELECT k." ++ key_col ++ ", c.n FROM (SELECT DISTINCT " ++ key_col ++
        " FROM r) k CROSS JOIN LATERAL (SELECT count(*)::int8 AS n FROM (SELECT 1 " ++ from_where ++ " LIMIT 1000) s) c)";
}

const b_list_global = listBatch(
    false,
    "cnt AS MATERIALIZED (SELECT count(*)::int8 AS n FROM (SELECT 1 FROM articles LIMIT 1000) s)",
    "CROSS JOIN cnt",
    "",
    "SELECT id FROM articles ORDER BY id DESC OFFSET r.off LIMIT r.lim",
    true,
);

const b_list_tag = listBatch(
    true,
    countPerKey("key", "FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = k.key)"),
    "JOIN cnt ON cnt.key = r.key",
    "key",
    "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.key) ORDER BY at.article_id DESC OFFSET r.off LIMIT r.lim",
    true,
);

const b_list_author = listBatch(
    true,
    countPerKey("key", "FROM articles a WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = k.key)"),
    "JOIN cnt ON cnt.key = r.key",
    "key",
    "SELECT id FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = r.key) ORDER BY id DESC OFFSET r.off LIMIT r.lim",
    true,
);

const b_list_fav = listBatch(
    true,
    countPerKey("key", "FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = k.key)"),
    "JOIN cnt ON cnt.key = r.key",
    "key",
    "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = r.key) ORDER BY f.article_id DESC OFFSET r.off LIMIT r.lim",
    true,
);

// the feed is the viewer's own: its pages are per viewer and every article on it is by someone the viewer follows
const b_feed = listBatch(
    false,
    "ff AS MATERIALIZED (SELECT v.viewer, ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id = v.viewer) AS ids FROM (SELECT DISTINCT viewer FROM r) v), " ++
        "hc AS MATERIALIZED (SELECT x.id FROM ff CROSS JOIN LATERAL unnest(ff.ids) x(id) GROUP BY x.id ORDER BY count(*) DESC, x.id LIMIT 8), " ++
        "heavy AS MATERIALIZED (SELECT hc.id FROM hc WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = hc.id OFFSET 999 LIMIT 1)), " ++
        "cnt AS MATERIALIZED (SELECT ff.viewer, CASE WHEN EXISTS (SELECT 1 FROM heavy h WHERE h.id = ANY(ff.ids)) THEN 1000::int8 " ++
        "ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(ff.ids) LIMIT 1000) s) END AS n FROM ff)",
    "JOIN cnt ON cnt.viewer = r.viewer",
    "viewer",
    "SELECT x.id FROM ff CROSS JOIN LATERAL unnest(ff.ids) fo(id) CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.id ORDER BY a2.id DESC LIMIT (r.lim + r.off)) x WHERE ff.viewer = r.viewer ORDER BY x.id DESC OFFSET r.off LIMIT r.lim",
    false,
);

const b_article =
    "WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, i)), " ++
    "dec AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT slug FROM r) k CROSS JOIN LATERAL (SELECT " ++ dec_cols_common ++ ", a.body" ++
    " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = k.slug OFFSET 0) x) " ++
    "SELECT r.i, dec.id, dec.slug, dec.title, dec.description, dec.created_at, dec.updated_at, dec.tag_list, dec.fav_count, " ++
    flag_favorited ++ ", dec.username, dec.bio, dec.image, " ++ flag_following ++ ", dec.body FROM r JOIN dec ON dec.slug = r.slug ORDER BY r.i";

// --- batched variants -------------------------------------------------------------------------------------
// Reads of the same kind that are waiting together run as one statement:
//   SELECT r.i, x.* FROM unnest($1::T1[], $2::T2[], ...) WITH ORDINALITY AS r(p1, p2, ..., i)
//   CROSS JOIN LATERAL (<the single-request statement, $k replaced by r.pk>) x
// Every request is still executed by its own run of its query (nested loop over r, correlated on its parameters).

fn rewrite(comptime sql: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var out: []const u8 = "";
        var i: usize = 0;
        while (i < sql.len) : (i += 1) {
            if (sql[i] == '$' and i + 1 < sql.len and sql[i + 1] >= '0' and sql[i + 1] <= '9') {
                out = out ++ "r.p" ++ sql[i + 1 .. i + 2];
                i += 1;
            } else out = out ++ sql[i .. i + 1];
        }
        return out;
    }
}

fn arrayType(comptime oid: u32) []const u8 {
    return switch (oid) {
        I8 => "int8[]",
        I4 => "int4[]",
        TX => "text[]",
        else => @compileError("no array type for this parameter"),
    };
}

fn arrayOid(comptime oid: u32) u32 {
    return switch (oid) {
        I8 => I8A,
        I4 => I4A,
        TX => TA,
        else => @compileError("no array oid"),
    };
}

/// The batched form of a single-request statement. The reply splitter relies on the rows arriving grouped by ordinal in
/// ascending order, which only an explicit ORDER BY guarantees (`inner_order` repeats the statement's own row order).
fn batchedSql(comptime d: Def, comptime inner_order: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(2_000_000);
        var un: []const u8 = "";
        var names: []const u8 = "";
        for (d.params, 0..) |o, k| {
            const n: []const u8 = &[1]u8{'1' + @as(u8, k)};
            un = un ++ (if (k > 0) ", " else "") ++ "$" ++ n ++ "::" ++ arrayType(o);
            names = names ++ "p" ++ n ++ ", ";
        }
        return "SELECT r.i, x.* FROM unnest(" ++ un ++ ") WITH ORDINALITY AS r(" ++ names ++ "i) CROSS JOIN LATERAL (" ++ rewrite(d.sql) ++ ") x ORDER BY r.i" ++ inner_order;
    }
}

fn batchedParams(comptime d: Def) []const u32 {
    comptime {
        var out: [d.params.len]u32 = undefined;
        for (d.params, 0..) |o, k| out[k] = arrayOid(o);
        const fin = out;
        return &fin;
    }
}

/// Kinds that can run batched, and their batched definitions (indexed like `defs`, `null` = not batchable).
pub const batchable = [_]Stmt{ .list_global, .list_tag, .list_author, .list_fav, .feed, .article, .comments, .profile };

pub const bdefs = blk: {
    var d: [defs.len]?Def = @splat(null);
    for (batchable) |k| {
        const base = defs[@backingInt(k)];
        const shared_sql: ?[]const u8 = switch (k) {
            .list_global => b_list_global,
            .list_tag => b_list_tag,
            .list_author => b_list_author,
            .list_fav => b_list_fav,
            .feed => b_feed,
            .article => b_article,
            else => null,
        };
        d[@backingInt(k)] = .{ .sql = shared_sql orelse batchedSql(base, if (k == .comments) ", x.created_at DESC, x.id DESC" else ""), .params = batchedParams(base) };
    }
    break :blk d;
};

/// Statement id used for the batched variant of `s` (prepared after all the single statements).
pub inline fn batchId(s: Stmt) u16 {
    return @as(u16, @intCast(defs.len)) + @as(u16, @backingInt(s));
}

pub inline fn id(s: Stmt) u16 {
    return @backingInt(s);
}

// --- the batch planner's statements ---------------------------------------------------------------------------------
// A planned batch runs in two phases. Phase A has one statement per kind of request present; each takes arrays of the
// batch's DISTINCT keys and returns lean rows tagged with the key's 1-based ordinal `k` (counts: k <= 0, -k is the count
// key's ordinal, the count in column 1). Phase B enriches the union of every article phase A returned, once (author,
// favourite count, tag names) and resolves the viewers' favourited / following flags with one `= ANY` range scan per
// viewer. Rows are assembled into each request's reply in the server.

/// Proof that a count reaches the 1,000 cap without aggregating, else the exact count.
fn capped(comptime rows: []const u8) []const u8 {
    return "CASE WHEN EXISTS (" ++ rows ++ " OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM (" ++ rows ++ " LIMIT 1000) s) END";
}

/// Article row columns after `k`: id, author_id, slug, title, description, created_at, updated_at.
const plan_cols = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";
/// NULL padding of a count row (matches plan_cols after the count).
const plan_pad = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

pub const PlanStmt = enum(u8) {
    a_global,
    a_tag,
    a_author,
    a_fav,
    a_feed,
    a_slug,
    a_cmts,
    a_prof,
    b_artx,
    b_fc,
    b_names,
    b_flags,
};

pub const plan_defs = blk: {
    var d: [std.meta.fieldNames(PlanStmt).len]Def = undefined;
    d[@backingInt(PlanStmt.a_global)] = .{
        .sql = "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), " ++ plan_pad ++
            " UNION ALL SELECT r.k, " ++ plan_cols ++ " FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) " ++
            "CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
        .params = &.{ I8A, I8A },
    };
    d[@backingInt(PlanStmt.a_tag)] = .{
        .sql = "SELECT -r.k, " ++ capped("SELECT 1 FROM article_tags at WHERE at.tag_id = t.id") ++ ", " ++ plan_pad ++
            " FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag UNION ALL " ++
            "SELECT r.k, " ++ plan_cols ++ " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(tag, lim, off, k) " ++
            "JOIN tags t ON t.name = r.tag CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id " ++
            "ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p JOIN articles a ON a.id = p.article_id",
        .params = &.{ TA, TA, I8A, I8A },
    };
    d[@backingInt(PlanStmt.a_author)] = .{
        .sql = "SELECT -r.k, " ++ capped("SELECT 1 FROM articles a WHERE a.author_id = u.id") ++ ", " ++ plan_pad ++
            " FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username UNION ALL " ++
            "SELECT r.k, " ++ plan_cols ++ " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) " ++
            "JOIN users u ON u.username = r.username CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id " ++
            "ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
        .params = &.{ TA, TA, I8A, I8A },
    };
    d[@backingInt(PlanStmt.a_fav)] = .{
        .sql = "SELECT -r.k, " ++ capped("SELECT 1 FROM favorites f WHERE f.user_id = u.id") ++ ", " ++ plan_pad ++
            " FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username UNION ALL " ++
            "SELECT r.k, " ++ plan_cols ++ " FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) " ++
            "JOIN users u ON u.username = r.username CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id " ++
            "ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p JOIN articles a ON a.id = p.article_id",
        .params = &.{ TA, TA, I8A, I8A },
    };
    d[@backingInt(PlanStmt.a_feed)] = .{
        .sql = "WITH ff AS MATERIALIZED (SELECT v, ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id = v) AS ids FROM (SELECT DISTINCT unnest($1::int8[] || $2::int8[]) AS v) q), " ++
            "hc AS MATERIALIZED (SELECT x.id FROM ff CROSS JOIN LATERAL unnest(ff.ids) x(id) GROUP BY x.id ORDER BY count(*) DESC, x.id LIMIT 8), " ++
            "heavy AS MATERIALIZED (SELECT hc.id FROM hc WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = hc.id OFFSET 999 LIMIT 1)) " ++
            "SELECT -r.k, CASE WHEN EXISTS (SELECT 1 FROM heavy h WHERE h.id = ANY(ff.ids)) THEN 1000::int8 ELSE " ++
            capped("SELECT 1 FROM articles a WHERE a.author_id = ANY(ff.ids) ORDER BY a.author_id, a.id DESC") ++
            " END, " ++ plan_pad ++ " FROM unnest($1::int8[]) WITH ORDINALITY r(v, k) JOIN ff ON ff.v = r.v UNION ALL " ++
            "SELECT r.k, " ++ plan_cols ++ " FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY r(v, lim, off, k) JOIN ff ON ff.v = r.v " ++
            "CROSS JOIN LATERAL (SELECT y.id FROM unnest(ff.ids) fo(id) CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.id " ++
            "ORDER BY a2.id DESC LIMIT r.lim + r.off) y ORDER BY y.id DESC LIMIT r.lim OFFSET r.off) x JOIN articles a ON a.id = x.id",
        .params = &.{ I8A, I8A, I8A, I8A },
    };
    // k, id, author_id, slug, title, description, created_at, updated_at, body
    d[@backingInt(PlanStmt.a_slug)] = .{
        .sql = "SELECT r.k, " ++ plan_cols ++ ", a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug",
        .params = &.{TA},
    };
    // k, article id, comment id, body, created_at, updated_at, author_id, username, bio, image (one all-NULL comment row for an article without comments)
    d[@backingInt(PlanStmt.a_cmts)] = .{
        .sql = "SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image " ++
            "FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug " ++
            "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id " ++
            "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id = c.author_id",
        .params = &.{TA},
    };
    d[@backingInt(PlanStmt.a_prof)] = .{
        .sql = "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) JOIN users u ON u.username = r.username",
        .params = &.{TA},
    };
    // id, username, bio, image of each distinct article's author
    d[@backingInt(PlanStmt.b_artx)] = .{
        .sql = "SELECT r.id, u.username, u.bio, u.image FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
        .params = &.{ I8A, I8A },
    };
    d[@backingInt(PlanStmt.b_fc)] = .{
        .sql = "SELECT f.article_id, count(*) FROM favorites f WHERE f.article_id = ANY($1::int8[]) GROUP BY f.article_id",
        .params = &.{I8A},
    };
    d[@backingInt(PlanStmt.b_names)] = .{
        .sql = "SELECT at.article_id, t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = ANY($1::int8[]) ORDER BY at.article_id, t.name",
        .params = &.{I8A},
    };
    // (0, viewer, article) per favourited pair asked about, (1, viewer, followee) per followed pair
    d[@backingInt(PlanStmt.b_flags)] = .{
        .sql = "WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), " ++
            "q AS (SELECT x.v, array_agg(x.u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) " ++
            "SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.aa)) f " ++
            "UNION ALL SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.uu)) fo",
        .params = &.{ I8A, I8A, I8A, I8A },
    };
    break :blk d;
};

/// Statement id of a planner statement. Batched statements use ids defs.len + <statement kind>, so these start past all of them.
pub inline fn planId(s: PlanStmt) u16 {
    return @as(u16, @intCast(2 * defs.len)) + @as(u16, @backingInt(s));
}

const TZ = 1184;
const BO = pg.oid.bool_;
const article_oids = [_]u32{ I8, TX, TX, TX, TZ, TZ, TA, I8, BO, TX, TX, TX, BO, TX };
const profile_oids = [_]u32{ I8, TX, TX, TX, BO };
const comment_oids = [_]u32{ I8, TX, TZ, TZ, TX, TX, TX, BO };

pub fn resultOids(comptime statement: u16) []const u32 {
    if (statement >= mutations.base_id) return mutations.resultOids(statement - mutations.base_id);
    if (statement == packed_id) return &.{ I8, I8, I8, I8, TX, TX, TX, TZ, TZ, TX, TA, I8, TX, TX, TX, I8A, I8A, I8A };
    if (statement >= 2 * defs.len) {
        return switch (@as(PlanStmt, @fromBackingInt(@intCast(statement - 2 * defs.len)))) {
            .a_global, .a_tag, .a_author, .a_fav, .a_feed => &.{ I8, I8, I8, TX, TX, TX, TZ, TZ },
            .a_slug => &.{ I8, I8, I8, TX, TX, TX, TZ, TZ, TX },
            .a_cmts => &.{ I8, I8, I8, TX, TZ, TZ, I8, TX, TX, TX },
            .a_prof => &.{ I8, I8, TX, TX, TX },
            .b_artx => &.{ I8, TX, TX, TX },
            .b_fc => &.{ I8, I8 },
            .b_names => &.{ I8, TX },
            .b_flags => &.{ I8, I8, I8 },
        };
    }
    if (statement >= defs.len) return &([_]u32{I8} ++ resultOids(statement - defs.len)[0..resultOids(statement - defs.len).len].*);
    return switch (@as(Stmt, @fromBackingInt(@intCast(statement)))) {
        .tx_begin, .tx_commit, .art_insert, .art_tags, .art_attach => &.{},
        .tags => &.{TX},
        .user_by_id, .user_insert, .user_update => &.{ I8, TX, TX, TX, TX },
        .user_login => &.{ I8, TX, TX, TX, TX, TX },
        .profile => &profile_oids,
        .follow, .unfollow => &.{ TX, TX, TX },
        .list_global, .list_tag, .list_author, .list_fav, .feed => &([_]u32{I8} ++ article_oids[0..13].*),
        .article, .art_new, .fav_add, .fav_del => &article_oids,
        .comments => &comment_oids,
        .comment_insert => comment_oids[0..7],
        .comment_delete, .art_delete => &.{ I8, BO },
        .art_update => &([_]u32{ I8, I8 } ++ article_oids),
    };
}

pub const packed_id: u16 = 2 * defs.len + plan_defs.len;
pub const packed_sql = @embedFile("packed.sql");

pub const Prep = struct { id: u16, sql: []const u8, params: []const u32 };

/// Every statement to prepare on a new connection: the single-request statements, the batched variants, the planner's.
pub const prepared = blk: {
    var out: [defs.len + batchable.len + plan_defs.len + 1 + mutations.defs.len]Prep = undefined;
    for (defs, 0..) |d, i| out[i] = .{ .id = @intCast(i), .sql = d.sql, .params = d.params };
    for (batchable, 0..) |k, j| {
        const b = bdefs[@backingInt(k)].?;
        out[defs.len + j] = .{ .id = batchId(k), .sql = b.sql, .params = b.params };
    }
    for (plan_defs, 0..) |d, j| out[defs.len + batchable.len + j] = .{ .id = planId(@fromBackingInt(@intCast(j))), .sql = d.sql, .params = d.params };
    out[defs.len + batchable.len + plan_defs.len] = .{ .id = packed_id, .sql = packed_sql, .params = &.{ I4A, I8A, I4A, I4A, TA } };
    for (mutations.defs, 0..) |d, i| out[defs.len + batchable.len + plan_defs.len + 1 + i] = .{ .id = mutations.base_id + @as(u16, @intCast(i)), .sql = d.sql, .params = d.params };
    break :blk out;
};
