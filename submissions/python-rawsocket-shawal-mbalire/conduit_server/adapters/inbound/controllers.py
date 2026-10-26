from typing import Tuple, List, Optional

from conduit_server.adapters.inbound.errors import ApiError
from conduit_server.adapters.inbound.router import HttpRequest, router
from conduit_server.adapters.outbound.pg_repository import DuplicateError
from conduit_server.domain.models import (
    ProfileData,
    ProfileResponse,
    UserData,
    UserResponse,
    ArticleData,
    SingleArticleResponse,
    ArticlesResponse,
    SingleCommentResponse,
    CommentsResponse,
    TagsResponse,
    Empty,
)
from conduit_server.domain import services

# Controllers use the db and crypto ports injected from main.py.
# The hot reads are generators: `row = yield db.q_...(...)` hands the query to the server, which runs it pipelined
# (the worker keeps serving meanwhile) and resumes the handler with its result; writes call the db directly.


# Injected at startup by main.py (composition root).
db = None  # type: ArticleRepositoryPort — no caching; every call hits Postgres
crypto = None  # type: CryptoPort


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


def _profile(row: dict) -> ProfileData:
    return ProfileData(
        username=row["username"], bio=row["bio"], image=row["image"], following=row["following"]
    )


def _article(row: dict, include_body: bool) -> ArticleData:
    if include_body:
        body = row["body"]
    else:
        body = None
    return ArticleData(
        slug=row["slug"],
        title=row["title"],
        description=row["description"],
        body=body,
        tagList=row["tag_list"],
        createdAt=row["created_at"],
        updatedAt=row["updated_at"],
        favorited=row["favorited"],
        favoritesCount=row["favorites_count"],
        author=ProfileData(
            username=row["username"],
            bio=row["bio"],
            image=row["image"],
            following=row["following"],
        ),
    )


def _user_data(row: dict, token: str) -> UserData:
    return UserData(
        email=row["email"],
        token=token,
        username=row["username"],
        bio=row["bio"],
        image=row["image"],
    )


def _articles_response(rows: List[tuple], total: int) -> dict:
    """The list response from rows. The routes get it built by Postgres (`list_articles_json`); scripts/diffsql.py
    checks that body against this one. Rows in ARTICLE_ROW order (ports.outbound). List entries omit 'body'
    entirely (RealWorld spec), unlike single-article responses: same keys and order as ArticleData minus body."""
    return {
        "articles": [
            {
                "slug": slug,
                "title": title,
                "description": description,
                "tagList": tag_list,
                "createdAt": created_at,
                "updatedAt": updated_at,
                "favorited": favorited,
                "favoritesCount": favorites_count,
                "author": ProfileData(username=username, bio=bio, image=image, following=following),
            }
            for (_id, slug, title, description, created_at, updated_at, tag_list, favorites_count,
                 favorited, username, bio, image, following) in rows
        ],
        "articlesCount": total,
    }


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


@router.post("/api/users/login", offload=True)  # bcrypt verify
def login(request: HttpRequest):
    body = request.json()
    try:
        services.require_strings(body, "user", "email", "password")
    except ValueError:
        raise ApiError(422, "email and password are required")
    user = body["user"]
    row = db.find_user_by_email(user["email"])
    if not row or not crypto.verify_password(user["password"], row["password_hash"]):
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
    row = yield db.q_find_profile(viewer, request.params["username"])
    if not row:
        raise ApiError(404, "profile not found")
    return 200, ProfileResponse(profile=_profile(row))


@router.post("/api/profiles/:username/follow")
def follow(request: HttpRequest):
    viewer = _viewer(request, required=True)
    row = db.find_profile(viewer, request.params["username"])
    if not row:
        raise ApiError(404, "profile not found")
    db.follow(viewer, row["id"])
    row["following"] = True
    return 200, ProfileResponse(profile=_profile(row))


@router.delete("/api/profiles/:username/follow")
def unfollow(request: HttpRequest):
    viewer = _viewer(request, required=True)
    row = db.find_profile(viewer, request.params["username"])
    if not row:
        raise ApiError(404, "profile not found")
    db.unfollow(viewer, row["id"])
    row["following"] = False
    return 200, ProfileResponse(profile=_profile(row))


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
    row = yield db.q_find_article(viewer, request.params["slug"])
    if not row:
        raise ApiError(404, "article not found")
    return 200, SingleArticleResponse(article=_article(row, include_body=True))


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
    art_id = db.create_article(
        viewer, payload["title"], payload["description"], payload["body"], tag_list
    )
    row = db.find_article_by_id(viewer, art_id)
    if not row:
        raise ApiError(404, "article not found")
    return 201, SingleArticleResponse(article=_article(row, include_body=True))


@router.put("/api/articles/:slug")
def update_article(request: HttpRequest):
    viewer = _viewer(request, required=True)
    art = db.article_for_write(request.params["slug"])
    if not art:
        raise ApiError(404, "article not found")
    if art["author_id"] != viewer:
        raise ApiError(403, "not the author")
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
    db.update_article(art["id"], fields)
    row = db.find_article_by_id(viewer, art["id"])
    return 200, SingleArticleResponse(article=_article(row, include_body=True))


@router.delete("/api/articles/:slug")
def delete_article(request: HttpRequest):
    viewer = _viewer(request, required=True)
    art = db.article_for_write(request.params["slug"])
    if not art:
        raise ApiError(404, "article not found")
    if art["author_id"] != viewer:
        raise ApiError(403, "not the author")
    db.delete_article(art["id"])
    return 204, Empty()


# ---- favorites -----------------------------------------------------------


def _favorite(request: HttpRequest) -> Tuple[int, SingleArticleResponse]:
    viewer = _viewer(request, required=True)
    art = db.article_for_write(request.params["slug"])
    if not art:
        raise ApiError(404, "article not found")
    row = db.find_article_by_id(viewer, art["id"])
    if not row:
        raise ApiError(404, "article not found")
    return 200, SingleArticleResponse(article=_article(row, include_body=True))


@router.post("/api/articles/:slug/favorite")
def favorite(request: HttpRequest):
    viewer = _viewer(request, required=True)
    art = db.article_for_write(request.params["slug"])
    if not art:
        raise ApiError(404, "article not found")
    db.favorite(viewer, art["id"])
    return _favorite(request)


@router.delete("/api/articles/:slug/favorite")
def unfavorite(request: HttpRequest):
    viewer = _viewer(request, required=True)
    art = db.article_for_write(request.params["slug"])
    if not art:
        raise ApiError(404, "article not found")
    db.unfavorite(viewer, art["id"])
    return _favorite(request)


# ---- comments ------------------------------------------------------------


@router.get("/api/articles/:slug/comments")
def list_comments(request: HttpRequest):
    viewer = _viewer(request, required=False)
    rows = yield db.q_list_comments_by_slug(viewer, request.params["slug"])
    if rows is None:
        raise ApiError(404, "article not found")
    comments = [  # rows in COMMENT_ROW order
        {
            "id": id_,
            "createdAt": created_at,
            "updatedAt": updated_at,
            "body": body,
            "author": ProfileData(username=username, bio=bio, image=image, following=following),
        }
        for (id_, body, created_at, updated_at, username, bio, image, following) in rows
    ]
    return 200, CommentsResponse(comments=comments)


@router.post("/api/articles/:slug/comments")
def create_comment(request: HttpRequest):
    viewer = _viewer(request, required=True)
    art = db.article_for_write(request.params["slug"])  # noqa: E302 — body validated first
    comment = request.json_wrapped("comment")
    if not services.is_non_empty_string(comment.get("body")):
        raise ApiError(422, "comment body is required")
    if not art:
        raise ApiError(404, "article not found")
    row = db.create_comment(viewer, art["id"], comment["body"])
    data = {
        "id": row["id"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
        "body": row["body"],
        "author": ProfileData(
            username=row["username"], bio=row["bio"], image=row["image"], following=False
        ),
    }
    return 201, SingleCommentResponse(comment=data)


@router.delete("/api/articles/:slug/comments/:comment_id")
def delete_comment(request: HttpRequest):
    viewer = _viewer(request, required=True)
    raw_id = request.params["comment_id"]
    if not raw_id.isdigit():
        raise ApiError(404, "comment not found")
    row = db.comment_for_write(request.params["slug"], int(raw_id))
    if not row:
        raise ApiError(404, "comment not found")
    if row["author_id"] != viewer:
        raise ApiError(403, "not the commenter")
    db.delete_comment(int(raw_id))
    return 204, Empty()


# ---- tags ----------------------------------------------------------------


@router.get("/api/tags")
def tags(request: HttpRequest):
    return 200, TagsResponse(tags=(yield db.q_list_tags()))
