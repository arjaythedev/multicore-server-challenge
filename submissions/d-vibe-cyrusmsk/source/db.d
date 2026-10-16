/// The Postgres layer: one connection pool per worker thread, with every
/// statement prepared once per connection.
///
/// The SQL below is the reference SQL from SPEC.md, verbatim (including the
/// in-SQL SLUGIFY), so each statement can be checked against the spec line by
/// line. A request never dials: connections are opened and prepared once, at
/// startup, and then reused for the life of the process.
module conduit.db;

import vibe.db.postgresql;

/// All statements, each under the name it is prepared as.
private struct Statements
{
    // -- users --
    enum insertUser = `INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image`;
    enum userByEmail = `SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1`;
    enum userById = `SELECT id, username, email, bio, image FROM users WHERE id = $1`;
    enum updateUser = `UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image`;

    // -- profiles --
    enum profile = `SELECT u.id, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
  FROM users u WHERE u.username = $2`;
    enum userByUsername = `SELECT id, username, bio, image FROM users WHERE username = $1`;
    enum insertFollow = `INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`;
    enum deleteFollow = `DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2`;

    // -- article lists: SPEC.md's ARTICLE_LIST_SELECT, one prepared statement
    // per filter, each with its capped count --
    enum listAll = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 ORDER BY a.id DESC LIMIT $2 OFFSET $3`;
    // The count walks the primary key from the oldest end: those pages are
    // all-visible (frozen), so it stays an index-only scan with no heap
    // fetches. Same answer either way: min(count, 1000).
    enum countAll = `SELECT count(*) FROM (SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000) s`;
    enum listByTag = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)
 ORDER BY a.id DESC`;
    enum countByTag = `SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s`;
    enum listByAuthor = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)
 ORDER BY a.id DESC LIMIT $2 OFFSET $3`;
    enum countByAuthor = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s`;
    enum listByFavorite = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)
 ORDER BY a.id DESC`;
    enum countByFavorite = `SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s`;
    // Note: $2 and $3 arrive as binary int8 (that is how a D long encodes),
    // so the reference $2::int + $3::int would reject their format; ::int8
    // computes the same sum and LIMIT accepts it.
    enum listFeed = `SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
    (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int8 + $3::int8)) x
  WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC`;
    enum countFeed = `SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s`;

    // -- a single article, with body --
    enum articleBySlug = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.slug = $2`;
    enum articleById = `SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a
  JOIN users u ON u.id = a.author_id
 WHERE a.id = $2`;

    enum articleIdBySlug = `SELECT id FROM articles WHERE slug = $1`;
    enum articleOwner = `SELECT id, author_id FROM articles WHERE slug = $1`;

    // -- article writes (the insert runs in one transaction, as in SPEC.md) --
    enum insertArticle = `INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id`;
    enum insertTags = `INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING`;
    enum insertArticleTags = `INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])`;
    enum updateArticle = `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1`;
    enum deleteArticle = `DELETE FROM articles WHERE id = $1`;
    enum insertFavorite = `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`;
    enum deleteFavorite = `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`;

    // -- comments --
    enum commentsByArticle = `SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
  FROM comments c JOIN users u ON u.id = c.author_id
 WHERE c.article_id = $2
 ORDER BY c.created_at DESC, c.id DESC
 LIMIT 100`;
    enum insertComment = `WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3)
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`;
    enum commentOwner = `SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2`;
    enum deleteComment = `DELETE FROM comments WHERE id = $1`;

    // -- tags --
    enum tagsAll = `SELECT name FROM tags ORDER BY name`;
}

/// The statement names, so a caller can't typo one: `Name.tagsAll` is "tagsAll".
struct Name
{
    mixin(statementNames());
}

/// `"insertUser = \"insertUser\"; ..."` for every statement.
private string statementNames()
{
    import std.format : format;

    string names;
    static foreach (member; __traits(allMembers, Statements))
        names ~= format!"enum %s = \"%s\";"(member, member);
    return names;
}

/// All statements, by name, for preparing them on a new connection.
private string[string] allStatements()
{
    string[string] statements;
    static foreach (name; __traits(allMembers, Statements))
        statements[name] = __traits(getMember, Statements, name);
    return statements;
}

/// One connection pool per worker thread: a vibe.d connection belongs to the
/// thread that opened it, so a pool must never be shared between threads.
///
/// The pool holds at most `maxConns` connections; they are opened lazily and
/// reused for the life of the process, so a request never dials.
final class Db
{
    private PostgresClient client;

    this(string connString, uint maxConns)
    {
        client = new PostgresClient(connString, maxConns, (conn) => initConnection(conn));
    }

    /// Opens every connection and prepares the statements up front, so no
    /// request pays the setup cost.
    void warmUp(uint connections)
    {
        foreach (_; 0 .. connections)
        {
            auto conn = client.lockConnection;
            conn.exec("SELECT 1");
        }
    }

    /// Borrows a connection for the calling fiber. Holding the lock across
    /// several calls keeps them on the same connection.
    auto lockConnection()
    {
        return client.lockConnection;
    }
}

/// Runs once per new connection: force a UTC session and prepare everything.
private void initConnection(Connection conn)
{
    conn.exec(`SET TIME ZONE 'UTC'`);
    // Our statements are prepared once and executed with ever-changing
    // parameters; generic plans avoid re-planning per execution, and JIT
    // never pays for these point queries. Session-level SET, allowed.
    conn.exec(`SET plan_cache_mode = force_generic_plan`);
    conn.exec(`SET jit = off`);
    foreach (name, sql; allStatements)
        conn.prepareEx(name, sql);
}

/// Runs prepared statements as one libpq pipeline and returns their answers in
/// send order: a single flush carries all of them, so a page and its count
/// cost one round trip instead of two.
///
/// Only for statements whose parameters are all known up front. On any error
/// the pipeline is drained and left clean, and the error is thrown.
immutable(Answer)[] execPipeline(LockedConnection conn, scope const(QueryParams)[] queries)
{
    conn.enterPipelineMode;
    scope (exit)
    {
        while (conn.pipelineStatus == PGpipelineStatus.PQ_PIPELINE_ABORTED)
            conn.getResult(conn.pollingTimeout);
        conn.exitPipelineMode;
    }

    foreach (ref const query; queries)
        conn.sendQueryPrepared(query);
    conn.sendFlushRequest;
    conn.flush();
    conn.pipelineSync;

    immutable(Answer)[] answers;
    foreach (_; queries)
        answers ~= awaitResult(conn).getAnswer;
    if (awaitResult(conn).status != PGRES_PIPELINE_SYNC)
        throw new Exception("pipeline sync failed");
    return answers;
}

/// Reads one pipelined result, waiting (without blocking the thread) for it
/// to arrive. A plain `getResult` cannot be used here: between two pipelined
/// results the connection can briefly look idle, and then it returns null for
/// a result that is still on its way.
private immutable(Result) awaitResult(LockedConnection conn)
{
    import vibe.core.core : sleep;
    import std.datetime : MonoTime;
    import core.time : usecs;

    auto deadline = MonoTime.currTime + conn.requestTimeout;
    while (true)
    {
        if (auto result = conn.getResult(conn.requestTimeout))
            return result;
        if (MonoTime.currTime >= deadline)
            throw new Exception("timed out waiting for a pipelined result");
        // Nothing buffered (or nothing arrived yet): pull in whatever is on
        // the socket, then yield so other requests proceed while waiting.
        conn.consumeInput();
        sleep(100.usecs);
    }
}
