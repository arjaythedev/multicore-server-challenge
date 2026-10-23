"""PostgreSQL adapter implementing all Conduit SQL from the challenge SPEC.

Single rows are shaped into plain dicts, list rows stay tuples (orders in ports.outbound); timestamps arrive
already formatted as API strings (`_TS`). Article lists and the feed also come as finished JSON response bodies,
built by Postgres (`list_json_stmt`).

Statements run on libpq directly (`conn.pgconn.exec_prepared`): every statement is prepared once per connection
at connect time, and rows come back in binary format, decoded by one reused psycopg C `Transformer` per connection. psycopg's own
`cursor.execute` costs ~45 µs of Python per statement (query parsing, generators, cursor setup); this path costs
a few µs and yields the same values.
"""

import re
import threading
import psycopg
from collections import deque
from contextlib import contextmanager
from psycopg import pq
from psycopg.adapt import Transformer
from typing import Optional, Tuple, List

from conduit_server.domain.services import slugify
from conduit_server.ports.outbound import ArticleRepositoryPort

_TUPLES_OK = pq.ExecStatus.TUPLES_OK
_COMMAND_OK = pq.ExecStatus.COMMAND_OK
_SQLSTATE = pq.DiagnosticField.SQLSTATE
_CONN_OK = pq.ConnStatus.OK
_PIPELINE_SYNC = pq.ExecStatus.PIPELINE_SYNC


class _Stmt:
    """One static statement: its server-side prepared name, `$n` SQL, and column names (fixed per statement)."""

    __slots__ = ("name", "sql", "cols")

    def __init__(self, sql: str):
        n = iter(range(1, 1000))
        self.name = b"c%d" % len(_STATEMENTS)
        self.sql = re.sub(r"%s", lambda _: f"${next(n)}", sql).encode()
        self.cols: Optional[List[str]] = None
        _STATEMENTS.append(self)


_STATEMENTS: List[_Stmt] = []

# Shared SQL fragments (spec section "SQL")
# Tag names by primary-key lookup (1-4 per article): a JOIN gets a generic plan that hash-joins all of `tags`.
TAG_LIST_ARRAY = """\
ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at
      WHERE at.article_id = a.id ORDER BY 1) AS tag_list\
"""
FAVORITES_COUNT = (
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count"
)
FAVORITED = (
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = %s) AS favorited"
)
# Timestamps leave Postgres as the API's strings: RFC 3339 UTC, milliseconds truncated (to_char's MS truncates).
# ~320 ns of Postgres per value, against ~750 ns of Python to decode and format a timestamptz.
_TS_EXPR = 'to_char({0} AT TIME ZONE \'UTC\', \'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"\')'
_TS = _TS_EXPR + " AS {1}"


def ts_cols(alias: str) -> str:
    return f"{_TS.format(alias + '.created_at', 'created_at')}, {_TS.format(alias + '.updated_at', 'updated_at')}"


FOLLOWING_AUTHOR = (
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %s AND fo.followee_id = a.author_id)"
    " AS following"
)


def article_cols(full: bool = False) -> str:
    body_col = "a.body, " if full else ""
    return (
        f"a.id, a.slug, a.title, a.description, {body_col}{ts_cols('a')}, "
        f"{TAG_LIST_ARRAY}, {FAVORITES_COUNT}, {FAVORITED}, u.username, u.bio, u.image, {FOLLOWING_AUTHOR}"
    )


def article_select(full: bool = False) -> str:
    return f"SELECT {article_cols(full)} FROM articles a JOIN users u ON u.id = a.author_id"


_PAGE_COLS = "a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id"


def list_stmt(count_rows: str, page: str) -> _Stmt:
    """A list page and its capped count in one statement: `c` (one row) LEFT JOINs the page, so an empty page still
    returns the count. Per-row subqueries run only on the rows left after LIMIT/OFFSET. `page` yields `a2` columns."""
    return _Stmt(
        f"WITH c AS (SELECT count(*) AS n FROM ({count_rows} LIMIT 1000) s)"
        f" SELECT c.n, {article_cols()} FROM c LEFT JOIN ({page}) a ON true"
        " LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
    )


def list_json_stmt(count_rows: str, page: str) -> _Stmt:
    """`list_stmt` with the response built by Postgres: one row, one json value, the whole
    {"articles": [...], "articlesCount": n} body (list entries without body, keys in the API's order).
    Same placeholders in the same order. json_build_object/json_agg cost Postgres ~1 µs per article and save the
    app ~3 µs (row decode, response objects, JSON encode): a 20-article page 540 → 563 µs of Postgres CPU,
    81 → 24 µs of app CPU, single-threaded."""
    article = (
        "json_build_object('slug', a.slug, 'title', a.title, 'description', a.description,"
        f" 'tagList', {TAG_LIST_ARRAY.removesuffix(' AS tag_list')},"
        f" 'createdAt', {_TS_EXPR.format('a.created_at')}, 'updatedAt', {_TS_EXPR.format('a.updated_at')},"
        f" 'favorited', {FAVORITED.removesuffix(' AS favorited')},"
        f" 'favoritesCount', {FAVORITES_COUNT.removesuffix(' AS favorites_count')},"
        " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
        f" 'following', {FOLLOWING_AUTHOR.removesuffix(' AS following')}))"
    )
    return _Stmt(
        f"WITH c AS (SELECT count(*) AS n FROM ({count_rows} LIMIT 1000) s)"
        f" SELECT json_build_object('articles', COALESCE((SELECT json_agg({article} ORDER BY a.id DESC)"
        f" FROM ({page}) a JOIN users u ON u.id = a.author_id), '[]'), 'articlesCount', c.n) FROM c"
    )


# Placeholders in text order: the count's, then viewer, viewer (FAVORITED, FOLLOWING_AUTHOR), then the page's.
# The counts walk indexes from the oldest end where pages are all-visible (index-only, no heap fetches).
# Each list as (count rows, page): prepared twice, as rows (list_stmt) and as a JSON body (list_json_stmt).
_TAG_ID = "(SELECT t.id FROM tags t WHERE t.name = %s)"
_NONE_SQL = (
    "SELECT 1 FROM articles ORDER BY id",
    f"SELECT {_PAGE_COLS} FROM articles a2 ORDER BY a2.id DESC LIMIT %s OFFSET %s",
)
_TAG_SQL = (
    f"SELECT 1 FROM article_tags at WHERE at.tag_id = {_TAG_ID} ORDER BY at.tag_id, at.article_id",
    f"SELECT {_PAGE_COLS} FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = {_TAG_ID}"
    " ORDER BY at.article_id DESC LIMIT %s OFFSET %s) p JOIN articles a2 ON a2.id = p.article_id",
)
_AUTHOR_SQL = (
    "SELECT 1 FROM articles a3 WHERE a3.author_id = (SELECT u.id FROM users u WHERE u.username = %s)",
    f"SELECT {_PAGE_COLS} FROM articles a2 WHERE a2.author_id ="
    " (SELECT au.id FROM users au WHERE au.username = %s) ORDER BY a2.id DESC LIMIT %s OFFSET %s",
)
_FAVORITED_SQL = (
    "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = %s)",
    f"SELECT {_PAGE_COLS} FROM (SELECT f.article_id FROM favorites f WHERE f.user_id ="
    " (SELECT fu.id FROM users fu WHERE fu.username = %s) ORDER BY f.article_id DESC LIMIT %s OFFSET %s) p"
    " JOIN articles a2 ON a2.id = p.article_id",
)
_FEED_SQL = (
    "SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo"
    " WHERE fo.follower_id = %s))",
    f"SELECT {_PAGE_COLS} FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL"
    " (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC"
    " LIMIT (%s::int + %s::int)) x WHERE fo.follower_id = %s ORDER BY x.id DESC LIMIT %s OFFSET %s) p"
    " JOIN articles a2 ON a2.id = p.id",
)
_LIST_NONE, _LIST_NONE_JSON = list_stmt(*_NONE_SQL), list_json_stmt(*_NONE_SQL)
_LIST_TAG, _LIST_TAG_JSON = list_stmt(*_TAG_SQL), list_json_stmt(*_TAG_SQL)
_LIST_AUTHOR, _LIST_AUTHOR_JSON = list_stmt(*_AUTHOR_SQL), list_json_stmt(*_AUTHOR_SQL)
_LIST_FAVORITED, _LIST_FAVORITED_JSON = list_stmt(*_FAVORITED_SQL), list_json_stmt(*_FAVORITED_SQL)
_LIST_FEED, _LIST_FEED_JSON = list_stmt(*_FEED_SQL), list_json_stmt(*_FEED_SQL)


_USER_COLS = "id, username, email, bio, image"
_COMMENT_COLS = (
    f"c.id, c.body, {ts_cols('c')}, u.username, u.bio, u.image,"
    " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %s AND fo.followee_id = c.author_id) AS following"
)

_REGISTER_USER = _Stmt(
    f"INSERT INTO users (username, email, password_hash) VALUES (%s, %s, %s) RETURNING {_USER_COLS}"
)
_USER_BY_EMAIL = _Stmt(
    "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = %s"
)
_USER_BY_ID = _Stmt(f"SELECT {_USER_COLS} FROM users WHERE id = %s")
_UPDATE_USER = _Stmt(
    "UPDATE users SET email = COALESCE(%s, email), username = COALESCE(%s, username),"
    " password_hash = COALESCE(%s, password_hash), bio = COALESCE(%s, bio),"
    " image = COALESCE(%s, image) WHERE id = %s"
    f" RETURNING {_USER_COLS}"
)
_PROFILE = _Stmt(
    "SELECT u.id, u.username, u.bio, u.image,"
    " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %s AND fo.followee_id = u.id)"
    " AS following FROM users u WHERE u.username = %s"
)
_FOLLOW = _Stmt(
    "INSERT INTO follows (follower_id, followee_id) VALUES (%s, %s) ON CONFLICT DO NOTHING"
)
_UNFOLLOW = _Stmt("DELETE FROM follows WHERE follower_id = %s AND followee_id = %s")
_TAGS = _Stmt("SELECT ARRAY(SELECT name FROM tags ORDER BY name)")  # one row, one array to decode
_ARTICLE_BY_SLUG = _Stmt(f"{article_select(full=True)} WHERE a.slug = %s")
_ARTICLE_BY_ID = _Stmt(f"{article_select(full=True)} WHERE a.id = %s")
_ARTICLE_FOR_WRITE = _Stmt("SELECT id, author_id FROM articles WHERE slug = %s")
_INSERT_ARTICLE = _Stmt(
    "INSERT INTO articles (id, slug, author_id, title, description, body)"
    " SELECT n.id, %s || '-' || n.id, %s, %s, %s, %s"
    " FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n"
    " RETURNING id"
)
_INSERT_TAGS = _Stmt(
    "INSERT INTO tags (name) SELECT DISTINCT unnest(%s::text[]) ON CONFLICT (name) DO NOTHING"
)
_INSERT_ARTICLE_TAGS = _Stmt(
    "INSERT INTO article_tags (article_id, tag_id)"
    " SELECT %s::int, t.id FROM tags t WHERE t.name = ANY(%s::text[])"
)
_UPDATE_ARTICLE = _Stmt(
    "UPDATE articles SET title = COALESCE(%s, title), description = COALESCE(%s, description),"
    " body = COALESCE(%s, body),"
    " slug = CASE WHEN %s::text IS NULL THEN slug ELSE %s || '-' || id END,"
    " updated_at = now() WHERE id = %s"
)
_DELETE_ARTICLE = _Stmt("DELETE FROM articles WHERE id = %s")
_FAVORITE = _Stmt(
    "INSERT INTO favorites (user_id, article_id) VALUES (%s, %s) ON CONFLICT DO NOTHING"
)
_UNFAVORITE = _Stmt("DELETE FROM favorites WHERE user_id = %s AND article_id = %s")
_COMMENTS = _Stmt(
    f"SELECT {_COMMENT_COLS} FROM comments c JOIN users u ON u.id = c.author_id"
    " WHERE c.article_id = %s ORDER BY c.created_at DESC, c.id DESC LIMIT 100"
)
# Article lookup and its comments in one statement: no row = no article; one all-NULL row = no comments.
_COMMENTS_BY_SLUG = _Stmt(
    f"SELECT {_COMMENT_COLS}"
    " FROM articles a LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id"
    " FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true"
    " LEFT JOIN users u ON u.id = c.author_id"
    " WHERE a.slug = %s ORDER BY c.created_at DESC, c.id DESC"
)
_CREATE_COMMENT = _Stmt(
    "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES (%s, %s, %s)"
    " RETURNING id, body, created_at, updated_at, author_id)"
    f" SELECT c.id, c.body, {ts_cols('c')}, u.username, u.bio, u.image"
    " FROM c JOIN users u ON u.id = c.author_id"
)
_COMMENT_FOR_WRITE = _Stmt(
    "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id"
    " WHERE c.id = %s AND a.slug = %s"
)
_DELETE_COMMENT = _Stmt("DELETE FROM comments WHERE id = %s")


class DuplicateError(Exception):
    pass


def configure_connection(conn: psycopg.Connection) -> None:
    """Pool hook, once per connection: autocommit (no BEGIN/COMMIT round-trips around reads; multi-statement
    writes use explicit transactions), no JIT for these short OLTP queries, timestamps already in UTC, then
    every statement above prepared server-side. Session-level only (rule 2).
    enable_seqscan = off: `tags` fits in two pages, so the planner scans all 200 rows for every tag-name lookup
    instead of using tags_pkey; every hot statement here is an index lookup anyway.
    plan_cache_mode = force_generic_plan: under `auto`, Postgres kept re-planning the list statements on every
    execution (their generic plan's estimate looks worse than a custom one, though the plans are the same shape),
    ~180 µs of planning each time. Forced: a 10-article list page 480 → 270 µs of Postgres CPU, ?tag 713 → 360."""
    conn.autocommit = True
    conn.execute("SET jit = off")
    conn.execute("SET enable_seqscan = off")
    conn.execute("SET plan_cache_mode = force_generic_plan")
    conn.execute("SET TimeZone = 'UTC'")
    pgconn = conn.pgconn
    for stmt in _STATEMENTS:
        res = pgconn.prepare(stmt.name, stmt.sql)
        if res.status != _COMMAND_OK:
            _raise(res)
    conn._conduit_tx = Transformer(conn)  # one row decoder per connection; it caches loaders by type oid


def _param(value) -> Optional[bytes]:
    """Text-format parameter. Lists become text[] literals (tags)."""
    if value is None:
        return None
    if value.__class__ is str:
        return value.encode()
    if value.__class__ is list:
        return (
            "{" + ",".join('"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"' for v in value) + "}"
        ).encode()
    return str(value).encode()


# Encoder by exact type for the common parameters (one dict lookup instead of a chain of checks); others use _param.
_ENCODE = {str: str.encode, int: lambda v: b"%d" % v, type(None): lambda v: None}


def _params(args) -> list:
    encode = _ENCODE.get
    return [encode(a.__class__, _param)(a) for a in args]


def _load(conn, stmt: _Stmt, res) -> list:
    """A TUPLES_OK result's rows as tuples, decoded by the connection's C Transformer."""
    if stmt.cols is None:
        stmt.cols = [res.fname(i).decode() for i in range(res.nfields)]
    tx = conn._conduit_tx
    tx.set_pgresult(res)
    return tx.load_rows(0, res.ntuples, tuple)


def _raise(res):
    sqlstate = res.error_field(_SQLSTATE)
    message = res.error_message.decode("utf-8", "replace")
    if sqlstate is None:
        raise psycopg.OperationalError(message)
    raise psycopg.errors.lookup(sqlstate.decode())(message)


class SingleConnection:
    """Pool stand-in for a single-threaded worker: one connection, same `.connection()` contract as
    psycopg_pool.ConnectionPool, minus its locks and background threads. Reconnects if the connection breaks.
    The thread that creates it (the worker's loop) owns `conn`; any other thread (the server's helper for
    offloaded bcrypt requests) gets its own connection, opened on first use."""

    def __init__(self, conninfo: str, configure=configure_connection):
        self.conninfo, self.configure = conninfo, configure
        self.owner = threading.get_ident()
        self.conn = self._connect()
        self._others = threading.local()

    def _connect(self) -> psycopg.Connection:
        conn = psycopg.connect(self.conninfo)
        self.configure(conn)
        return conn

    def get(self) -> psycopg.Connection:
        """The connection, reconnected first if it broke. No context manager: one thread owns it."""
        if threading.get_ident() != self.owner:
            return self._other()
        conn = self.conn
        # libpq calls bypass psycopg, so its `broken` flag never flips: ask libpq for the connection state
        if conn.closed or conn.pgconn.status != _CONN_OK:
            try:
                conn.close()
            except Exception:
                pass
            conn = self.conn = self._connect()
        return conn

    def _other(self) -> psycopg.Connection:
        conn = getattr(self._others, "conn", None)
        if conn is None or conn.closed or conn.pgconn.status != _CONN_OK:
            conn = self._others.conn = self._connect()
        return conn

    @contextmanager
    def connection(self):
        yield self.get()


class Query:
    """One read a handler can wait on without blocking its worker: `row = yield db.q_find_article(...)`.
    The server runs it on its `PgPipeline`; anywhere else `run()` executes it on the repository's connection.
    `finish` turns the statement's result (rows as tuples; for `json` statements the body's bytes) into what the
    repository method of the same name returns."""

    __slots__ = ("repo", "stmt", "args", "json", "finish")

    def __init__(self, repo, stmt: _Stmt, args: tuple, finish=None, json: bool = False):
        self.repo, self.stmt, self.args, self.json, self.finish = repo, stmt, args, json, finish

    def run(self):
        """Synchronously, on the repository's own connection."""
        if self.json:
            return self.repo._json(self.stmt, self.args)
        rows = self.repo._rows(self.stmt, self.args)
        return rows if self.finish is None else self.finish(rows)

    def result(self, conn, res):
        """The value from a result that came back on `conn` (pipeline); raises on an error result."""
        status = res.status
        if status != _TUPLES_OK:
            _raise(res)
        if self.json:
            return res.get_value(0, 0)
        rows = _load(conn, self.stmt, res)
        return rows if self.finish is None else self.finish(rows)


class PgPipeline:
    """One connection in libpq pipeline mode for a worker's epoll loop: queries go out without waiting for the ones
    before them, so a worker keeps serving while Postgres works, and statements in flight together share round
    trips (Postgres reads every statement waiting in its socket at once). Each query is followed by its own Sync,
    so each runs in its own implicit transaction, as in autocommit. Measured per statement, single-threaded:
    blocking 30 µs of Postgres CPU + 16.5 µs client; 2 in flight 14.3 + 8.1; 8 in flight 12.0 + 6.4.

    The server watches `fileno()` for reads, calls `submit` for each query, `flush()` once per loop pass (True:
    the socket is full, watch for writes too), and `ready()` when readable: (token, value, error) per finished
    query, in submission order."""

    def __init__(self, conninfo: str, configure=configure_connection):
        self.conninfo, self.configure = conninfo, configure
        self.inflight: deque = deque()  # (query, token), in submission order
        self.pending = None  # the head query's result, until its Sync arrives
        self.conn = self.pg = None
        self._connect()

    def _connect(self):
        conn = psycopg.connect(self.conninfo)
        self.configure(conn)
        pg = conn.pgconn
        pg.nonblocking = 1
        pg.enter_pipeline_mode()
        self.conn, self.pg = conn, pg

    def fileno(self) -> int:
        return self.pg.socket if self.pg is not None else -1

    def submit(self, query: Query, token) -> None:
        if self.pg is None:
            self._connect()  # broken earlier; raises if Postgres is still unreachable
        pg = self.pg
        pg.send_query_prepared(query.stmt.name, _params(query.args), None, 1)
        pg.pipeline_sync()
        self.inflight.append((query, token))

    def flush(self) -> bool:
        """Send what libpq has buffered; True if some is left (wait for the socket to be writable)."""
        if self.pg is None:
            return False
        try:
            return self.pg.flush() == 1
        except psycopg.OperationalError:
            return False  # the next ready() call sees the broken connection

    def ready(self) -> list:
        pg, inflight, out = self.pg, self.inflight, []
        if pg is None:
            return out
        try:
            pg.consume_input()
            while inflight and not pg.is_busy():
                res = pg.get_result()
                if res is None:
                    continue  # end of one query's results; its Sync comes next
                if res.status != _PIPELINE_SYNC:
                    self.pending = res
                    continue
                query, token = inflight.popleft()
                res, self.pending = self.pending, None
                try:
                    out.append((token, query.result(self.conn, res), None))
                except Exception as e:
                    out.append((token, None, e))
        except psycopg.OperationalError as e:
            out.extend(self._broken(e))
        if pg.status != _CONN_OK and self.pg is pg:
            out.extend(self._broken(psycopg.OperationalError("connection to Postgres lost")))
        return out

    def _broken(self, error) -> list:
        """Fail every query in flight; the next submit reconnects."""
        failed = [(token, None, error) for _, token in self.inflight]
        self.inflight.clear()
        self.pending = None
        try:
            self.conn.close()
        except Exception:
            pass
        self.conn = self.pg = None
        return failed


class PostgresUserRepository(ArticleRepositoryPort):
    def __init__(self, pool):
        self.pool = pool
        if isinstance(pool, SingleConnection):  # inline worker: skip the per-call context manager
            get = pool.get
            run = self._run
            self._rows = lambda stmt, args: run(get(), stmt, args)
            run_json = self._run_json
            self._json = lambda stmt, args: run_json(get(), stmt, args)

    # ---- helpers -----------------------------------------------------------
    @staticmethod
    def _run(conn, stmt: _Stmt, args) -> list:
        """Execute a prepared statement; rows as tuples ([] for commands without RETURNING)."""
        # Text parameters, binary results: binary loaders skip parsing (list page decode 12.9 → 9.6 µs, same values)
        res = conn.pgconn.exec_prepared(stmt.name, _params(args), None, 1)
        status = res.status
        if status == _TUPLES_OK:
            return _load(conn, stmt, res)
        if status != _COMMAND_OK:
            _raise(res)
        return []

    @staticmethod
    def _run_json(conn, stmt: _Stmt, args) -> bytes:
        """Execute a prepared statement whose one row is one json value; its bytes as they are (json's binary
        format is its text), no row decoding."""
        res = conn.pgconn.exec_prepared(stmt.name, _params(args), None, 1)
        if res.status != _TUPLES_OK:
            _raise(res)
        return res.get_value(0, 0)

    def _json(self, stmt: _Stmt, args) -> bytes:
        with self.pool.connection() as conn:
            return self._run_json(conn, stmt, args)

    def _rows(self, stmt: _Stmt, args) -> list:
        with self.pool.connection() as conn:
            return self._run(conn, stmt, args)

    def _one(self, stmt: _Stmt, *args) -> Optional[dict]:
        rows = self._rows(stmt, args)
        return dict(zip(stmt.cols, rows[0])) if rows else None

    _exec = _one

    # ---- users / auth ------------------------------------------------------
    def register_user(self, username: str, email: str, password_hash: str) -> Optional[dict]:
        try:
            return self._exec(_REGISTER_USER, username, email, password_hash)
        except psycopg.errors.UniqueViolation:
            raise DuplicateError("username or email already taken")

    def find_user_by_email(self, email: str) -> Optional[dict]:
        return self._one(_USER_BY_EMAIL, email)

    def find_user_by_id(self, user_id: int) -> Optional[dict]:
        return self.q_find_user_by_id(user_id).run()

    def q_find_user_by_id(self, user_id: int) -> Query:
        return Query(self, _USER_BY_ID, (user_id,), _first_dict(_USER_BY_ID))

    def update_user(self, user_id: int, fields: dict) -> Optional[dict]:
        try:
            return self._exec(
                _UPDATE_USER,
                fields.get("email"),
                fields.get("username"),
                fields.get("password_hash"),
                fields.get("bio"),
                fields.get("image"),
                user_id,
            )
        except psycopg.errors.UniqueViolation:
            raise DuplicateError("username or email already taken")

    # ---- profiles / follows ------------------------------------------------
    def find_profile(self, viewer: int, username: str) -> Optional[dict]:
        return self.q_find_profile(viewer, username).run()

    def q_find_profile(self, viewer: int, username: str) -> Query:
        return Query(self, _PROFILE, (viewer, username), _first_dict(_PROFILE))

    def follow(self, follower_id: int, followee_id: int) -> None:
        self._exec(_FOLLOW, follower_id, followee_id)

    def unfollow(self, follower_id: int, followee_id: int) -> None:
        self._exec(_UNFOLLOW, follower_id, followee_id)

    # ---- tags --------------------------------------------------------------
    def list_tags(self) -> List[str]:
        return self.q_list_tags().run()

    def q_list_tags(self) -> Query:
        return Query(self, _TAGS, (), _only_value)

    # ---- articles ----------------------------------------------------------
    def list_articles(
        self,
        viewer: int,
        limit: int,
        offset: int,
        filter_kind: str = "none",
        filter_value: str = "",
    ) -> Tuple[int, List[tuple]]:
        if filter_kind == "tag":
            stmt = _LIST_TAG
        elif filter_kind == "author":
            stmt = _LIST_AUTHOR
        elif filter_kind == "favorited":
            stmt = _LIST_FAVORITED
        else:  # none
            return self._list(_LIST_NONE, (viewer, viewer, limit, offset))
        return self._list(stmt, (filter_value, viewer, viewer, filter_value, limit, offset))

    def _list(self, stmt: _Stmt, args: tuple) -> Tuple[int, List[tuple]]:
        """One statement, one round-trip: column 0 is the capped count, the rest an article (all NULL if no page)."""
        rows = self._rows(stmt, args)
        total = rows[0][0]
        if rows[0][1] is None:
            return total, []
        return total, [r[1:] for r in rows]  # ARTICLE_ROW order

    def feed_articles(self, viewer: int, limit: int, offset: int) -> Tuple[int, List[tuple]]:
        return self._list(_LIST_FEED, (viewer, viewer, viewer, limit, offset, viewer, limit, offset))  # count, 2x viewer, page

    def list_articles_json(
        self, viewer: int, limit: int, offset: int, filter_kind: str = "none", filter_value: str = ""
    ) -> bytes:
        return self.q_list_articles_json(viewer, limit, offset, filter_kind, filter_value).run()

    def q_list_articles_json(
        self, viewer: int, limit: int, offset: int, filter_kind: str = "none", filter_value: str = ""
    ) -> Query:
        if filter_kind == "tag":
            stmt = _LIST_TAG_JSON
        elif filter_kind == "author":
            stmt = _LIST_AUTHOR_JSON
        elif filter_kind == "favorited":
            stmt = _LIST_FAVORITED_JSON
        else:  # none
            return Query(self, _LIST_NONE_JSON, (viewer, viewer, limit, offset), json=True)
        return Query(self, stmt, (filter_value, viewer, viewer, filter_value, limit, offset), json=True)

    def feed_articles_json(self, viewer: int, limit: int, offset: int) -> bytes:
        return self.q_feed_articles_json(viewer, limit, offset).run()

    def q_feed_articles_json(self, viewer: int, limit: int, offset: int) -> Query:
        args = (viewer, viewer, viewer, limit, offset, viewer, limit, offset)  # count, 2x viewer, page
        return Query(self, _LIST_FEED_JSON, args, json=True)

    def find_article(self, viewer: int, slug: str) -> Optional[dict]:
        return self.q_find_article(viewer, slug).run()

    def q_find_article(self, viewer: int, slug: str) -> Query:
        return Query(self, _ARTICLE_BY_SLUG, (viewer, viewer, slug), _first_dict(_ARTICLE_BY_SLUG))

    def find_article_by_id(self, viewer: int, article_id: int) -> Optional[dict]:
        return self._one(_ARTICLE_BY_ID, viewer, viewer, article_id)

    def article_for_write(self, slug: str) -> Optional[dict]:
        return self._one(_ARTICLE_FOR_WRITE, slug)

    def create_article(
        self, author_id: int, title: str, description: str, body: str, tags: List[str]
    ) -> Optional[int]:
        s = slugify(title)
        with self.pool.connection() as conn:
            pgconn = conn.pgconn
            pgconn.exec_(b"BEGIN")
            try:
                article_id = self._run(conn, _INSERT_ARTICLE, (s, author_id, title, description, body))[0][0]
                if tags:
                    self._run(conn, _INSERT_TAGS, (list(tags),))
                    self._run(conn, _INSERT_ARTICLE_TAGS, (article_id, list(tags)))
            except BaseException:
                pgconn.exec_(b"ROLLBACK")
                raise
            res = pgconn.exec_(b"COMMIT")
            if res.status != _COMMAND_OK:
                _raise(res)
        return article_id

    def update_article(self, article_id: int, fields: dict) -> None:
        new_title = fields.get("title")
        new_slug = slugify(new_title) if new_title is not None else None
        self._exec(
            _UPDATE_ARTICLE,
            new_title,
            fields.get("description"),
            fields.get("body"),
            new_slug,
            new_slug,
            article_id,
        )

    def delete_article(self, article_id: int) -> None:
        self._exec(_DELETE_ARTICLE, article_id)

    # ---- favorites ---------------------------------------------------------
    def favorite(self, viewer: int, article_id: int) -> None:
        self._exec(_FAVORITE, viewer, article_id)

    def unfavorite(self, viewer: int, article_id: int) -> None:
        self._exec(_UNFAVORITE, viewer, article_id)

    # ---- comments ----------------------------------------------------------
    def list_comments(self, viewer: int, article_id: int) -> List[tuple]:
        return self._rows(_COMMENTS, (viewer, article_id))  # COMMENT_ROW order

    def list_comments_by_slug(self, viewer: int, slug: str) -> Optional[List[tuple]]:
        return self.q_list_comments_by_slug(viewer, slug).run()

    def q_list_comments_by_slug(self, viewer: int, slug: str) -> Query:
        return Query(self, _COMMENTS_BY_SLUG, (viewer, slug), _comments_or_none)

    def create_comment(self, author_id: int, article_id: int, body: str) -> Optional[dict]:
        return self._one(_CREATE_COMMENT, article_id, author_id, body)

    def comment_for_write(self, slug: str, comment_id: int) -> Optional[dict]:
        return self._one(_COMMENT_FOR_WRITE, comment_id, slug)

    def delete_comment(self, comment_id: int) -> None:
        self._exec(_DELETE_COMMENT, comment_id)


# ---- `Query.finish` functions: statement rows -> repository return value ---------------------------------------
def _first_dict(stmt: _Stmt):
    def finish(rows):
        return dict(zip(stmt.cols, rows[0])) if rows else None

    return finish


def _only_value(rows):
    return rows[0][0]


def _comments_or_none(rows):
    """Article lookup and its comments in one statement: no row = no article; one all-NULL row = no comments."""
    if not rows:
        return None
    if rows[0][0] is None:
        return []
    return rows  # COMMENT_ROW order
