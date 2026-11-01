"""DB_DRIVER=libpq-rows: the libpq driver with Postgres returning rows instead of JSON. Each `q_*_json` method runs
a row statement and builds the response in the app (domain/models.py dataclasses, encoded by the JSON codec), so
it returns the same body as the JSON statements in pg_repository.py (scripts/diffsql.py with REPO=rows). The point
is to measure what `json_build_object` costs Postgres against what building the body costs the app.

Same as the JSON statements: one statement per request (writes are the same CTEs), timestamps formatted by SQL
(`_TS_EXPR`), tags as text[]. These statements have no batched forms, so the broker runs them one by one.
"""

from conduit_server.adapters.outbound.pg_driver import LibpqDriver
from conduit_server.adapters.outbound import pg_repository as r
from conduit_server.adapters.outbound.pg_repository import (
    FAVORITED, FAVORITES_COUNT, FOLLOWING_AUTHOR, TAG_LIST_ARRAY, PostgresUserRepository, Query, SingleConnection,
    _Stmt, _TS_EXPR,
)
from conduit_server.domain.models import (
    ArticleData, ArticleListData, ArticlesResponse, CommentData, CommentsResponse, ProfileData, ProfileResponse,
    SingleArticleResponse, SingleCommentResponse, TagsResponse,
)
from conduit_server.domain.services import slugify

_FAV = FAVORITED.removesuffix(" AS favorited")
_FAV_COUNT = FAVORITES_COUNT.removesuffix(" AS favorites_count")
_FOLLOWING = FOLLOWING_AUTHOR.removesuffix(" AS following")
_TAGS = TAG_LIST_ARRAY.removesuffix(" AS tag_list")
_TS_A = f"{_TS_EXPR.format('a.created_at')}, {_TS_EXPR.format('a.updated_at')}"
_TS_C = f"{_TS_EXPR.format('c.created_at')}, {_TS_EXPR.format('c.updated_at')}"
_AUTHOR = "u.username, u.bio, u.image"
# slug, title, description, body, tag_list, created, updated, favorited, favorites_count, username, bio, image,
# following
_FULL_COLS = (f"a.slug, a.title, a.description, a.body, {_TAGS}, {_TS_A}, {_FAV}, {_FAV_COUNT}, {_AUTHOR},"
              f" {_FOLLOWING}")


def _list_stmt(count_sql: str, page: str, lateral_fav: bool = False, follow_true: bool = False) -> _Stmt:
    """Like pg_repository.list_json_stmt: the capped count in every row (one row of NULLs for an empty page), then
    the page's entries without body, newest first."""
    fav_count = "fv.fc" if lateral_fav else _FAV_COUNT
    fav = "fv.fav" if lateral_fav else _FAV
    follow = "true" if follow_true else _FOLLOWING
    lat = r._LAT_FAV_JOIN if lateral_fav else ""
    return _Stmt(
        f"WITH c AS ({count_sql}) SELECT c.n, p.* FROM c LEFT JOIN LATERAL ("
        f"SELECT a.id, a.slug, a.title, a.description, {_TAGS}, {_TS_A}, {fav}, {fav_count}, {_AUTHOR}, {follow}"
        f" FROM ({page}) a JOIN users u ON u.id = a.author_id{lat}) p ON true ORDER BY p.id DESC"
    )


_LIST_NONE = _list_stmt(*r._NONE_SQL)
_LIST_TAG = _list_stmt(*r._TAG_SQL)
_LIST_AUTHOR = _list_stmt(*r._AUTHOR_SQL)
_LIST_FAVORITED = _list_stmt(*r._FAVORITED_SQL)
_LIST_FEED = _list_stmt(*r._FEED_SQL)

_PROFILE = _Stmt(
    "SELECT u.username, u.bio, u.image,"
    " ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id))"
    " FROM users u WHERE u.username = $2"
)
_FOLLOW = _Stmt(
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),"
    " w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)"
    " SELECT u.username, u.bio, u.image, true FROM u"
)
_UNFOLLOW = _Stmt(
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),"
    " w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u))"
    " SELECT u.username, u.bio, u.image, false FROM u"
)
_TAG_NAMES = _Stmt("SELECT COALESCE((SELECT array_agg(t.name ORDER BY t.name) FROM tags t), '{}')")
_ARTICLE = _Stmt(f"SELECT {_FULL_COLS} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2")
_CREATE_ARTICLE = _Stmt(
    r._CREATE_ARTICLE_JSON.sql.decode().partition(" SELECT json_build_object(")[0]
    + " SELECT a.slug, a.title, a.description, a.body,"
    " COALESCE((SELECT array_agg(r.name ORDER BY r.name) FROM req_tags r), '{}'),"
    f" {_TS_A}, false, 0, {_AUTHOR}, {_FOLLOWING}"
    " FROM ins_a a JOIN users u ON u.id = a.author_id"
)
_UPDATE_ARTICLE = _Stmt(
    r._UPDATE_ARTICLE_BY_SLUG_JSON.sql.decode().partition(" SELECT t.author_id,")[0]
    + f" SELECT t.author_id, x.* FROM t LEFT JOIN LATERAL (SELECT {_FULL_COLS}"
    " FROM u_art a JOIN users u ON u.id = a.author_id) x ON true"
)


def _toggle_stmt(write: str, count_op: str, favorited_op: str) -> _Stmt:
    return _Stmt(
        f"WITH w AS ({write} RETURNING 1)"
        f" SELECT a.slug, a.title, a.description, a.body, {_TAGS}, {_TS_A},"
        f" ({_FAV} {favorited_op} EXISTS (SELECT 1 FROM w)), ({_FAV_COUNT} {count_op} (SELECT count(*) FROM w)),"
        f" {_AUTHOR}, {_FOLLOWING}"
        " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"
    )


_FAVORITE = _toggle_stmt(r._FAVORITE_WRITE, "+", "OR")
_UNFAVORITE = _toggle_stmt(r._UNFAVORITE_WRITE, "-", "AND NOT")
_COMMENTS = _Stmt(
    "SELECT a.id, x.* FROM articles a LEFT JOIN LATERAL ("
    # rn, not created_at, for the order: rows cross the broker socket (marshal), which carries no datetimes
    f"SELECT c.id AS cid, row_number() OVER (ORDER BY c.created_at DESC, c.id DESC) AS rn, {_TS_C}, c.body, {_AUTHOR},"
    " ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id))"
    " FROM (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id"
    " FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c"
    " JOIN users u ON u.id = c.author_id) x ON true WHERE a.slug = $2 ORDER BY x.rn"
)
_CREATE_COMMENT = _Stmt(
    "WITH a AS (SELECT id FROM articles WHERE slug = $2),"
    " c AS (INSERT INTO comments (article_id, author_id, body)"
    " SELECT a.id, $1, $3 FROM a RETURNING id, body, created_at, updated_at, author_id)"
    f" SELECT c.id, {_TS_C}, c.body, {_AUTHOR},"
    " ($1::bigint <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = $1))"
    " FROM c JOIN users u ON u.id = c.author_id"
)


# ---- rows -> response bodies (run in the worker, after the result arrives) -------------------------------------
def _full_article(row) -> ArticleData:
    return ArticleData(row[0], row[1], row[2], row[3], row[4], row[5], row[6], row[7], row[8],
                       ProfileData(row[9], row[10], row[11], row[12]))


class PostgresRowsRepository(PostgresUserRepository):
    """The JSON repository's interface (and its user, delete and bcrypt methods), with every response body built in
    the app from rows."""

    def __init__(self, pool, codec):
        super().__init__(pool)
        dumps = codec.dumps

        def profile(rows):
            if not rows:
                return None
            u = rows[0]
            return dumps(ProfileResponse(ProfileData(u[0], u[1], u[2], u[3])))

        def article(rows):
            return dumps(SingleArticleResponse(_full_article(rows[0]))) if rows else None

        def article_list(rows):
            return dumps(ArticlesResponse(
                [ArticleListData(x[2], x[3], x[4], x[5], x[6], x[7], x[8], x[9],
                                 ProfileData(x[10], x[11], x[12], x[13])) for x in rows if x[1] is not None],
                rows[0][0]))

        def tags(rows):
            return dumps(TagsResponse(rows[0][0]))

        def update(rows):
            if not rows:
                return None
            x = rows[0]
            return x[0], (dumps(SingleArticleResponse(_full_article(x[1:]))) if x[1] is not None else None)

        def comments(rows):
            if not rows:
                return None
            return dumps(CommentsResponse([
                CommentData(x[1], x[3], x[4], x[5], ProfileData(x[6], x[7], x[8], x[9]))
                for x in rows if x[1] is not None]))

        def comment(rows):
            if not rows:
                return None
            x = rows[0]
            return dumps(SingleCommentResponse(CommentData(x[0], x[1], x[2], x[3], ProfileData(x[4], x[5], x[6], x[7]))))

        self._profile, self._article, self._list, self._tags = profile, article, article_list, tags
        self._update, self._comments, self._comment = update, comments, comment

    def q_find_profile_json(self, viewer: int, username: str) -> Query:
        return Query(self, _PROFILE, (viewer, username), self._profile)

    def q_follow_json(self, viewer: int, username: str) -> Query:
        return Query(self, _FOLLOW, (viewer, username), self._profile, write=True)

    def q_unfollow_json(self, viewer: int, username: str) -> Query:
        return Query(self, _UNFOLLOW, (viewer, username), self._profile, write=True)

    def q_list_tags_json(self) -> Query:
        return Query(self, _TAG_NAMES, (), self._tags)

    def q_list_articles_json(self, viewer: int, limit: int, offset: int, filter_kind: str = "none",
                             filter_value: str = "") -> Query:
        if filter_kind == "none":
            return Query(self, _LIST_NONE, (viewer, limit, offset), self._list)
        stmt = {"tag": _LIST_TAG, "author": _LIST_AUTHOR, "favorited": _LIST_FAVORITED}[filter_kind]
        return Query(self, stmt, (viewer, filter_value, limit, offset), self._list)

    def q_feed_articles_json(self, viewer: int, limit: int, offset: int) -> Query:
        return Query(self, _LIST_FEED, (viewer, limit, offset), self._list)

    def q_find_article_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _ARTICLE, (viewer, slug), self._article)

    def q_create_article_json(self, author_id: int, title: str, description: str, body: str, tags) -> Query:
        return Query(self, _CREATE_ARTICLE, (author_id, slugify(title), title, description, body, list(tags)),
                     self._article, write=True)

    def q_update_article_by_slug_json(self, viewer: int, slug: str, fields: dict) -> Query:
        new_title = fields.get("title")
        new_slug = slugify(new_title) if new_title is not None else None
        return Query(self, _UPDATE_ARTICLE,
                     (viewer, slug, new_title, fields.get("description"), fields.get("body"), new_slug),
                     self._update, write=True)

    def q_favorite_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _FAVORITE, (viewer, slug), self._article, write=True)

    def q_unfavorite_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _UNFAVORITE, (viewer, slug), self._article, write=True)

    def q_list_comments_by_slug_json(self, viewer: int, slug: str) -> Query:
        return Query(self, _COMMENTS, (viewer, slug), self._comments)

    def q_create_comment_by_slug_json(self, author_id: int, slug: str, body: str) -> Query:
        return Query(self, _CREATE_COMMENT, (author_id, slug, body), self._comment, write=True)


class LibpqRowsDriver(LibpqDriver):
    def repository(self, threads: int, pool_size: int, codec=None):
        return PostgresRowsRepository(super().repository(threads, pool_size).pool, codec)
