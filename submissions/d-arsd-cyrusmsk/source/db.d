/// The Postgres layer: one connection per worker thread and the reference SQL
/// from SPEC.md.
///
/// arsd.postgres executes SQL through libpq's simple-query protocol and
/// substitutes escaped literals for `?`/`?n` placeholders rather than using
/// server-side prepared statements. Because a libpq call blocks the calling
/// thread, and a worker thread runs exactly one fiber at a time, a single
/// connection per worker thread is enough: no pool locking, no connection ever
/// handed to another thread. The connection is opened lazily (after the server
/// has forked) and reused for the life of the thread.
module conduit.db;

import arsd.postgres;

import std.array : appender;
import std.string : indexOf;
import std.variant : Variant;

/// DATABASE_URL, recorded once in main().
__gshared string g_dbUrl;

/// This thread's connection, opened on first use.
private static PostgreSql tlsConnection;

/// Borrows the calling thread's connection, opening it on first use.
PostgreSql dbConn()
{
    if (tlsConnection is null)
    {
        auto conn = new PostgreSql(connectionUrl());
        conn.queryImpl("SET TIME ZONE 'UTC'");
        conn.queryImpl("SET jit = off");
        tlsConnection = conn;
    }
    return tlsConnection;
}

/// The URL, forced to plain TCP: the benchmark's Postgres speaks no TLS.
private string connectionUrl()
{
    auto url = g_dbUrl;
    if (url.indexOf("sslmode=") < 0)
        url ~= (url.indexOf('?') >= 0 ? "&" : "?") ~ "sslmode=disable";
    return url;
}

/// A `Variant` holding a string value. The slice is made mutable (`char[]`), so
/// arsd's `toSql` renders it as a quoted literal even when it is empty; only
/// [vnull] produces SQL NULL.
Variant vstr(const(char)[] s)
{
    // A null `string` is arsd's marker for SQL NULL, so an empty value must
    // still be a non-null slice: the sentinel gives length 0 with a valid
    // pointer, which renders as ''.
    static char[1] sentinel;
    string value = s.length ? s.idup : cast(string) sentinel[0 .. 0];
    return Variant(value);
}

/// A `Variant` holding SQL NULL.
Variant vnull()
{
    string empty;
    return Variant(empty);
}

/// A `Variant` holding an integer (rendered as a quoted literal, which Postgres
/// coerces in every context the SQL uses).
Variant vlong(long v)
{
    return Variant(v);
}

/// A PostgreSQL `text[]` array literal for a list of tags, e.g. `{"d",` `"go"}`.
/// Each element is double-quoted with `"` and `\` escaped.
string pgTextArray(string[] items)
{
    auto out_ = appender!(char[])();
    out_.put('{');
    foreach (i, item; items)
    {
        if (i)
            out_.put(',');
        out_.put('"');
        foreach (c; item)
        {
            if (c == '"' || c == '\\')
                out_.put('\\');
            out_.put(c);
        }
        out_.put('"');
    }
    out_.put('}');
    return out_.data.idup;
}

/// Rolls back a transaction, ignoring any error (the connection may already be
/// gone); used from `scope(exit)` where throwing is not an option.
void rollbackQuietly(PostgreSql conn) nothrow
{
    try
        conn.queryImpl("ROLLBACK");
    catch (Throwable)
    {
    }
}

/// True when a statement failed on a unique constraint (SPEC.md: 422).
bool isDuplicate(Throwable e)
{
    for (Throwable t = e; t !is null; t = t.next)
        if (t.msg.indexOf("duplicate key value violates unique constraint") >= 0)
            return true;
    return false;
}

// The reference SQL from SPEC.md, with `$n` rewritten to arsd's zero-based
// `?n` and timestamps produced by Postgres as RFC 3339 with 3 fractional
// digits. `?n` is explicit so a parameter used twice is passed once.

/// ARTICLE_LIST_SELECT: `?0` is the viewer.
private enum listSelect = `SELECT a.id, a.slug, a.title, a.description,
       to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
       to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
       COALESCE((SELECT json_agg(t.name ORDER BY t.name) FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id), '[]') AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?0) AS favorited,
       u.username,
       (CASE WHEN u.bio IS NULL THEN E'\x01N' ELSE E'\x01V' || u.bio END) AS bio,
       (CASE WHEN u.image IS NULL THEN E'\x01N' ELSE E'\x01V' || u.image END) AS image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ?0 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id`;

/// ARTICLE_FULL_SELECT: the same query with `a.body` after `a.description`.
private enum fullSelect = `SELECT a.id, a.slug, a.title, a.description, a.body,
       to_char(a.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
       to_char(a.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
       COALESCE((SELECT json_agg(t.name ORDER BY t.name) FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id), '[]') AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ?0) AS favorited,
       u.username,
       (CASE WHEN u.bio IS NULL THEN E'\x01N' ELSE E'\x01V' || u.bio END) AS bio,
       (CASE WHEN u.image IS NULL THEN E'\x01N' ELSE E'\x01V' || u.image END) AS image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ?0 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id`;

enum
{
    // -- users --
    insertUser = `INSERT INTO users (username, email, password_hash) VALUES (?0, ?1, ?2)
 ON CONFLICT DO NOTHING
 RETURNING id, username, email,
       (CASE WHEN bio IS NULL THEN E'\x01N' ELSE E'\x01V' || bio END) AS bio,
       (CASE WHEN image IS NULL THEN E'\x01N' ELSE E'\x01V' || image END) AS image`,
    userByEmail = `SELECT id, username, email,
       (CASE WHEN bio IS NULL THEN E'\x01N' ELSE E'\x01V' || bio END) AS bio,
       (CASE WHEN image IS NULL THEN E'\x01N' ELSE E'\x01V' || image END) AS image,
       password_hash FROM users WHERE email = ?0`,
    userById = `SELECT id, username, email,
       (CASE WHEN bio IS NULL THEN E'\x01N' ELSE E'\x01V' || bio END) AS bio,
       (CASE WHEN image IS NULL THEN E'\x01N' ELSE E'\x01V' || image END) AS image
  FROM users WHERE id = ?0`,
    updateUserSql = `UPDATE users SET email = COALESCE(?1, email), username = COALESCE(?2, username),
                 password_hash = COALESCE(?3, password_hash), bio = COALESCE(?4, bio), image = COALESCE(?5, image)
 WHERE id = ?0
 RETURNING id, username, email,
       (CASE WHEN bio IS NULL THEN E'\x01N' ELSE E'\x01V' || bio END) AS bio,
       (CASE WHEN image IS NULL THEN E'\x01N' ELSE E'\x01V' || image END) AS image`,

    // -- profiles --
    profile = `SELECT u.id, u.username,
       (CASE WHEN u.bio IS NULL THEN E'\x01N' ELSE E'\x01V' || u.bio END) AS bio,
       (CASE WHEN u.image IS NULL THEN E'\x01N' ELSE E'\x01V' || u.image END) AS image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ?0 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = ?1`,
    userByUsername = `SELECT id, username,
       (CASE WHEN bio IS NULL THEN E'\x01N' ELSE E'\x01V' || bio END) AS bio,
       (CASE WHEN image IS NULL THEN E'\x01N' ELSE E'\x01V' || image END) AS image
  FROM users WHERE username = ?0`,
    insertFollow = `INSERT INTO follows (follower_id, followee_id) VALUES (?0, ?1) ON CONFLICT DO NOTHING`,
    deleteFollow = `DELETE FROM follows WHERE follower_id = ?0 AND followee_id = ?1`,

    // -- article lists --
    listAll = listSelect ~ `
 ORDER BY a.id DESC LIMIT ?1 OFFSET ?2`,
    countAll = `SELECT count(*) FROM (SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000) s`,
    listByTag = listSelect ~ `
 WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?3) ORDER BY at.article_id DESC LIMIT ?1 OFFSET ?2)
 ORDER BY a.id DESC`,
    countByTag = `SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ?0) LIMIT 1000) s`,
    listByAuthor = listSelect ~ `
 WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = ?3)
 ORDER BY a.id DESC LIMIT ?1 OFFSET ?2`,
    countByAuthor = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = ?0) LIMIT 1000) s`,
    listByFavorite = listSelect ~ `
 WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?3) ORDER BY f.article_id DESC LIMIT ?1 OFFSET ?2)
 ORDER BY a.id DESC`,
    countByFavorite = `SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ?0) LIMIT 1000) s`,
    listFeed = listSelect ~ `
 WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
    (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (?1::int8 + ?2::int8)) x
  WHERE fo.follower_id = ?0 ORDER BY x.id DESC LIMIT ?1 OFFSET ?2) ORDER BY a.id DESC`,
    countFeed = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = ?0) LIMIT 1000) s`,

    // -- a single article --
    articleBySlug = fullSelect ~ ` WHERE a.slug = ?1`,
    articleById = fullSelect ~ ` WHERE a.id = ?1`,
    articleIdBySlug = `SELECT id FROM articles WHERE slug = ?0`,
    articleOwner = `SELECT id, author_id FROM articles WHERE slug = ?0`,

    // -- article writes --
    insertArticle = `INSERT INTO articles (id, slug, author_id, title, description, body)
 SELECT n.id, trim(both '-' from lower(regexp_replace(?1, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, ?0, ?1, ?2, ?3
   FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
 RETURNING id`,
    insertTags = `INSERT INTO tags (name) SELECT DISTINCT unnest(?0::text[]) ON CONFLICT (name) DO NOTHING`,
    insertArticleTags = `INSERT INTO article_tags (article_id, tag_id) SELECT ?0, t.id FROM tags t WHERE t.name = ANY(?1::text[])`,
    updateArticleSql = `UPDATE articles SET title = COALESCE(?1, title), description = COALESCE(?2, description), body = COALESCE(?3, body),
       slug = CASE WHEN ?1::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace(?1, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = ?0`,
    deleteArticleSql = `DELETE FROM articles WHERE id = ?0`,
    insertFavorite = `INSERT INTO favorites (user_id, article_id) VALUES (?0, ?1) ON CONFLICT DO NOTHING`,
    deleteFavorite = `DELETE FROM favorites WHERE user_id = ?0 AND article_id = ?1`,

    // -- comments --
    commentsByArticle = `SELECT c.id, c.body,
       to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
       to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
       u.username,
       (CASE WHEN u.bio IS NULL THEN E'\x01N' ELSE E'\x01V' || u.bio END) AS bio,
       (CASE WHEN u.image IS NULL THEN E'\x01N' ELSE E'\x01V' || u.image END) AS image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ?0 AND fo.followee_id = c.author_id) AS following
  FROM comments c JOIN users u ON u.id = c.author_id
 WHERE c.article_id = ?1
 ORDER BY c.created_at DESC, c.id DESC
 LIMIT 100`,
    insertComment = `WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES (?0, ?1, ?2)
           RETURNING id, body, created_at, updated_at, author_id)
 SELECT c.id, c.body,
       to_char(c.created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS created_at,
       to_char(c.updated_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"') AS updated_at,
       u.username,
       (CASE WHEN u.bio IS NULL THEN E'\x01N' ELSE E'\x01V' || u.bio END) AS bio,
       (CASE WHEN u.image IS NULL THEN E'\x01N' ELSE E'\x01V' || u.image END) AS image
   FROM c JOIN users u ON u.id = c.author_id`,
    commentOwner = `SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = ?0 AND a.slug = ?1`,
    deleteCommentSql = `DELETE FROM comments WHERE id = ?0`,

    // -- tags --
    tagsAll = `SELECT name FROM tags ORDER BY name`,
}
