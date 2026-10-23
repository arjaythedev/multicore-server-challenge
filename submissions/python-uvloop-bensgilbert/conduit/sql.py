_TS = "'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'"


def _ts(col: str) -> str:
    return f"to_char({col}, {_TS})"


def _profile(u: str, following: str) -> str:
    return f"json_build_object('username', {u}.username, 'bio', {u}.bio, 'image', {u}.image, 'following', {following})"


_FOLLOWING = "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = {a}.author_id)"


def _article(a: str, u: str, *, body: str | None = None, following: str | None = None,
             favorited: str | None = None, fav_count: str | None = None) -> str:
    """The json_build_object for one article. `a` is the alias with the article columns, `u` the author's row."""
    following = following or _FOLLOWING.format(a=a)
    favorited = favorited or f"EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = {a}.id AND f.user_id = $1)"
    fav_count = fav_count or f"(SELECT count(*) FROM favorites f WHERE f.article_id = {a}.id)"
    body_part = f"'body', {body}, " if body else ""
    return f"""json_build_object(
  'slug', {a}.slug, 'title', {a}.title, 'description', {a}.description, {body_part}
  'tagList', COALESCE((SELECT json_agg(n ORDER BY n)
                         FROM (SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS n
                                 FROM article_tags at WHERE at.article_id = {a}.id) x), '[]'::json),
  'createdAt', {_ts(a + '.created_at')}, 'updatedAt', {_ts(a + '.updated_at')},
  'favorited', {favorited}, 'favoritesCount', {fav_count},
  'author', {_profile(u, following)})"""


def _comment(c: str, u: str, following: str) -> str:
    return f"""json_build_object('id', {c}.id, 'createdAt', {_ts(c + '.created_at')}, 'updatedAt', {_ts(c + '.updated_at')},
  'body', {c}.body, 'author', {_profile(u, following)})"""


# lists
#
# The page size goes into the statement as a literal, so there is one prepared statement per distinct `limit` (clients
# only use a few). With `LIMIT $n` a generic plan has to guess that a page is 10% of the table, and then a hash join
# over a seq scan of `users` looks only ~1% dearer than the index probes a 10 row page really needs, although it is
# about 100x slower. With a literal the nested loop wins by a mile, whatever ANALYZE happened to sample.
# Parameters: $1 viewer, $2 offset, $3 name (tag, author, or the user who favorited).

_PAGE_COLS = "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id"


def _list(page: str, count: str, *, following: str | None = None, direct: bool = False) -> str:
    """A list endpoint: {"articles": [...], "articlesCount": n} as one json value.

    direct=True: `page` is a sub-select of the page's article columns (_PAGE_COLS), newest first.
    direct=False: `page` only gives the article ids (they come from another table), which are joined to `articles`.
    Either way the per-article sub-selects run for the rows of the page only, not for the rows OFFSET skips.
    """
    source = f"({page}) a" if direct else f"({page}) ids\nJOIN articles a ON a.id = ids.id"
    return f"""
SELECT json_build_object(
  'articles', COALESCE(json_agg({_article('a', 'u', following=following)} ORDER BY a.id DESC), '[]'::json),
  'articlesCount', ({count}))
FROM {source}
JOIN users u ON u.id = a.author_id"""


def _capped(rows: str) -> str:
    """min(1000, number of rows) for a sub-select that is usually longer than 1000. Skipping 999 rows with OFFSET is
    cheaper than counting 1000, so only a short result needs the exact count."""
    return f"""SELECT CASE WHEN EXISTS ({rows} OFFSET 999 LIMIT 1) THEN 1000 ELSE (SELECT count(*) FROM ({rows}) r) END"""


def _list_all(limit: int) -> str:
    return _list(
        f"SELECT {_PAGE_COLS} FROM articles a ORDER BY a.id DESC LIMIT {limit} OFFSET $2",
        _capped("SELECT 1 FROM articles ORDER BY id"),
        direct=True,
    )


def _list_tag(limit: int) -> str:
    return _list(
        f"""SELECT at.article_id AS id FROM article_tags at
            WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $3)
            ORDER BY at.article_id DESC LIMIT {limit} OFFSET $2""",
        _capped("SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $3)"),
    )


def _list_author(limit: int) -> str:
    return _list(
        f"""SELECT {_PAGE_COLS} FROM articles a
            WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $3)
            ORDER BY a.id DESC LIMIT {limit} OFFSET $2""",
        """SELECT count(*) FROM (SELECT 1 FROM articles a
            WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $3) LIMIT 1000) s""",
        direct=True,
    )


def _list_favorited(limit: int) -> str:
    return _list(
        f"""SELECT f.article_id AS id FROM favorites f
            WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $3)
            ORDER BY f.article_id DESC LIMIT {limit} OFFSET $2""",
        """SELECT count(*) FROM (SELECT 1 FROM favorites f
            WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $3) LIMIT 1000) s""",
    )


def _list_feed(limit: int) -> str:
    """Everyone in the feed is followed by $1, so author.following is true without looking it up."""
    return _list(
        f"""SELECT x.id FROM follows fo
            CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                                 ORDER BY a2.id DESC LIMIT ({limit} + $2::bigint)) x
            WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT {limit} OFFSET $2""",
        _capped("SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)"),
        following="true",
    )


MAX_LIMIT = 100


def _per_limit(build) -> tuple:
    """Statement text for every page size from 1 to 100, built once at import (index = limit). It's query text, not
    data."""
    return tuple(None if n == 0 else build(n) for n in range(MAX_LIMIT + 1))


LIST_ALL = _per_limit(_list_all)
LIST_TAG = _per_limit(_list_tag)
LIST_AUTHOR = _per_limit(_list_author)
LIST_FAVORITED = _per_limit(_list_favorited)
LIST_FEED = _per_limit(_list_feed)


# articles

_ART_ROW = f"""
SELECT json_build_object('article', {_article('a', 'u', body='a.body')})
FROM articles a JOIN users u ON u.id = a.author_id"""

# $1 viewer, $2 slug  -> no row = 404
ARTICLE_BY_SLUG = _ART_ROW + " WHERE a.slug = $2"
# $1 viewer, $2 article id
ARTICLE_BY_ID = _ART_ROW + " WHERE a.id = $2"

# $1 viewer, $2 slug: 404 if the article doesn't exist, else the newest 100 comments
COMMENTS = f"""
SELECT json_build_object('comments', COALESCE((
  SELECT json_agg({_comment('c', 'u', 'EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)')}
                  ORDER BY c.created_at DESC, c.id DESC)
    FROM (SELECT * FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
    JOIN users u ON u.id = c.author_id), '[]'::json))
FROM articles a WHERE a.slug = $2"""

# $1 viewer, $2 slug. After the write we know whether the viewer's row exists, but the statement can't see its own
# write, so favoritesCount is everyone else's rows plus or minus the viewer.
_FAV_ART = lambda favorited, delta: f"""
SELECT json_build_object('article', {_article('a', 'u', body='a.body', favorited=favorited,
    fav_count=f"((SELECT count(*) FROM favorites f WHERE f.article_id = a.id AND f.user_id <> $1) + {delta})")})
FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM target)"""

FAVORITE = ("""WITH target AS (SELECT id FROM articles WHERE slug = $2),
ins AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING)"""
            + _FAV_ART("true", 1))
UNFAVORITE = ("""WITH target AS (SELECT id FROM articles WHERE slug = $2),
del AS (DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM target))"""
              + _FAV_ART("false", 0))

# $1 viewer, $2 slug, $3 body -> no row = 404
ADD_COMMENT = f"""
WITH a AS (SELECT id FROM articles WHERE slug = $2),
c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM a
      RETURNING id, body, created_at, updated_at, author_id)
SELECT json_build_object('comment', {_comment('c', 'u', 'false')})
FROM c JOIN users u ON u.id = c.author_id"""

# $1 comment id, $2 slug, $3 viewer -> (author_id or NULL if there is no such comment, number of rows deleted)
DELETE_COMMENT = """
WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
            WHERE c.id = $1 AND a.slug = $2),
d AS (DELETE FROM comments WHERE id IN (SELECT id FROM c WHERE author_id = $3) RETURNING id)
SELECT (SELECT author_id FROM c), (SELECT count(*) FROM d)"""

# Article writes are rare (1.4% of page views), so they stay close to the reference: a few statements.
ARTICLE_OWNER = "SELECT id, author_id FROM articles WHERE slug = $1"
_SLUG = "trim(both '-' from lower(regexp_replace({t}, '[^A-Za-z0-9]+', '-', 'g')))"
INSERT_ARTICLE = f"""INSERT INTO articles (id, slug, author_id, title, description, body)
SELECT n.id, {_SLUG.format(t='$2')} || '-' || n.id, $1, $2, $3, $4
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
RETURNING id"""
# In name order, so two requests adding the same new tags at the same time can't deadlock each other.
INSERT_TAGS = "INSERT INTO tags (name) SELECT t FROM unnest($1::text[]) AS t GROUP BY t ORDER BY t ON CONFLICT (name) DO NOTHING"
INSERT_ARTICLE_TAGS = "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])"
UPDATE_ARTICLE = f"""UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE {_SLUG.format(t='$2')} || '-' || id END,
       updated_at = now()
 WHERE id = $1"""
DELETE_ARTICLE = "DELETE FROM articles WHERE id = $1"

# profiles

# $1 viewer, $2 username
GET_PROFILE = f"""
SELECT json_build_object('profile', {_profile('u', 'EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)')})
FROM users u WHERE u.username = $2"""

# $1 viewer, $2 username -> no row = 404
FOLLOW = f"""
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
ins AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING)
SELECT json_build_object('profile', {_profile('u', 'true')}) FROM u"""
UNFOLLOW = f"""
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
del AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))
SELECT json_build_object('profile', {_profile('u', 'false')}) FROM u"""

# users

INSERT_USER = """INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image"""
LOGIN_USER = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
GET_USER = "SELECT id, username, email, bio, image FROM users WHERE id = $1"
UPDATE_USER = """UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image"""

TAGS = "SELECT json_build_object('tags', COALESCE(json_agg(name ORDER BY name), '[]'::json)) FROM tags"
