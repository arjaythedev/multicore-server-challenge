/**
 * The Postgres layer: one `vibe.d` connection pool per worker thread, with every
 * statement prepared once per connection.
 *
 * AGENTS.md notes translate to: reuse a fixed set of connections instead of
 * dialing per request, prepare SQL once and reuse it afterwards, and let the
 * database batch commits (a request's write commits before the response is sent
 * - Postgres groups concurrent commits itself).
 *
 * Every statement is listed once, as a prepared statement, and typed through the
 * variables in db.d: strings are passed in the binary (UTF-8) format so Postgres
 * never has to unescape anything, integers go as binary int8, and NULLs are
 * passed as proper NULLs. Results come back in the text format, which lets each
 * row be copied into the JSON response almost byte for byte.
 */
module conduit.db;

import vibe.core.connectionpool;
import vibe.db.postgresql;
import vibe.core.log;

import dpq2;
import dpq2.args : QueryParams;
import dpq2.connection : Connection;

import conduit.json : JsonBuf;

import std.array : Appender, appender;
import std.bitmanip : read;

/// The prepared statements' SQL, one literal per statement. `$n` placeholders are
/// in the order the reference SQL uses.
struct Statements
{
    // users
    enum insertUser = `INSERT INTO users (username, email, password_hash)
         VALUES ($1, $2, $3)
         RETURNING id, username, email, bio, image`;
    enum userByEmail = `SELECT id, username, email, bio, image, password_hash
         FROM users WHERE email = $1`;
    enum userById = `SELECT id, username, email, bio, image
         FROM users WHERE id = $1`;
    enum updateUser = `UPDATE users SET email = COALESCE($2, email),
                      username = COALESCE($3, username),
                      password_hash = COALESCE($4, password_hash),
                      bio = COALESCE($5, bio), image = COALESCE($6, image)
         WHERE id = $1
         RETURNING id, username, email, bio, image`;

    // profiles
    enum profile = `SELECT u.id, u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1
                     AND fo.followee_id = u.id) AS following
         FROM users u WHERE u.username = $2`;
    enum userByUsername = `SELECT id, username, bio, image FROM users WHERE username = $1`;
    enum insertFollow =
        `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`;
    enum deleteFollow = `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`;

    // article lists: SPEC.md ARTICLE_LIST_SELECT, with the filter and ordering
    // inlined per variant so each is a single prepared statement.
    enum listAll = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id
         ORDER BY a.id DESC LIMIT $2 OFFSET $3`;
    enum listByTag = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id
         WHERE a.id IN (SELECT at.article_id FROM article_tags at
                        WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
                        ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)
         ORDER BY a.id DESC`;
    enum listByAuthor = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id
         WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)
         ORDER BY a.id DESC LIMIT $2 OFFSET $3`;
    enum listByFavorite = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id
         WHERE a.id IN (SELECT f.article_id FROM favorites f
                        WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)
                        ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)
         ORDER BY a.id DESC`;
    enum listFeed = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id
         WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
                 (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                  ORDER BY a2.id DESC LIMIT ($2::int8 + $3::int8)) x
             WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)
         ORDER BY a.id DESC`;

    enum countAll = `SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s`;
    enum countByTag = `SELECT count(*) FROM (SELECT 1 FROM article_tags at
         WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`;
    enum countByAuthor = `SELECT count(*) FROM (SELECT 1 FROM articles a
         WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`;
    enum countByFavorite = `SELECT count(*) FROM (SELECT 1 FROM favorites f
         WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`;
    enum countFeed = `SELECT count(*) FROM (SELECT 1 FROM articles a
         WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s`;

    // a single article, with body: by slug and by id share the same column list
    enum articleBySlug = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2`;
    enum articleById = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
             ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                   WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
             u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
         FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2`;

    enum articleIdBySlug = `SELECT id FROM articles WHERE slug = $1`;
    enum articleOwner = `SELECT id, author_id FROM articles WHERE slug = $1`;

    // writes
    // One statement, one implicit transaction: the article, its tags and its tag
    // links. `allt` is what makes the order safe - it depends on `tg`, so the new
    // tags exist before the links are inserted, yet it still returns the tags that
    // were already in the table.
    enum insertArticle = `WITH newid AS MATERIALIZED (
             SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
             art AS (
             INSERT INTO articles (id, slug, author_id, title, description, body)
             SELECT id, $1 || '-' || id, $2, $3, $4, $5 FROM newid RETURNING id),
             tg AS (
             INSERT INTO tags (name) SELECT DISTINCT unnest($6::text[])
                 ON CONFLICT (name) DO NOTHING RETURNING name, id),
             allt AS (
             SELECT name, id FROM tg
             UNION SELECT t.name, t.id FROM tags t WHERE t.name = ANY($6::text[])),
             at AS (
             INSERT INTO article_tags (article_id, tag_id)
             SELECT a.id, t.id FROM art a, allt t)
         SELECT id FROM art`;
    enum updateArticle = `UPDATE articles SET slug = COALESCE($2, slug),
             title = COALESCE($3, title), description = COALESCE($4, description),
             body = COALESCE($5, body), updated_at = now()
         WHERE id = $1`;
    enum deleteArticle = `DELETE FROM articles WHERE id = $1`;
    enum insertFavorite =
        `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`;
    enum deleteFavorite = `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`;

    // comments
    enum commentsByArticle = `SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
         FROM comments c JOIN users u ON u.id = c.author_id
         WHERE c.article_id = $2
         ORDER BY c.created_at DESC, c.id DESC LIMIT 100`;
    enum insertComment = `WITH c AS (INSERT INTO comments (article_id, author_id, body)
             VALUES ($1, $2, $3) RETURNING id, body, created_at, updated_at, author_id)
         SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
         FROM c JOIN users u ON u.id = c.author_id`;
    enum commentOwner = `SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
         WHERE c.id = $1 AND a.slug = $2`;
    enum deleteComment = `DELETE FROM comments WHERE id = $1`;

    enum tags = `SELECT name FROM tags ORDER BY name`;
}

/// The prepared statements, by name: the name is the same as the member of
/// Statements that holds its SQL.
immutable(string[][string]) allStatements() @safe pure
{
    string[][string] m;
    static foreach (name; __traits(allMembers, Statements))
        m[name] = [__traits(getMember, Statements, name)];
    return () @trusted { return cast(immutable) m; }();
}

/// The statement names, so a caller can't typo one: `Name.tags` is "tags".
struct Name
{
    mixin(statementNames);
}

/// "insertUser = \"insertUser\"; ..." for every statement.
private string statementNames()()
{
    import std.format : format;

    string names;
    static foreach (member; __traits(allMembers, Statements))
        names ~= format!"enum %s = \"%s\";"(member, member);
    return names;
}

/// The statement that ran last in this thread, for error messages (the name is
/// a string literal, so recording it costs nothing).
static string lastStatement;

/// Two answers, for the endpoints that run a page and its count.
struct Pair
{
    immutable(Answer) a, b;
}

/// One connection pool per thread: `vibe.d` connections are fiber-bound, so a
/// pool must never hand a connection created by another thread to this one.
///
/// The pool holds at most `maxConns` connections; they are opened lazily and
/// reused for the lifetime of the process (a request never dials).
final class Db
{
    private PostgresClient client;

    this(string connString, uint maxConns)
    {
        import vibe.db.postgresql : PostgresClient;

        // A vibed Postgres connection belongs to the thread that opened it, so the
        // pool hands out only connections this thread created.
        client = new PostgresClient(connString, maxConns, (conn) { initConnection(conn); });
    }

    /// Opens every connection and prepares the statements up front, so that no
    /// request pays the setup cost.
    void warmUp(uint connections)
    {
        foreach (i; 0 .. connections) {
            auto conn = client.lockConnection;
            conn.exec("SELECT 1");
        }
    }

    /// Runs a prepared statement on one of the pooled connections.
    immutable(Answer) exec(QueryParams p) @trusted
    {
        lastStatement = p.sqlCommand;
        auto conn = client.lockConnection;
        return conn.execPrepared(p);
    }

    /// Runs two prepared statements on one connection: an endpoint's page and
    /// its count share the connection the request already holds.
    Pair execPair(QueryParams p1, QueryParams p2) @trusted
    {
        lastStatement = p1.sqlCommand;
        auto conn = client.lockConnection;
        auto a = conn.execPrepared(p1);
        lastStatement = p2.sqlCommand;
        return Pair(a, conn.execPrepared(p2));
    }
}

/// Runs once per new connection: force a UTC session (so timestamptz values render
/// with a "+00" offset and no timezone math is needed) and prepare everything.
private void initConnection(Connection conn) @trusted
{
    conn.exec(`SET TIME ZONE 'UTC'`);
    foreach (name, sql; allStatements)
        conn.prepareEx(name, sql[0]);
}

@safe unittest
{
    assert(allStatements.length > 0);
}


