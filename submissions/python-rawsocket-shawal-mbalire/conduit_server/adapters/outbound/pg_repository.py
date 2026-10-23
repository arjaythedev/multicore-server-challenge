"""PostgreSQL adapter implementing all Conduit SQL from the challenge SPEC.

Rows are shaped into plain dicts; timestamps stay as datetimes (formatted by controllers).
"""

import psycopg
from typing import Optional, Tuple, List

from conduit_server.domain.services import slugify
from conduit_server.ports.outbound import ArticleRepositoryPort

# Shared SQL fragments (spec section "SQL")
TAG_LIST_ARRAY = """\
ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
      WHERE at.article_id = a.id ORDER BY t.name) AS tag_list\
"""
FAVORITES_COUNT = (
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count"
)
FAVORITED = (
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = %s) AS favorited"
)
FOLLOWING_AUTHOR = (
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %s AND fo.followee_id = a.author_id)"
    " AS following"
)


def article_select(full: bool = False) -> str:
    body_col = "a.body, " if full else ""
    return (
        f"SELECT a.id, a.slug, a.title, a.description, {body_col}a.created_at, a.updated_at, "
        f"{TAG_LIST_ARRAY}, {FAVORITES_COUNT}, {FAVORITED}, u.username, u.bio, u.image, {FOLLOWING_AUTHOR}"
        " FROM articles a JOIN users u ON u.id = a.author_id"
    )


ORDER_PAGE = "ORDER BY a.id DESC LIMIT %s OFFSET %s"

_USER_COLS = "id, username, email, bio, image"


class DuplicateError(Exception):
    pass


class PostgresUserRepository(ArticleRepositoryPort):
    def __init__(self, pool):
        self.pool = pool

    # ---- helpers -----------------------------------------------------------
    def _one(self, sql: str, *args):
        with self.pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(sql, args)
                return self._maybe_row(cur)

    @staticmethod
    def _maybe_row(cur):
        row = cur.fetchone()
        if row is None:
            return None
        cols = [d.name for d in cur.description]
        return dict(zip(cols, row))

    def _exec(self, sql: str, *args):
        with self.pool.connection() as conn:
            with conn.cursor() as cur:
                cur.execute(sql, args)
                try:
                    return self._maybe_row(cur)
                except psycopg.ProgrammingError:
                    return None  # INSERT/DELETE without RETURNING

    # ---- users / auth ------------------------------------------------------
    def register_user(self, username: str, email: str, password_hash: str) -> Optional[dict]:
        try:
            return self._exec(
                f"INSERT INTO users (username, email, password_hash) VALUES (%s, %s, %s) "
                f"RETURNING {_USER_COLS}",
                username,
                email,
                password_hash,
            )
        except psycopg.errors.UniqueViolation:
            raise DuplicateError("username or email already taken")

    def find_user_by_email(self, email: str) -> Optional[dict]:
        return self._one(
            "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = %s",
            email,
        )

    def find_user_by_id(self, user_id: int) -> Optional[dict]:
        return self._one(f"SELECT {_USER_COLS} FROM users WHERE id = %s", user_id)

    def update_user(self, user_id: int, fields: dict) -> Optional[dict]:
        try:
            return self._exec(
                "UPDATE users SET email = COALESCE(%s, email), username = COALESCE(%s, username),"
                " password_hash = COALESCE(%s, password_hash), bio = COALESCE(%s, bio),"
                " image = COALESCE(%s, image) WHERE id = %s"
                f" RETURNING {_USER_COLS}",
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
        return self._one(
            "SELECT u.id, u.username, u.bio, u.image,"
            " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %s AND fo.followee_id = u.id)"
            " AS following FROM users u WHERE u.username = %s",
            viewer,
            username,
        )

    def follow(self, follower_id: int, followee_id: int) -> None:
        self._exec(
            "INSERT INTO follows (follower_id, followee_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
            follower_id,
            followee_id,
        )

    def unfollow(self, follower_id: int, followee_id: int) -> None:
        self._exec(
            "DELETE FROM follows WHERE follower_id = %s AND followee_id = %s",
            follower_id,
            followee_id,
        )

    # ---- tags --------------------------------------------------------------
    def list_tags(self) -> List[str]:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT name FROM tags ORDER BY name")
            return [r[0] for r in cur.fetchall()]

    # ---- articles ----------------------------------------------------------
    def list_articles(
        self,
        viewer: int,
        limit: int,
        offset: int,
        filter_kind: str = "none",
        filter_value: str = "",
    ) -> Tuple[int, List[dict]]:
        base = article_select(full=False)
        kind = filter_kind
        if kind == "tag":
            page = (
                f"{base} WHERE a.id IN (SELECT at.article_id FROM article_tags at"
                " WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = %s)"
                " ORDER BY at.article_id DESC LIMIT %s OFFSET %s) ORDER BY a.id DESC"
            )
            count = (
                "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id ="
                " (SELECT t.id FROM tags t WHERE t.name = %s) LIMIT 1000) s"
            )
            page_args = (viewer, viewer, filter_value, limit, offset)
            count_args = (filter_value,)
        elif kind == "author":
            page = (
                f"{base} WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = %s)"
                f" {ORDER_PAGE}"
            )
            count = (
                "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id ="
                " (SELECT u.id FROM users u WHERE u.username = %s) LIMIT 1000) s"
            )
            page_args = (viewer, viewer, filter_value, limit, offset)
            count_args = (filter_value,)
        elif kind == "favorited":
            page = (
                f"{base} WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id ="
                " (SELECT fu.id FROM users fu WHERE fu.username = %s)"
                " ORDER BY f.article_id DESC LIMIT %s OFFSET %s) ORDER BY a.id DESC"
            )
            count = (
                "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id ="
                " (SELECT fu.id FROM users fu WHERE fu.username = %s) LIMIT 1000) s"
            )
            page_args = (viewer, viewer, filter_value, limit, offset)
            count_args = (filter_value,)
        else:  # none
            page = f"{base} {ORDER_PAGE}"
            count = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"
            page_args = (viewer, viewer, limit, offset)
            count_args = ()

        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(page, page_args)
            rows = self._rows(cur)
            cur.execute(count, count_args)
            total = cur.fetchone()[0]
        return total, rows

    def feed_articles(self, viewer: int, limit: int, offset: int) -> Tuple[int, List[dict]]:
        base = article_select(full=False)
        page = (
            f"{base} WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL"
            " (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id"
            " ORDER BY a.id DESC LIMIT (%s::int + %s::int)) x"
            " WHERE fo.follower_id = %s ORDER BY x.id DESC LIMIT %s OFFSET %s) ORDER BY a.id DESC"
        )
        count = (
            "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN"
            " (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = %s) LIMIT 1000) s"
        )
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(page, (viewer, viewer, limit, limit, viewer, limit, offset))
            rows = self._rows(cur)
            cur.execute(count, (viewer,))
            total = cur.fetchone()[0]
        return total, rows

    @staticmethod
    def _rows(cur):
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]

    def find_article(self, viewer: int, slug: str) -> Optional[dict]:
        return self._one(f"{article_select(full=True)} WHERE a.slug = %s", viewer, viewer, slug)

    def find_article_by_id(self, viewer: int, article_id: int) -> Optional[dict]:
        return self._one(f"{article_select(full=True)} WHERE a.id = %s", viewer, viewer, article_id)

    def article_for_write(self, slug: str) -> Optional[dict]:
        return self._one("SELECT id, author_id FROM articles WHERE slug = %s", slug)

    def create_article(
        self, author_id: int, title: str, description: str, body: str, tags: List[str]
    ) -> Optional[int]:
        s = slugify(title)
        with self.pool.connection() as conn:
            with conn.transaction():
                with conn.cursor() as cur:
                    cur.execute(
                        "INSERT INTO articles (id, slug, author_id, title, description, body)"
                        " SELECT n.id, %s || '-' || n.id, %s, %s, %s, %s"
                        " FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n"
                        " RETURNING id",
                        (s, author_id, title, description, body),
                    )
                    article_id = cur.fetchone()[0]
                    if tags:
                        cur.execute(
                            "INSERT INTO tags (name) SELECT DISTINCT unnest(%s::text[])"
                            " ON CONFLICT (name) DO NOTHING",
                            (list(tags),),
                        )
                        cur.execute(
                            "INSERT INTO article_tags (article_id, tag_id)"
                            " SELECT %s, t.id FROM tags t WHERE t.name = ANY(%s::text[])",
                            (article_id, list(tags)),
                        )
        return article_id

    def update_article(self, article_id: int, fields: dict) -> None:
        new_title = fields.get("title")
        new_slug = slugify(new_title) if new_title is not None else None
        self._exec(
            "UPDATE articles SET title = COALESCE(%s, title), description = COALESCE(%s, description),"
            " body = COALESCE(%s, body),"
            " slug = CASE WHEN %s::text IS NULL THEN slug ELSE %s || '-' || id END,"
            " updated_at = now() WHERE id = %s",
            new_title,
            fields.get("description"),
            fields.get("body"),
            new_slug,
            new_slug,
            article_id,
        )

    def delete_article(self, article_id: int) -> None:
        self._exec("DELETE FROM articles WHERE id = %s", article_id)

    # ---- favorites ---------------------------------------------------------
    def favorite(self, viewer: int, article_id: int) -> None:
        self._exec(
            "INSERT INTO favorites (user_id, article_id) VALUES (%s, %s) ON CONFLICT DO NOTHING",
            viewer,
            article_id,
        )

    def unfavorite(self, viewer: int, article_id: int) -> None:
        self._exec(
            "DELETE FROM favorites WHERE user_id = %s AND article_id = %s", viewer, article_id
        )

    # ---- comments ----------------------------------------------------------
    def list_comments(self, viewer: int, article_id: int) -> List[dict]:
        with self.pool.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,"
                " EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = %s"
                " AND fo.followee_id = c.author_id) AS following"
                " FROM comments c JOIN users u ON u.id = c.author_id"
                " WHERE c.article_id = %s ORDER BY c.created_at DESC, c.id DESC LIMIT 100",
                (viewer, article_id),
            )
            rows = cur.fetchall()
        cols = ["id", "body", "created_at", "updated_at", "username", "bio", "image", "following"]
        return [dict(zip(cols, r)) for r in rows]

    def create_comment(self, author_id: int, article_id: int, body: str) -> Optional[dict]:
        return self._one(
            "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES (%s, %s, %s)"
            " RETURNING id, body, created_at, updated_at, author_id)"
            " SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image"
            " FROM c JOIN users u ON u.id = c.author_id",
            article_id,
            author_id,
            body,
        )

    def comment_for_write(self, slug: str, comment_id: int) -> Optional[dict]:
        return self._one(
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id"
            " WHERE c.id = %s AND a.slug = %s",
            comment_id,
            slug,
        )

    def delete_comment(self, comment_id: int) -> None:
        self._exec("DELETE FROM comments WHERE id = %s", comment_id)
