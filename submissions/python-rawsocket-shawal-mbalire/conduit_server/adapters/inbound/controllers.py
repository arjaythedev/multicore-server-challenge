from typing import Tuple

from conduit_server.adapters.inbound.errors import ApiError
from conduit_server.adapters.inbound.router import HttpRequest, router
from conduit_server.adapters.outbound.pg_repository import DuplicateError
from conduit_server.domain.models import UserData, UserResponse, Empty
from conduit_server.domain import services

# Controllers use the db and crypto ports injected from main.py.
# Every route but the three bcrypt ones is a generator: `body = yield db.q_...(...)` hands the query to the server,
# which runs it pipelined (the worker keeps serving meanwhile) and resumes the handler with its result. Those
# results are finished JSON bodies built by Postgres (the response shapes are in domain/models.py and checked by
# scripts/diffsql.py). The bcrypt routes run on the offload helper thread and call the db directly.


# Injected at startup by main.py (composition root).
db = None  # type: ArticleRepositoryPort — no caching; every call hits Postgres
crypto = None  # type: CryptoPort


_MAX_BIGINT = 2**63 - 1


def bootstrap(article_repository, crypto_adapter):
    global db, crypto
    db = article_repository
    crypto = crypto_adapter


# ---- shared helpers -------------------------------------------------------


def _viewer(request: HttpRequest, required: bool) -> int:
    """Auth optional: absent header => 0 (anonymous); present but invalid => 401."""
    header = request.headers.get("authorization")
    if header and not header.startswith("Token "):
        # RealWorld scheme is exactly "Token <jwt>"; anything else (Bearer, bare token) is 401.
        raise ApiError(401, "invalid authorization scheme")
    if not header:
        if required:
            raise ApiError(401, "Missing token")
        return 0
    token = header[len("Token ") :]
    try:
        return crypto.verify_token(token)
    except Exception:
        raise ApiError(401, "Invalid token")


def _token(request: HttpRequest) -> str:
    return request.headers.get("authorization", "").removeprefix("Token ")


def _paging(query: dict) -> Tuple[int, int]:
    try:
        return services.parse_limit_offset(query)
    except ValueError:
        raise ApiError(422, "limit or offset out of range")


def _user_data(row: dict, token: str) -> UserData:
    return UserData(
        email=row["email"],
        token=token,
        username=row["username"],
        bio=row["bio"],
        image=row["image"],
    )


# ---- users / auth --------------------------------------------------------


@router.post("/api/users", offload=True)  # bcrypt hash
def register(request: HttpRequest):
    body = request.json()
    try:
        services.require_strings(body, "user", "username", "email", "password")
    except ValueError:
        raise ApiError(422, "username, email and password are required")
    user = body["user"]

    try:
        row = db.register_user(
            user["username"], user["email"], crypto.hash_password(user["password"])
        )
    except DuplicateError:
        raise ApiError(422, "duplicate username or email")
    except ValueError:  # bcrypt: password over 72 bytes
        raise ApiError(422, "password too long")
    return 201, UserResponse(user=_user_data(row, crypto.issue_token(row["id"])))


# With the broker, logins yield their bcrypt to it, where other workers' logins share the hashing (6 lanes: 4.4x less
# CPU per hash); without it, this generator runs on the offload helper thread, each step in place.
@router.post("/api/users/login", offload=True, broker=True)  # bcrypt verify
def login(request: HttpRequest):
    body = request.json()
    try:
        services.require_strings(body, "user", "email", "password")
    except ValueError:
        raise ApiError(422, "email and password are required")
    user = body["user"]
    row = yield db.q_find_user_by_email(user["email"])
    if not row:
        raise ApiError(401, "invalid credentials")
    ok = yield crypto.q_verify_password(user["password"], row["password_hash"])
    if not ok:
        raise ApiError(401, "invalid credentials")
    return 200, UserResponse(user=_user_data(row, crypto.issue_token(row["id"])))


@router.get("/api/user")
def current_user(request: HttpRequest):
    viewer = _viewer(request, required=True)
    row = yield db.q_find_user_by_id(viewer)
    if not row:
        raise ApiError(401, "no such user")
    return 200, UserResponse(user=_user_data(row, _token(request)))


@router.put("/api/user", offload=True)  # bcrypt hash when the password changes
def update_user(request: HttpRequest):
    viewer = _viewer(request, required=True)
    payload = request.json_wrapped("user")
    # every provided field must be a string (empty string is allowed); absent/null unchanged
    for k in ("email", "username", "password", "bio", "image"):
        v = payload.get(k)
        if v is None:
            continue
        if not isinstance(v, str) or (k in ("email", "username") and v == ""):
            raise ApiError(422, f"invalid {k}")
    fields = {k: payload.get(k) for k in ("email", "username", "bio", "image") if k in payload}
    if payload.get("password"):
        try:
            fields["password_hash"] = crypto.hash_password(payload["password"])
        except ValueError:  # bcrypt: password over 72 bytes
            raise ApiError(422, "password too long")
    try:
        row = db.update_user(viewer, fields)
    except DuplicateError:
        raise ApiError(422, "duplicate username or email")
    if not row:
        raise ApiError(401, "no such user")
    return 200, UserResponse(user=_user_data(row, _token(request)))


# ---- profiles / follows --------------------------------------------------


@router.get("/api/profiles/:username")
def get_profile(request: HttpRequest):
    viewer = _viewer(request, required=False)
    body = yield db.q_find_profile_json(viewer, request.params["username"])
    if body is None:
        raise ApiError(404, "profile not found")
    return 200, body


@router.post("/api/profiles/:username/follow")
def follow(request: HttpRequest):
    viewer = _viewer(request, required=True)
    body = yield db.q_follow_json(viewer, request.params["username"])
    if body is None:
        raise ApiError(404, "profile not found")
    return 200, body


@router.delete("/api/profiles/:username/follow")
def unfollow(request: HttpRequest):
    viewer = _viewer(request, required=True)
    body = yield db.q_unfollow_json(viewer, request.params["username"])
    if body is None:
        raise ApiError(404, "profile not found")
    return 200, body


# ---- articles ------------------------------------------------------------


@router.get("/api/articles")
def list_articles(request: HttpRequest):
    viewer = _viewer(request, required=False)
    limit, offset = _paging(request.query)
    kind, value = "none", ""
    for k in ("tag", "author", "favorited"):  # first non-empty in this order applies
        if request.query.get(k, "") != "":
            kind, value = k, request.query[k]
            break
    body = yield db.q_list_articles_json(viewer, limit, offset, kind, value)  # built by Postgres
    return 200, body


@router.get("/api/articles/feed")
def feed(request: HttpRequest):
    viewer = _viewer(request, required=True)
    limit, offset = _paging(request.query)
    body = yield db.q_feed_articles_json(viewer, limit, offset)  # built by Postgres
    return 200, body


@router.get("/api/articles/:slug")
def get_article(request: HttpRequest):
    viewer = _viewer(request, required=False)
    body = yield db.q_find_article_json(viewer, request.params["slug"])
    if body is None:
        raise ApiError(404, "article not found")
    return 200, body


@router.post("/api/articles")
def create_article(request: HttpRequest):
    viewer = _viewer(request, required=True)
    payload = request.json_wrapped("article")
    try:
        tag_list = services.parse_tag_list(payload.get("tagList"))
    except ValueError:
        raise ApiError(422, "invalid tagList")
    if not all(
        services.is_non_empty_string(payload.get(f))
        for f in ("title", "description", "body")
    ):
        raise ApiError(422, "title, description and body are required")
    body = yield db.q_create_article_json(
        viewer, payload["title"], payload["description"], payload["body"], tag_list
    )
    if body is None:
        raise ApiError(404, "article not found")
    return 201, body


@router.put("/api/articles/:slug")
def update_article(request: HttpRequest):
    viewer = _viewer(request, required=True)
    payload = request.json_wrapped("article")
    for k in ("title", "description", "body"):
        v = payload.get(k)
        if v is not None and not services.is_non_empty_string(v):
            raise ApiError(422, f"invalid {k}")
    fields = {
        k: payload.get(k)
        for k in ("title", "description", "body")
        if payload.get(k) is not None
    }
    res = yield db.q_update_article_by_slug_json(viewer, request.params["slug"], fields)
    if res is None:
        raise ApiError(404, "article not found")
    author_id, body = res
    if author_id != viewer:
        raise ApiError(403, "not the author")
    return 200, body


@router.delete("/api/articles/:slug")
def delete_article(request: HttpRequest):
    viewer = _viewer(request, required=True)
    author_id = yield db.q_delete_article_by_slug(viewer, request.params["slug"])
    if author_id is None:
        raise ApiError(404, "article not found")
    if author_id != viewer:
        raise ApiError(403, "not the author")
    return 204, Empty()


# ---- favorites -----------------------------------------------------------
# Each toggle is one statement (favorite/unfavorite): CTE `w` does the write, the same statement
# returns the article JSON body. None = article not found (404).


@router.post("/api/articles/:slug/favorite")
def favorite(request: HttpRequest):
    viewer = _viewer(request, required=True)
    body = yield db.q_favorite_json(viewer, request.params["slug"])
    if body is None:
        raise ApiError(404, "article not found")
    return 200, body


@router.delete("/api/articles/:slug/favorite")
def unfavorite(request: HttpRequest):
    viewer = _viewer(request, required=True)
    body = yield db.q_unfavorite_json(viewer, request.params["slug"])
    if body is None:
        raise ApiError(404, "article not found")
    return 200, body


# ---- comments ------------------------------------------------------------


@router.get("/api/articles/:slug/comments")
def list_comments(request: HttpRequest):
    viewer = _viewer(request, required=False)
    body = yield db.q_list_comments_by_slug_json(viewer, request.params["slug"])
    if body is None:
        raise ApiError(404, "article not found")
    return 200, body


@router.post("/api/articles/:slug/comments")
def create_comment(request: HttpRequest):
    viewer = _viewer(request, required=True)
    comment = request.json_wrapped("comment")
    if not services.is_non_empty_string(comment.get("body")):
        raise ApiError(422, "comment body is required")
    body = yield db.q_create_comment_by_slug_json(viewer, request.params["slug"], comment["body"])
    if body is None:
        raise ApiError(404, "article not found")
    return 201, body


@router.delete("/api/articles/:slug/comments/:comment_id")
def delete_comment(request: HttpRequest):
    viewer = _viewer(request, required=True)
    raw_id = request.params["comment_id"]
    # ASCII digits only ("²".isdigit() is True, but int() rejects it), and within bigint: anything else can't be an id
    if not (raw_id.isascii() and raw_id.isdigit()) or int(raw_id) > _MAX_BIGINT:
        raise ApiError(404, "comment not found")
    author_id = yield db.q_delete_comment_by_slug(viewer, request.params["slug"], int(raw_id))
    if author_id is None:
        raise ApiError(404, "comment not found")
    if author_id != viewer:
        raise ApiError(403, "not the commenter")
    return 204, Empty()


# ---- tags ----------------------------------------------------------------


@router.get("/api/tags")
def tags(request: HttpRequest):
    return 200, (yield db.q_list_tags_json())
