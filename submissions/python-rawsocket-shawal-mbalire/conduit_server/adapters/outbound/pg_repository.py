"""PostgreSQL adapter implementing all Conduit SQL from the challenge SPEC.

Every response except the user routes' is a finished JSON body built by Postgres (`json_build_object`), passed
through as bytes; timestamps are formatted in SQL (`_TS_EXPR`). The user routes' rows are shaped into plain dicts.
Writes are single statements (CTEs), so each one is atomic on its own in autocommit or behind one pipeline Sync.

Statements run on libpq directly (`conn.pgconn.exec_prepared`): every statement is prepared once per connection
at connect time, and rows come back in binary format, decoded by one reused psycopg C `Transformer` per connection. psycopg's own
`cursor.execute` costs ~45 µs of Python per statement (query parsing, generators, cursor setup); this path costs
a few µs and yields the same values.
"""

import os
import re
import threading
import psycopg
from collections import deque
from contextlib import contextmanager
from psycopg import pq
from psycopg.adapt import Transformer
from typing import Optional, List

from conduit_server.domain.errors import DuplicateError
from conduit_server.domain.services import slugify
from conduit_server.ports.outbound import ArticleRepositoryPort

_TUPLES_OK = pq.ExecStatus.TUPLES_OK
_COMMAND_OK = pq.ExecStatus.COMMAND_OK
_SQLSTATE = pq.DiagnosticField.SQLSTATE
_CONN_OK = pq.ConnStatus.OK
_PIPELINE_SYNC = pq.ExecStatus.PIPELINE_SYNC


class _Stmt:
    """One static statement: its server-side prepared name, `$n` SQL, and column names (fixed per statement)."""

    __slots__ = ("name", "sql", "cols", "index")

    def __init__(self, sql: str):
        self.index = len(_STATEMENTS)  # same in every process (module-level definitions): the broker's job key
        self.name = b"c%d" % self.index
        if "%s" in sql:
            n = iter(range(1, 1000))
            sql = re.sub(r"%s", lambda _: f"${next(n)}", sql)
        self.sql = sql.encode()
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
    "($1::bigint <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)) AS favorited"
)
# Timestamps leave Postgres as the API's strings: RFC 3339 UTC, milliseconds truncated (to_char's MS truncates).
# ~320 ns of Postgres per value, against ~750 ns of Python to decode and format a timestamptz.
_TS_EXPR = 'to_char({0} AT TIME ZONE \'UTC\', \'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"\')'


FOLLOWING_AUTHOR = (
    "($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id))"
    " AS following"
)


_PAGE_COLS = "a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id"
_LAT_FAV_JOIN = (
    " LEFT JOIN LATERAL (SELECT count(*) AS fc,"
    " ($1::bigint <> 0 AND COALESCE(bool_or(f.user_id = $1), false)) AS fav"
    " FROM favorites f WHERE f.article_id = a.id) fv ON true"
)


def list_json_stmt(
    count_sql: str,
    page: str,
    lateral_fav: bool = False,
    follow_true: bool = False,
) -> _Stmt:
    """A list page and its capped count in one statement, the response built by Postgres: one row, one json value,
    the whole {"articles": [...], "articlesCount": n} body (list entries without body, keys in the API's order).
    `c` (one row) holds the count, so an empty page still returns it; per-row subqueries run only on the rows left
    after LIMIT/OFFSET. `page` yields `a2` columns."""
    fav_count = "fv.fc" if lateral_fav else FAVORITES_COUNT.removesuffix(" AS favorites_count")
    fav_expr = "fv.fav" if lateral_fav else FAVORITED.removesuffix(" AS favorited")
    follow_expr = "true" if follow_true else FOLLOWING_AUTHOR.removesuffix(" AS following")
    lat = _LAT_FAV_JOIN if lateral_fav else ""
    article = (
        "json_build_object('slug', a.slug, 'title', a.title, 'description', a.description,"
        f" 'tagList', {TAG_LIST_ARRAY.removesuffix(' AS tag_list')},"
        f" 'createdAt', {_TS_EXPR.format('a.created_at')}, 'updatedAt', {_TS_EXPR.format('a.updated_at')},"
        f" 'favorited', {fav_expr},"
        f" 'favoritesCount', {fav_count},"
        " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
        f" 'following', {follow_expr}))"
    )
    return _Stmt(
        f"WITH c AS ({count_sql})"
        f" SELECT json_build_object('articles', COALESCE((SELECT json_agg({article} ORDER BY a.id DESC)"
        f" FROM ({page}) a JOIN users u ON u.id = a.author_id{lat}), '[]'), 'articlesCount', c.n) FROM c"
    )


# The counts walk indexes from the oldest end where pages are all-visible (index-only, no heap fetches).
# Global and tag lists have >1,000 rows in practice, so `EXISTS (... OFFSET 999 LIMIT 1)` skips counting when >= 1,000.
# Inner `LIMIT 100` gives `force_generic_plan` a tight upper bound (100 rows instead of 61,314).
_NONE_SQL = (
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999 LIMIT 1) THEN 1000"
    " ELSE (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) END AS n",
    f"SELECT * FROM (SELECT {_PAGE_COLS} FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3::int) b"
    " ORDER BY b.id DESC LIMIT $2::int",
    True,
    False,
)
_TAG_SQL = (
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2)"
    " ORDER BY at.tag_id, at.article_id OFFSET 999 LIMIT 1) THEN 1000"
    " ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2)"
    " ORDER BY at.tag_id, at.article_id LIMIT 1000) s) END AS n",
    f"SELECT {_PAGE_COLS} FROM (SELECT * FROM (SELECT at.article_id FROM article_tags at"
    " WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2)"
    " ORDER BY at.article_id DESC LIMIT 100 OFFSET $4::int) b ORDER BY b.article_id DESC LIMIT $3::int) p"
    " JOIN articles a2 ON a2.id = p.article_id",
    True,
    False,
)
_AUTHOR_SQL = (
    "SELECT count(*) AS n FROM (SELECT 1 FROM articles a3"
    " WHERE a3.author_id = (SELECT u.id FROM users u WHERE u.username = $2)"
    " ORDER BY a3.author_id DESC, a3.id ASC LIMIT 1000) s",
    f"SELECT * FROM (SELECT {_PAGE_COLS} FROM articles a2"
    " WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $2)"
    " ORDER BY a2.id DESC LIMIT 100 OFFSET $4::int) b ORDER BY b.id DESC LIMIT $3::int",
    False,
    False,
)
_FAVORITED_SQL = (
    "SELECT count(*) AS n FROM (SELECT 1 FROM favorites f"
    " WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $2)"
    " ORDER BY f.user_id, f.article_id LIMIT 1000) s",
    f"SELECT {_PAGE_COLS} FROM (SELECT * FROM (SELECT f.article_id FROM favorites f"
    " WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $2)"
    " ORDER BY f.article_id DESC LIMIT 100 OFFSET $4::int) b ORDER BY b.article_id DESC LIMIT $3::int) p"
    " JOIN articles a2 ON a2.id = p.article_id",
    False,
    False,
)
# The feed's count: one index scan over all the followees (`= ANY`, PostgreSQL 17+) instead of one per followee
# under a nested loop: the same rows, ~20% less time (each index entry passes through fewer executor nodes).
_FEED_COUNT = (
    "SELECT count(*) AS n FROM (SELECT 1 FROM articles a3"
    " WHERE a3.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = {viewer}))"
    " ORDER BY a3.author_id DESC, a3.id ASC LIMIT 1000) s"
)
_FEED_SQL = (
    _FEED_COUNT.format(viewer="$1"),
    f"SELECT {_PAGE_COLS} FROM (SELECT * FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL"
    " (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC"
    " LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT 100 OFFSET $3::int) b"
    " ORDER BY b.id DESC LIMIT $2::int) p JOIN articles a2 ON a2.id = p.id",
    False,
    True,
)
_LIST_NONE_JSON = list_json_stmt(*_NONE_SQL)
_LIST_TAG_JSON = list_json_stmt(*_TAG_SQL)
_LIST_AUTHOR_JSON = list_json_stmt(*_AUTHOR_SQL)
_LIST_FAVORITED_JSON = list_json_stmt(*_FAVORITED_SQL)
_LIST_FEED_JSON = list_json_stmt(*_FEED_SQL)


_USER_COLS = "id, username, email, bio, image"
_FULL_ARTICLE_JSON = (
    "json_build_object('article', json_build_object("
    "'slug', a.slug, 'title', a.title, 'description', a.description, 'body', a.body,"
    f" 'tagList', {TAG_LIST_ARRAY.removesuffix(' AS tag_list')},"
    f" 'createdAt', {_TS_EXPR.format('a.created_at')}, 'updatedAt', {_TS_EXPR.format('a.updated_at')},"
    f" 'favorited', {FAVORITED.removesuffix(' AS favorited')},"
    f" 'favoritesCount', {FAVORITES_COUNT.removesuffix(' AS favorites_count')},"
    " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
    f" 'following', {FOLLOWING_AUTHOR.removesuffix(' AS following')})))"
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
_PROFILE_JSON = _Stmt(
    "SELECT json_build_object('profile', json_build_object("
    "'username', u.username, 'bio', u.bio, 'image', u.image,"
    " 'following', ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id))))"
    " FROM users u WHERE u.username = $2"
)
_FOLLOW_JSON = _Stmt(
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),"
    " w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)"
    " SELECT json_build_object('profile', json_build_object("
    "'username', u.username, 'bio', u.bio, 'image', u.image, 'following', true)) FROM u"
)
_UNFOLLOW_JSON = _Stmt(
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),"
    " w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u))"
    " SELECT json_build_object('profile', json_build_object("
    "'username', u.username, 'bio', u.bio, 'image', u.image, 'following', false)) FROM u"
)
_TAGS_JSON = _Stmt("SELECT json_build_object('tags', COALESCE((SELECT json_agg(t.name ORDER BY t.name) FROM tags t), '[]'))")
_ARTICLE_BY_SLUG_JSON = _Stmt(
    f"SELECT {_FULL_ARTICLE_JSON} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"
)
_CREATE_ARTICLE_JSON = _Stmt(
    "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),"
    " ins_a AS (INSERT INTO articles (id, slug, author_id, title, description, body)"
    " SELECT n.id, $2 || '-' || n.id, $1, $3, $4, $5 FROM n"
    " RETURNING id, slug, title, description, body, created_at, updated_at, author_id),"
    " req_tags AS (SELECT DISTINCT unnest($6::text[]) AS name),"
    " ex_tags AS (SELECT t.id, t.name FROM tags t JOIN req_tags r ON t.name = r.name),"
    # Tags missing from this statement's snapshot. DO UPDATE (not DO NOTHING): if another request commits the same
    # new tag meanwhile, the snapshot can't see its row, but DO UPDATE returns it, so the article_tags row isn't lost.
    # Only tags absent from ex_tags get here, so existing tags are never rewritten.
    " new_tags AS (INSERT INTO tags (name)"
    " SELECT r.name FROM req_tags r WHERE NOT EXISTS (SELECT 1 FROM ex_tags e WHERE e.name = r.name)"
    " ORDER BY r.name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),"
    " all_tags AS (SELECT id, name FROM ex_tags UNION ALL SELECT id, name FROM new_tags),"
    " ins_at AS (INSERT INTO article_tags (article_id, tag_id)"
    " SELECT ins_a.id, at.id FROM ins_a CROSS JOIN all_tags at)"
    " SELECT json_build_object('article', json_build_object("
    "'slug', a.slug, 'title', a.title, 'description', a.description, 'body', a.body,"
    " 'tagList', COALESCE((SELECT json_agg(r.name ORDER BY r.name) FROM req_tags r), '[]'),"
    f" 'createdAt', {_TS_EXPR.format('a.created_at')}, 'updatedAt', {_TS_EXPR.format('a.updated_at')},"
    " 'favorited', false, 'favoritesCount', 0,"
    " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
    f" 'following', {FOLLOWING_AUTHOR.removesuffix(' AS following')})))"  # true if the author follows themselves
    " FROM ins_a a JOIN users u ON u.id = a.author_id"
)
_UPDATE_ARTICLE_BY_SLUG_JSON = _Stmt(
    "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2),"
    " u_art AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description),"
    " body = COALESCE($5, body),"
    " slug = CASE WHEN $6::text IS NULL THEN slug ELSE $6 || '-' || id END,"
    " updated_at = now() WHERE id = (SELECT id FROM t WHERE author_id = $1)"
    " RETURNING id, slug, title, description, body, created_at, updated_at, author_id)"
    " SELECT t.author_id, (SELECT json_build_object('article', json_build_object("
    "'slug', a.slug, 'title', a.title, 'description', a.description, 'body', a.body,"
    f" 'tagList', {TAG_LIST_ARRAY.removesuffix(' AS tag_list')},"
    f" 'createdAt', {_TS_EXPR.format('a.created_at')}, 'updatedAt', {_TS_EXPR.format('a.updated_at')},"
    f" 'favorited', {FAVORITED.removesuffix(' AS favorited')},"
    f" 'favoritesCount', {FAVORITES_COUNT.removesuffix(' AS favorites_count')},"
    " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
    f" 'following', {FOLLOWING_AUTHOR.removesuffix(' AS following')})))"
    " FROM u_art a JOIN users u ON u.id = a.author_id)::text FROM t"
)
_DELETE_ARTICLE_BY_SLUG = _Stmt(
    "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2),"
    " d AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $1))"
    " SELECT t.author_id FROM t"
)


# Favorite / unfavorite in ONE statement: CTE `w` does the write (RETURNING 1 per row inserted/deleted, empty when
# nothing changed) and the same statement returns the article's response body. Commands in one statement can't see
# one another's effects, so favorited and favoritesCount adjust by w's row count.
def _toggle_json_stmt(write: str, count_op: str, favorited_op: str) -> _Stmt:
    return _Stmt(
        f"WITH w AS ({write}"
        " RETURNING 1)"
        " SELECT json_build_object('article', json_build_object("
        "'slug', a.slug, 'title', a.title, 'description', a.description, 'body', a.body,"
        f" 'tagList', {TAG_LIST_ARRAY.removesuffix(' AS tag_list')},"
        f" 'createdAt', {_TS_EXPR.format('a.created_at')}, 'updatedAt', {_TS_EXPR.format('a.updated_at')},"
        f" 'favorited', ({FAVORITED.removesuffix(' AS favorited')} {favorited_op} EXISTS (SELECT 1 FROM w)),"
        f" 'favoritesCount', ({FAVORITES_COUNT.removesuffix(' AS favorites_count')} {count_op}"
        " (SELECT count(*) FROM w)),"
        " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
        f" 'following', {FOLLOWING_AUTHOR.removesuffix(' AS following')})))"
        " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"
    )


_FAVORITE_WRITE = (
    "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2"
    " ON CONFLICT DO NOTHING"
)
_UNFAVORITE_WRITE = (
    "DELETE FROM favorites WHERE user_id = $1"
    " AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)"
)
_FAVORITE_JSON = _toggle_json_stmt(_FAVORITE_WRITE, count_op="+", favorited_op="OR")
_UNFAVORITE_JSON = _toggle_json_stmt(_UNFAVORITE_WRITE, count_op="-", favorited_op="AND NOT")
_COMMENTS_BY_SLUG_JSON = _Stmt(
    "SELECT json_build_object('comments', COALESCE((SELECT json_agg(json_build_object("
    "'id', c.id,"
    f" 'createdAt', {_TS_EXPR.format('c.created_at')}, 'updatedAt', {_TS_EXPR.format('c.updated_at')},"
    " 'body', c.body,"
    " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
    " 'following', ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id))))"
    " ORDER BY c.created_at DESC, c.id DESC)"
    " FROM (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id"
    " FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c"
    " JOIN users u ON u.id = c.author_id), '[]')) FROM articles a WHERE a.slug = $2"
)
_CREATE_COMMENT_BY_SLUG_JSON = _Stmt(
    "WITH a AS (SELECT id FROM articles WHERE slug = $2),"
    " c AS (INSERT INTO comments (article_id, author_id, body)"
    " SELECT a.id, $1, $3 FROM a RETURNING id, body, created_at, updated_at, author_id)"
    " SELECT json_build_object('comment', json_build_object("
    "'id', c.id,"
    f" 'createdAt', {_TS_EXPR.format('c.created_at')}, 'updatedAt', {_TS_EXPR.format('c.updated_at')},"
    " 'body', c.body,"
    " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
    " 'following', ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = $1)))))"
    " FROM c JOIN users u ON u.id = c.author_id"
)
_DELETE_COMMENT_BY_SLUG = _Stmt(
    "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id"
    " WHERE c.id = $3 AND a.slug = $2),"
    " d AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $1))"
    " SELECT t.author_id FROM t"
)


# ---- Batched reads (pg_broker.py) ------------------------------------------------------------------------------
# One statement for a unit of N queued requests of one kind: parameters are arrays (one element per request), the
# work the requests share runs once (an article's tags, favorites count and author; the list's capped count), and
# the result is one row per request, (ord, body) in request order, body NULL where the single statement returns no
# row. Every body is the same bytes the single statement returns (scripts/batchcheck.py).
def _text_array(values) -> str:
    return "{" + ",".join('"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"' for v in values) + "}"


def _int_array(values) -> str:
    return "{" + ",".join(["%d" % v for v in values]) + "}"


# Per-article data shared by every request in the unit that shows the article: `w` columns. The units' keys come
# from CTEs, whose size a generic plan can't know (it merge-joined all of `articles`): each key is looked up through
# LATERAL with LIMIT 1 (the keys are unique), which keeps the planner from flattening it back into a join: an index
# probe per key.
_SHARED_ARTICLE_COLS = (
    "a.id, a.slug, a.title, a.description, a.author_id,"
    f" {TAG_LIST_ARRAY.removesuffix(' AS tag_list')} AS tl,"
    f" {_TS_EXPR.format('a.created_at')} AS ca, {_TS_EXPR.format('a.updated_at')} AS ua,"
    f" {FAVORITES_COUNT.removesuffix(' AS favorites_count')} AS fc,"
    " a.username, a.bio, a.image"
)
# The viewer's flags, per request (v.viewer) and article (w)
_V_FAVORITED = "(v.viewer <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = v.viewer AND f.article_id = w.id))"
_V_FOLLOWING = (
    "(v.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = v.viewer AND fo.followee_id = w.author_id))"
)


def _w_article_json(with_body: bool, following: str = _V_FOLLOWING) -> str:
    return (
        "json_build_object('slug', w.slug, 'title', w.title, 'description', w.description,"
        + (" 'body', w.body," if with_body else "")
        + " 'tagList', w.tl, 'createdAt', w.ca, 'updatedAt', w.ua,"
        f" 'favorited', {_V_FAVORITED}, 'favoritesCount', w.fc,"
        " 'author', json_build_object('username', w.username, 'bio', w.bio, 'image', w.image,"
        f" 'following', {following}))"
    )


def _pages_json(article_json: str) -> str:
    """CTE `j` (ord, a): each request's page as a json array, from `pg` (ord, id) and `w`, in one grouped join (a
    subquery per request scanned all of `w` each time). Pages that are empty have no row."""
    return (
        f", j AS (SELECT pg.ord, json_agg({article_json} ORDER BY w.id DESC) AS a"
        " FROM pg JOIN w ON w.id = pg.id JOIN v ON v.ord = pg.ord GROUP BY pg.ord)"
    )


# Global list: each request's page is `LIMIT least(lim, 100) OFFSET off` of articles by id (as _NONE_SQL); the
# article data is built once for the union of the pages, the count once for the unit. The union's DISTINCT reads
# from unnest(ARRAY(...)): over the CTE, the generic plan sized its hash table for thousands of rows (0.45 ms).
_LIST_NONE_BATCH = _Stmt(
    "WITH v AS (SELECT * FROM unnest($1::bigint[], $2::int[], $3::int[]) WITH ORDINALITY AS v(viewer, lim, off, ord)),"
    f" c AS ({_NONE_SQL[0]}),"
    " pg AS MATERIALIZED (SELECT v.ord, p.id FROM v CROSS JOIN LATERAL"
    " (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT least(v.lim, 100) OFFSET v.off) p),"
    f" w AS MATERIALIZED (SELECT {_SHARED_ARTICLE_COLS}"
    " FROM (SELECT DISTINCT id FROM unnest(ARRAY(SELECT id FROM pg)) id) d CROSS JOIN LATERAL (SELECT a.*, u.username, u.bio, u.image FROM articles a"
    " JOIN users u ON u.id = a.author_id WHERE a.id = d.id LIMIT 1) a)"
    f"{_pages_json(_w_article_json(False))}"
    " SELECT v.ord, json_build_object('articles', COALESCE(j.a, '[]'), 'articlesCount', c.n)"
    " FROM v CROSS JOIN c LEFT JOIN j ON j.ord = v.ord ORDER BY v.ord"
)
# Feed: each request's count and page are its own (as _FEED_SQL, viewer from v); the article data is built once
# for the union of the pages (popular authors' newest articles are on many feeds).
_LIST_FEED_BATCH = _Stmt(
    "WITH v AS (SELECT * FROM unnest($1::bigint[], $2::int[], $3::int[]) WITH ORDINALITY AS v(viewer, lim, off, ord)),"
    " pg AS MATERIALIZED (SELECT v.ord, p.id FROM v CROSS JOIN LATERAL"
    " (SELECT * FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL"
    " (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT (v.lim + v.off)) x"
    " WHERE fo.follower_id = v.viewer ORDER BY x.id DESC LIMIT 100 OFFSET v.off) b ORDER BY b.id DESC LIMIT v.lim) p),"
    f" w AS MATERIALIZED (SELECT {_SHARED_ARTICLE_COLS}"
    " FROM (SELECT DISTINCT id FROM unnest(ARRAY(SELECT id FROM pg)) id) d CROSS JOIN LATERAL (SELECT a.*, u.username, u.bio, u.image FROM articles a"
    " JOIN users u ON u.id = a.author_id WHERE a.id = d.id LIMIT 1) a)"
    f"{_pages_json(_w_article_json(False, 'true'))}"
    " SELECT v.ord, json_build_object('articles', COALESCE(j.a, '[]'), 'articlesCount',"
    f" ({_FEED_COUNT.format(viewer='v.viewer')}))"
    " FROM v LEFT JOIN j ON j.ord = v.ord ORDER BY v.ord"
)
def _keyed_list_batch(count_sql: str, page_sql: str) -> _Stmt:
    """A list filtered by a key ($2, the tag or username; $3 limit, $4 offset): the count once per distinct key in the
    unit, each request's page as the single statement's, the article data once for the union of the pages. Used for
    author, tag and favorited lists."""
    count = count_sql.replace("$2", "d.key")
    page = page_sql.replace("$2", "v.key").replace("$3::int", "v.lim").replace("$4::int", "v.off")
    return _Stmt(
        "WITH v AS (SELECT * FROM unnest($1::bigint[], $2::text[], $3::int[], $4::int[])"
        " WITH ORDINALITY AS v(viewer, key, lim, off, ord)),"
        f" c AS MATERIALIZED (SELECT d.key, ({count}) AS n FROM (SELECT DISTINCT key FROM unnest($2::text[]) key) d),"
        f" pg AS MATERIALIZED (SELECT v.ord, p.id FROM v CROSS JOIN LATERAL ({page}) p),"
        f" w AS MATERIALIZED (SELECT {_SHARED_ARTICLE_COLS}"
        " FROM (SELECT DISTINCT id FROM unnest(ARRAY(SELECT id FROM pg)) id) d CROSS JOIN LATERAL"
        " (SELECT a.*, u.username, u.bio, u.image FROM articles a"
        " JOIN users u ON u.id = a.author_id WHERE a.id = d.id LIMIT 1) a)"
        f"{_pages_json(_w_article_json(False))}"
        " SELECT v.ord, json_build_object('articles', COALESCE(j.a, '[]'), 'articlesCount', c.n)"
        " FROM v JOIN c ON c.key = v.key LEFT JOIN j ON j.ord = v.ord ORDER BY v.ord"
    )


_LIST_AUTHOR_BATCH = _keyed_list_batch(*_AUTHOR_SQL[:2])
_LIST_TAG_BATCH = _keyed_list_batch(*_TAG_SQL[:2])
_LIST_FAVORITED_BATCH = _keyed_list_batch(*_FAVORITED_SQL[:2])


_ARTICLE_BY_SLUG_BATCH = _Stmt(
    "WITH v AS (SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS v(viewer, slug, ord)),"
    f" w AS MATERIALIZED (SELECT {_SHARED_ARTICLE_COLS}, a.body"
    " FROM (SELECT DISTINCT slug FROM unnest($2::text[]) slug) s CROSS JOIN LATERAL"
    " (SELECT a.*, u.username, u.bio, u.image FROM articles a"
    " JOIN users u ON u.id = a.author_id WHERE a.slug = s.slug LIMIT 1) a)"
    f" SELECT v.ord, (SELECT json_build_object('article', {_w_article_json(True)}) FROM w WHERE w.slug = v.slug)"
    " FROM v ORDER BY v.ord"
)
# Comments share little (an article's comments are listed once per request anyway), and a CTE shared by the unit
# made every request scan all of its comments (163 µs a request under load, worse than single statements): each
# request runs the single statement's lookup through LATERAL, so the unit saves only per-statement overhead.
_COMMENTS_BY_SLUG_BATCH = _Stmt(
    "WITH v AS (SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS v(viewer, slug, ord))"
    " SELECT v.ord, (SELECT json_build_object('comments', COALESCE((SELECT json_agg(json_build_object("
    "'id', c.id,"
    f" 'createdAt', {_TS_EXPR.format('c.created_at')}, 'updatedAt', {_TS_EXPR.format('c.updated_at')},"
    " 'body', c.body,"
    " 'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,"
    " 'following', (v.viewer <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = v.viewer"
    " AND fo.followee_id = c.author_id))))"
    " ORDER BY c.created_at DESC, c.id DESC)"
    " FROM (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id"
    " FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c"
    " CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id LIMIT 1) u), '[]'))"
    " FROM articles a WHERE a.slug = v.slug)"
    " FROM v ORDER BY v.ord"
)


def _viewer_text_params(jobs_args) -> tuple:
    """(viewer, text) per request -> ($1 bigint[], $2 text[])."""
    return _int_array([a[0] for a in jobs_args]), _text_array([a[1] for a in jobs_args])


def _keyed_list_params(jobs_args) -> tuple:
    """(viewer, key, limit, offset) per request -> ($1 bigint[], $2 text[], $3 int[], $4 int[])."""
    return (
        _int_array([a[0] for a in jobs_args]),
        _text_array([a[1] for a in jobs_args]),
        _int_array([a[2] for a in jobs_args]),
        _int_array([a[3] for a in jobs_args]),
    )


def _list_none_params(jobs_args) -> tuple:
    return (
        _int_array([a[0] for a in jobs_args]),
        _int_array([a[1] for a in jobs_args]),
        _int_array([a[2] for a in jobs_args]),
    )


class Batched:
    """How the broker runs a unit of `single`'s requests: as `stmt`, with `params(list of args)`, from `min_size`."""

    __slots__ = ("stmt", "params", "min_size")

    def __init__(self, stmt: _Stmt, params, min_size: int):
        self.stmt, self.params, self.min_size = stmt, params, min_size


# single statement index -> Batched
BATCHED = {
    _LIST_NONE_JSON.index: Batched(_LIST_NONE_BATCH, _list_none_params, 4),
    _LIST_FEED_JSON.index: Batched(_LIST_FEED_BATCH, _list_none_params, 2),
    _LIST_AUTHOR_JSON.index: Batched(_LIST_AUTHOR_BATCH, _keyed_list_params, 2),
    _ARTICLE_BY_SLUG_JSON.index: Batched(_ARTICLE_BY_SLUG_BATCH, _viewer_text_params, 2),
    _COMMENTS_BY_SLUG_JSON.index: Batched(_COMMENTS_BY_SLUG_BATCH, _viewer_text_params, 4),
}
# Tag and favorited lists, batched since 2026-10-31: on fresh copies of the seed at 50,000 test users, Postgres 109
# against 114 µs/request (mean of 6 and 8 runs). On the drifted conduit_full they had measured slower than singles.
# BATCH_KEYED=0 runs them as singles (A/B).
if os.getenv("BATCH_KEYED", "1") != "0":
    BATCHED[_LIST_TAG_JSON.index] = Batched(_LIST_TAG_BATCH, _keyed_list_params, 2)
    BATCHED[_LIST_FAVORITED_JSON.index] = Batched(_LIST_FAVORITED_BATCH, _keyed_list_params, 2)
# Statements without parameters whose one result every request in the unit shares
SHARED = frozenset({_TAGS_JSON.index})


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
    conn.execute("SET enable_memoize = off")
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
    offloaded bcrypt requests) gets its own connection. Both open on first use: with the pipeline on, the loop
    thread never runs a query here, so its connection is never opened."""

    def __init__(self, conninfo: str, configure=configure_connection):
        self.conninfo, self.configure = conninfo, configure
        self.owner = threading.get_ident()
        self.conn = None
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
        if conn is None or conn.closed or conn.pgconn.status != _CONN_OK:
            if conn is not None:
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
    """One read or write a handler can wait on without blocking its worker: `row = yield db.q_find_article(...)`.
    The server runs it on its `PgPipeline`; anywhere else `run()` executes it on the repository's connection.
    `finish` turns the statement's result (rows as tuples; for `json` statements the body's bytes or None if 0 rows)
    into what the repository method of the same name returns."""

    __slots__ = ("repo", "stmt", "args", "json", "finish", "write")

    def __init__(self, repo, stmt: _Stmt, args: tuple, finish=None, json: bool = False, write: bool = False):
        self.repo, self.stmt, self.args, self.json, self.finish, self.write = repo, stmt, args, json, finish, write

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
            return res.get_value(0, 0) if res.ntuples else None
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
        self.pending = []  # the head query's results, until its Sync arrives
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

    def submit_unit(self, unit, token) -> None:
        """Several statements behind one Sync (pg_broker's group commit): `unit.send(pg)` sends them, and
        `unit.result(conn, results)` gets every result that came back before the Sync."""
        if self.pg is None:
            self._connect()
        unit.send(self.pg)
        self.pg.pipeline_sync()
        self.inflight.append((unit, token))

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
                    self.pending.append(res)
                    continue
                query, token = inflight.popleft()
                results, self.pending = self.pending, []
                try:
                    if getattr(query, "multi", False):
                        out.append((token, query.result(self.conn, results), None))
                    else:
                        out.append((token, query.result(self.conn, results[-1]), None))
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
        self.pending = []
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
    def _run_json(conn, stmt: _Stmt, args) -> Optional[bytes]:
        """Execute a prepared statement whose one row is one json value; its bytes as they are (json's binary
        format is its text), no row decoding. None if 0 rows."""
        res = conn.pgconn.exec_prepared(stmt.name, _params(args), None, 1)
        if res.status != _TUPLES_OK:
            _raise(res)
        return res.get_value(0, 0) if res.ntuples else None

    def _json(self, stmt: _Stmt, args) -> Optional[bytes]:
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

    def q_find_user_by_email(self, email: str) -> Query:
        return Query(self, _USER_BY_EMAIL, (email,), _first_dict(_USER_BY_EMAIL))

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

    # ---- profiles / follows ------------------------------------------------------
    def q_find_profile_json(self, viewer: int, username: str) -> Query:
        return Query(self, _PROFILE_JSON, (viewer, username), json=True)

    def q_follow_json(self, viewer: int, username: str) -> Query:
        return Query(self, _FOLLOW_JSON, (viewer, username), json=True, write=True)

    def q_unfollow_json(self, viewer: int, username: str) -> Query:
        return Query(self, _UNFOLLOW_JSON, (viewer, username), json=True, write=True)

    # ---- tags --------------------------------------------------------------------
    def q_list_tags_json(self) -> Query:
        return Query(self, _TAGS_JSON, (), json=True)

    # ---- articles ----------------------------------------------------------------
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
            return Query(self, _LIST_NONE_JSON, (viewer, limit, offset), json=True)
        return Query(self, stmt, (viewer, filter_value, limit, offset), json=True)

    def q_feed_articles_json(self, viewer: int, limit: int, offset: int) -> Query:
        return Query(self, _LIST_FEED_JSON, (viewer, limit, offset), json=True)

    def q_find_article_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _ARTICLE_BY_SLUG_JSON, (viewer, slug), json=True)

    def q_create_article_json(
        self, author_id: int, title: str, description: str, body: str, tags: List[str]
    ) -> Query:
        return Query(
            self,
            _CREATE_ARTICLE_JSON,
            (author_id, slugify(title), title, description, body, list(tags)),
            json=True,
            write=True,
        )

    def q_update_article_by_slug_json(
        self, viewer: int, slug: str, fields: dict
    ) -> Query:
        new_title = fields.get("title")
        new_slug = slugify(new_title) if new_title is not None else None
        return Query(
            self,
            _UPDATE_ARTICLE_BY_SLUG_JSON,
            (viewer, slug, new_title, fields.get("description"), fields.get("body"), new_slug),
            _author_and_json,
            write=True,
        )

    def q_delete_article_by_slug(self, viewer: int, slug: str) -> Query:
        return Query(self, _DELETE_ARTICLE_BY_SLUG, (viewer, slug), _first_val, write=True)

    # ---- favorites ---------------------------------------------------------------
    def q_favorite_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _FAVORITE_JSON, (viewer, slug), json=True, write=True)

    def q_unfavorite_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _UNFAVORITE_JSON, (viewer, slug), json=True, write=True)

    # ---- comments ----------------------------------------------------------------
    def q_list_comments_by_slug_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _COMMENTS_BY_SLUG_JSON, (viewer, slug), json=True)

    def q_create_comment_by_slug_json(self, author_id: int, slug: str, body: str) -> Query:
        return Query(self, _CREATE_COMMENT_BY_SLUG_JSON, (author_id, slug, body), json=True, write=True)

    def q_delete_comment_by_slug(self, viewer: int, slug: str, comment_id: int) -> Query:
        return Query(self, _DELETE_COMMENT_BY_SLUG, (viewer, slug, comment_id), _first_val, write=True)


# ---- `Query.finish` functions: statement rows -> repository return value ---------------------------------------
def _first_dict(stmt: _Stmt):
    def finish(rows):
        return dict(zip(stmt.cols, rows[0])) if rows else None

    return finish


def _first_val(rows):
    return rows[0][0] if rows else None


def _author_and_json(rows):
    if not rows:
        return None
    author_id, body = rows[0]
    return author_id, body.encode() if body is not None else None

