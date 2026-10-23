module conduit.db;

import dpq2.async.connection : AsyncConnection;
import dpq2.async.waiter : SocketWaiter, SocketWaitMode,
    PostgresClientTimeoutException;
import dpq2.connection : Connection, ConnectionException;
import dpq2.args : QueryParams;
import dpq2.value : Value, ValueFormat;
import dpq2.result : Answer, Result, Row, ResponseException;
import derelict.pq.pq : Oid, PGRES_COMMAND_OK, PGRES_TUPLES_OK,
    PGRES_PIPELINE_SYNC, PGpipelineStatus;

public import dpq2.args : QueryParams;
public import dpq2.value : Value, ValueFormat;
public import dpq2.result : Answer, Result, Row;

import core.stdc.errno : errno, EINTR;
import core.time : Duration, msecs, seconds;
import core.sys.posix.poll : POLLIN, POLLOUT, poll, pollfd;
import photon : Condition, Mutex, condition, mutex;
import photon.conduit_shim : resetRead, resetWrite;
import std.exception : enforce;
import std.string : indexOf;

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
    enum insertArticleWithTags = `WITH new_article AS (
    INSERT INTO articles (id, slug, author_id, title, description, body)
    SELECT n.id,
           trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
           $1, $2, $3, $4
      FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
    RETURNING id
), new_tags AS (
    INSERT INTO tags (name)
    SELECT DISTINCT unnest($5::text[])
    ON CONFLICT (name) DO NOTHING
)
SELECT na.id FROM new_article na`;
    enum updateArticle = `UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
 WHERE id = $1`;
    enum deleteArticle = `DELETE FROM articles WHERE id = $1`;
    enum insertFavorite = `INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING`;
    enum deleteFavorite = `DELETE FROM favorites WHERE user_id = $1 AND article_id = $2`;
    enum insertFavoriteBySlug = `WITH target AS (
    SELECT id FROM articles WHERE slug = $2 FOR SHARE
), ins AS (
    INSERT INTO favorites (user_id, article_id)
    SELECT $1, id FROM target
    ON CONFLICT DO NOTHING
)
SELECT id FROM target`;
    enum deleteFavoriteBySlug = `WITH target AS (
    SELECT id FROM articles WHERE slug = $2
), del AS (
    DELETE FROM favorites f USING target t
     WHERE f.user_id = $1 AND f.article_id = t.id
)
SELECT id FROM target`;

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
    enum commentsByArticleSlug = `SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
  FROM comments c
  JOIN users u ON u.id = c.author_id
  JOIN articles a ON a.id = c.article_id
 WHERE a.slug = $2
 ORDER BY c.created_at DESC, c.id DESC
 LIMIT 100`;
    enum insertCommentBySlug = `WITH a AS (SELECT id FROM articles WHERE slug = $1),
     c AS (INSERT INTO comments (article_id, author_id, body)
           SELECT a.id, $2, $3 FROM a
           RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM c JOIN users u ON u.id = c.author_id`;
    enum commentOwner = `SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2`;
    enum deleteComment = `DELETE FROM comments WHERE id = $1`;

    // -- tags --
    enum tagsAll = `SELECT string_agg(name, E'\x1f' ORDER BY name) AS tags,
       bool_or(position(E'\x1f' in name) > 0) AS has_sep
  FROM tags`;
    enum tagsAllRows = `SELECT name FROM tags ORDER BY name`;
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

/// A dpq2 SocketWaiter for photon.
///
/// The async dpq2 connection waits for the socket to become readable before
/// calling PQconsumeInput, so a query suspends only the current fiber instead
/// of the event loop thread.
final class PhotonSocketWaiter : SocketWaiter
{
    private int fd;

    this(int fd) nothrow
    {
        this.fd = fd;
    }

    override bool wait(SocketWaitMode mode, Duration timeout)
    {
        // libpq reads and writes this socket itself, so photon does not know
        // that the readiness it cached was consumed: drop it and re-arm.
        final switch (mode)
        {
        case SocketWaitMode.read:
            resetRead(fd);
            break;
        case SocketWaitMode.write:
            resetWrite(fd);
            break;
        case SocketWaitMode.readWrite:
            resetRead(fd);
            resetWrite(fd);
            break;
        }

        pollfd descriptor;
        descriptor.fd = fd;
        descriptor.events = cast(short)(
            (mode != SocketWaitMode.write ? POLLIN : 0) |
            (mode != SocketWaitMode.read ? POLLOUT : 0));

        int timeoutMs = -1;
        if (timeout != Duration.max)
        {
            const millis = timeout.total!"msecs";
            if (millis >= 0 && millis <= int.max)
                timeoutMs = cast(int) millis;
        }

        while (true)
        {
            const ready = poll(&descriptor, 1, timeoutMs);
            if (ready < 0)
            {
                if (errno == EINTR)
                    continue;
                return false;
            }
            return ready > 0;
        }
    }
}

/// An async dpq2 connection whose prepared statements survive a reset.
///
/// dpq2 re-creates its waiter after `reset()` (1.3.2), which matters here
/// because libpq may hand back a different socket descriptor.
///
/// The query methods are overridden because dpq2's generic runner calls
/// PQconsumeInput a second time after the result is already buffered. Photon's
/// recv hook turns the resulting EAGAIN into a fiber wait, so that redundant
/// call suspends the request forever. Waiting once, then reading the buffered
/// result, is both correct and enough for the single-statement queries here.
final class ConduitConnection : AsyncConnection
{
    private bool repairing;
    private PhotonSocketWaiter waiter;
    int slot;

    this(string connString, Duration pollingTimeout, Duration requestTimeout)
    {
        super(connString, (int socket) => new PhotonSocketWaiter(socket),
            pollingTimeout, requestTimeout);
        waiter = new PhotonSocketWaiter(posixSocket);
        initConnection(this);
    }

    /// Re-establishes the socket and prepares every statement again.
    override void reset()
    {
        if (repairing)
            return;
        repairing = true;
        scope (exit)
            repairing = false;

        super.reset();
        waiter = new PhotonSocketWaiter(posixSocket);
        initConnection(this);
    }

    override immutable(Answer) execParams(scope const ref QueryParams params)
    {
        sendQueryParams(params);
        return waitOne().getAnswer;
    }

    /// A dead connection is reset before the error reaches the request; the
    /// request itself still fails, but the pooled connection is usable again.
    override immutable(Answer) execPrepared(scope const ref QueryParams params)
    {
        try
        {
            sendQueryPrepared(params);
            return waitOne().getAnswer;
        }
        catch (ConnectionException e)
        {
            repair();
            throw e;
        }
    }

    override void prepareEx(string statementName, string sqlStatement,
        Oid[] oids = null)
    {
        sendPrepare(statementName, sqlStatement, oids);
        auto result = waitOne();
        if (result.status != PGRES_COMMAND_OK)
            throw new ResponseException(result, __FILE__, __LINE__);
    }

    /// Waits for the one result of a single statement, then for the
    /// ReadyForQuery terminator. `PQgetResult` must not be called while the
    /// connection is busy: it would block (or, with a zero timeout, fail) on
    /// the terminator instead of returning it.
    private immutable(Result) waitOne()
    {
        try
        {
            auto first = readFirstResult();
            while (true)
            {
                while (isBusy)
                {
                    if (!waiter.wait(SocketWaitMode.read, requestTimeout))
                        throw new PostgresClientTimeoutException(__FILE__, __LINE__);
                    consumeInput();
                }
                auto next = (cast(Connection) this).getResult();
                if (next is null)
                    break;
            }
            return first;
        }
        catch (PostgresClientTimeoutException e)
        {
            repair();
            throw e;
        }
    }

    /// Reads the one real result of a single statement. The null that follows
    /// it is the ReadyForQuery terminator, drained by `waitOne`.
    private immutable(Result) readFirstResult()
    {
        while (true)
        {
            while (isBusy)
            {
                if (!waiter.wait(SocketWaitMode.read, requestTimeout))
                    throw new PostgresClientTimeoutException(__FILE__, __LINE__);
                consumeInput();
            }
            auto next = (cast(Connection) this).getResult();
            if (next is null)
                throw new ConnectionException(this, __FILE__, __LINE__);
            return next;
        }
    }

    void repair() nothrow
    {
        try
            reset();
        catch (Exception)
        {
        }
    }
}

/// One connection pool per worker thread: a connection belongs to the thread
/// that opened it, so a pool must never be shared between threads.
///
/// A request never dials: the connections are opened and their statements
/// prepared once at startup, then reused for the life of the process.
final class Db
{
    private ConduitConnection[] connections;
    private int[] freeSlots;
    private shared Mutex lock;
    private shared Condition available;

    this(string connString, uint maxConns)
    {
        connString = withConnectTimeout(connString);
        lock = mutex();
        available = condition();
        connections.reserve(maxConns);
        freeSlots.reserve(maxConns);
        foreach (i; 0 .. maxConns)
        {
            auto conn = new ConduitConnection(connString, 5.seconds, 30.seconds);
            conn.slot = cast(int) connections.length;
            connections ~= conn;
            freeSlots ~= conn.slot;
        }
    }

    /// Borrows a connection for the calling fiber. Holding it across several
    /// calls keeps them on the same connection.
    ///
    /// photon's Channel is multi-producer/single-consumer, so it must not be
    /// used as a shared pool: two fibers would pop the same item. A fiber-aware
    /// mutex and condition variable give every waiter its own slot.
    ConduitConnection acquire()
    {
        lock.lock();
        while (freeSlots.length == 0)
        {
            if (!available.wait(lock, 5.seconds))
            {
                lock.unlock();
                throw new Exception("database pool exhausted");
            }
        }
        const slot = freeSlots[$ - 1];
        freeSlots.length -= 1;
        lock.unlock();
        return connections[cast(size_t) slot];
    }

    void release(ConduitConnection conn)
    {
        lock.lock();
        freeSlots ~= conn.slot;
        available.signal();
        lock.unlock();
    }
}

/// Appends a connect timeout without disturbing an existing one.
private string withConnectTimeout(string url)
{
    if (url.indexOf("connect_timeout=") >= 0)
        return url;
    return url ~ (url.indexOf('?') >= 0 ? "&" : "?") ~ "connect_timeout=5";
}

/// Runs once per new connection: force a UTC session, bound bad queries, and
/// prepare every statement in one pipeline.
private void prepareAll(ConduitConnection conn)
{
    auto statements = allStatements();
    conn.enterPipelineMode;
    bool syncSent;
    scope (exit) closePipeline(conn, syncSent);

    foreach (sql; [
        `SET TIME ZONE 'UTC'`,
        `SET plan_cache_mode = force_generic_plan`,
        `SET jit = off`,
        `SET statement_timeout = '10s'`,
        `SET lock_timeout = '5s'`,
    ])
    {
        QueryParams params;
        params.sqlCommand = sql;
        params.resultFormat = ValueFormat.TEXT;
        conn.sendQueryParams(params);
    }
    foreach (name, sql; statements)
        conn.sendPrepare(name, sql, null);

    conn.sendFlushRequest;
    conn.flush();
    conn.pipelineSync;
    syncSent = true;

    foreach (_; 0 .. 5 + statements.length)
    {
        auto result = awaitResult(conn);
        if (result.status != PGRES_COMMAND_OK)
            throw new Exception("connection setup failed");
    }
    if (awaitResult(conn).status != PGRES_PIPELINE_SYNC)
        throw new Exception("prepare pipeline sync failed");
}

private void initConnection(ConduitConnection conn)
{
    prepareAll(conn);
}

/// Runs a one-off statement and discards the result (SET, BEGIN, ...).
void execSimple(ConduitConnection conn, string sql)
{
    QueryParams params;
    params.sqlCommand = sql;
    params.resultFormat = ValueFormat.TEXT;
    try
        conn.execParams(params);
    catch (ConnectionException e)
    {
        conn.repair();
        throw e;
    }
}

/// Runs prepared statements as one libpq pipeline and returns their answers in
/// send order: a single flush carries all of them, so a page and its count
/// cost one round trip instead of two.
///
/// Only for statements whose parameters are all known up front. On any error
/// the pipeline is drained and left clean, and the error is thrown.
immutable(Answer)[] execPipeline(ConduitConnection conn,
    scope const(QueryParams)[] queries)
{
    conn.enterPipelineMode;
    bool syncSent;
    scope (exit)
        closePipeline(conn, syncSent);

    foreach (ref const query; queries)
        conn.sendQueryPrepared(query);
    conn.sendFlushRequest;
    conn.flush();
    conn.pipelineSync;
    syncSent = true;

    immutable(Answer)[] answers;
    foreach (_; queries)
        answers ~= awaitResult(conn).getAnswer;
    if (awaitResult(conn).status != PGRES_PIPELINE_SYNC)
        throw new Exception("pipeline sync failed");
    return answers;
}

/// Drains an aborted pipeline and leaves pipeline mode, even on the way out
/// of an exception.
private void closePipeline(ConduitConnection conn, bool syncSent) nothrow
{
    try
    {
        if (!syncSent)
            conn.pipelineSync();
        size_t drained;
        while (true)
        {
            auto result = conn.getResult(conn.requestTimeout);
            if (result is null)
                break;
            if (++drained > 4096)
            {
                conn.repair();
                return;
            }
        }
        conn.exitPipelineMode;
    }
    catch (Exception)
        conn.repair();
}

/// Reads one pipelined result, suspending the fiber until it arrives.
private immutable(Result) awaitResult(ConduitConnection conn)
{
    size_t attempts;
    while (true)
    {
        if (auto result = conn.getResult(conn.requestTimeout))
            return result;
        if (++attempts > 4096)
            throw new Exception("pipeline result missing");
    }
}
