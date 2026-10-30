from typing import Protocol, Any, Optional, Sequence


class CryptoPort(Protocol):
    """Outbound port for hashing, token signing and token verification."""

    def hash_password(self, password: str) -> str: ...

    def verify_password(self, password: str, password_hash: str) -> bool: ...

    def q_verify_password(self, password: str, password_hash: str) -> "QueryPort":
        """`verify_password` as a job a handler waits on (`ok = yield ...`), so logins can be hashed together."""

    def issue_token(self, user_id: int) -> str: ...

    def verify_token(self, token: str) -> int:
        """Return the user id, or raise on invalid/expired/mismatched alg."""


class QueryPort(Protocol):
    """A query a handler waits on with `value = yield query`: the server runs it without blocking its worker (or
    `run()` executes it in place). For a `*_json` query the value is the finished JSON response body as bytes (UTF-8),
    or None when the statement found no row (the handler's 404)."""

    def run(self) -> Any: ...


class ArticleRepositoryPort(Protocol):
    """Outbound port for all Conduit SQL. Concrete adapter: libpq through psycopg.
    The bcrypt routes call the plain methods synchronously (they run on the offload helper thread). Everything else
    is a `q_*` method returning a QueryPort for generator handlers; `*_json` ones yield a response body built by
    Postgres, in the shapes of domain/models.py. Writes are one statement each, so each is atomic on its own."""

    def register_user(self, username: str, email: str, password_hash: str) -> dict:
        """The new user's row; raises DuplicateError on a taken username or email."""
    def find_user_by_email(self, email: str) -> Optional[dict]:
        """The user's row with `password_hash`, or None."""
    def update_user(self, user_id: int, fields: dict) -> Optional[dict]:
        """Fields absent from `fields` are unchanged. None if no such user; raises DuplicateError like register_user."""
    def q_find_user_by_id(self, user_id: int) -> QueryPort:
        """The user's row (dict), or None."""
    def q_find_profile_json(self, viewer: int, username: str) -> QueryPort: ...
    def q_follow_json(self, viewer: int, username: str) -> QueryPort: ...
    def q_unfollow_json(self, viewer: int, username: str) -> QueryPort: ...
    def q_list_tags_json(self) -> QueryPort: ...
    def q_list_articles_json(
        self,
        viewer: int,
        limit: int,
        offset: int,
        filter_kind: str = "none",
        filter_value: str = "",
    ) -> QueryPort:
        """{"articles": [...], "articlesCount": n}; filter_kind is none, tag, author or favorited."""
    def q_feed_articles_json(self, viewer: int, limit: int, offset: int) -> QueryPort: ...
    def q_find_article_json(self, viewer: int, slug: str) -> QueryPort: ...
    def q_create_article_json(
        self, author_id: int, title: str, description: str, body: str, tags: Sequence[str]
    ) -> QueryPort: ...
    def q_update_article_by_slug_json(self, viewer: int, slug: str, fields: dict) -> QueryPort:
        """(author_id, body): body is None, and nothing is updated, when the viewer isn't the author (the handler's
        403). None when there is no such article."""
    def q_delete_article_by_slug(self, viewer: int, slug: str) -> QueryPort:
        """The article's author_id (deleted only if it is the viewer), or None."""
    def q_favorite_json(self, viewer: int, slug: str) -> QueryPort: ...
    def q_unfavorite_json(self, viewer: int, slug: str) -> QueryPort: ...
    def q_list_comments_by_slug_json(self, viewer: int, slug: str) -> QueryPort: ...
    def q_create_comment_by_slug_json(self, author_id: int, slug: str, body: str) -> QueryPort: ...
    def q_delete_comment_by_slug(self, viewer: int, slug: str, comment_id: int) -> QueryPort:
        """The comment's author_id (deleted only if it is the viewer), or None."""
