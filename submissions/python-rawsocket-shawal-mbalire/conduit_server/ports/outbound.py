from typing import Protocol, Any, Optional, Sequence


class JsonCodecPort(Protocol):
    """JSON for request and response bodies. `dumps` must serialize the frozen dataclasses of domain/models.py
    (by field, in declaration order) and return UTF-8 bytes; `loads` takes bytes and raises ValueError (or
    UnicodeDecodeError) on invalid input."""

    def dumps(self, value: Any) -> bytes: ...

    def loads(self, data: bytes) -> Any: ...


class PasswordHasherPort(Protocol):
    """Outbound port for password hashing (bcrypt cost 10, rule 7)."""

    def hash_password(self, password: str) -> str:
        """Raises ValueError for a password the hash can't take (bcrypt: over 72 bytes)."""

    def verify_password(self, password: str, password_hash: str) -> bool: ...

    def q_verify_password(self, password: str, password_hash: str) -> "QueryPort":
        """`verify_password` as a job a handler waits on (`ok = yield ...`), so logins can be hashed together."""


class TokenPort(Protocol):
    """Outbound port for signing and verifying auth tokens (HS256 JWT, checked on every request)."""

    def issue_token(self, user_id: int) -> str: ...

    def verify_token(self, token: str) -> int:
        """Return the user id, or raise on invalid/expired/mismatched alg."""


class QueryPort(Protocol):
    """A query a handler waits on with `value = yield query`: the server runs it without blocking its worker (or
    `run()` executes it in place). For a `*_json` query the value is the finished JSON response body as bytes (UTF-8),
    or None when the statement found no row (the handler's 404)."""

    def run(self) -> Any: ...


class ArticleRepositoryPort(Protocol):
    """Outbound port for all Conduit SQL. Adapters: see DB_DRIVER in registry.py.
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


class QueryPipelinePort(Protocol):
    """Runs the QueryPorts that handlers yield without blocking the worker: its socket sits in the transport's
    epoll. `submit` queues a query with a token, `flush` sends what is queued (True while bytes remain unsent: watch
    for EPOLLOUT), and `ready` (on EPOLLIN) returns [(token, value, error), ...] for the queries that finished."""

    inflight: Any  # sized: queries submitted and not yet answered (the transport balances on it)

    def fileno(self) -> int: ...

    def submit(self, query: QueryPort, token: Any) -> None: ...

    def flush(self) -> bool: ...

    def ready(self) -> list: ...


class DatabaseDriverPort(Protocol):
    """What the composition root needs from a database adapter: the repository, the pipelines its queries run on,
    and how many server connections that costs (max_connections = 100, the spec allows 95)."""

    def repository(self, threads: int, pool_size: int, codec: JsonCodecPort) -> ArticleRepositoryPort:
        """threads=0: one lazily opened connection for synchronous calls; else a pool of pool_size. `codec`: for
        adapters that build response bodies in the app."""

    def pipelines(self, readers: int) -> Sequence[QueryPipelinePort]:
        """`readers` read pipelines, then one write pipeline (the last)."""

    def connections_per_worker(self, threads: int, pool_size: int, readers: int) -> int: ...
