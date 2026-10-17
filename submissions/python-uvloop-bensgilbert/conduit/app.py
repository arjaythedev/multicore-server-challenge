import asyncio
from concurrent.futures import ThreadPoolExecutor
from urllib.parse import unquote_to_bytes

import asyncpg
import orjson

from . import auth, sql
from .db import Pool

INT64_MAX = auth.INT64_MAX

pool: Pool
_executor: ThreadPoolExecutor
_loop: asyncio.AbstractEventLoop


async def start(dsn: str, pool_size: int, hash_threads: int) -> None:
    global pool, _executor, _loop
    _loop = asyncio.get_running_loop()
    _executor = ThreadPoolExecutor(max_workers=hash_threads, thread_name_prefix="bcrypt")
    pool = Pool(dsn, pool_size)
    await pool.start()


async def stop() -> None:
    await pool.close()
    _executor.shutdown(wait=False)


# responses

def _err(status: int, msg: str) -> tuple[int, bytes]:
    return status, b'{"errors":{"body":["' + msg.encode() + b'"]}}'


E_UNAUTHORIZED = _err(401, "authorization required")
E_BAD_TOKEN = _err(401, "invalid or expired token")
E_FORBIDDEN = _err(403, "forbidden")
E_NOT_FOUND = _err(404, "not found")
E_ARTICLE_404 = _err(404, "article not found")
E_PROFILE_404 = _err(404, "profile not found")
E_COMMENT_404 = _err(404, "comment not found")
E_METHOD = _err(405, "method not allowed")
E_BODY = _err(422, "invalid request body")
E_PAGING_LIMIT = _err(422, "limit must be an integer from 1 to 100")
E_PAGING_OFFSET = _err(422, "offset must be an integer >= 0")
E_TAKEN = _err(422, "username or email already taken")
E_PASSWORD = _err(422, "password is too long")
E_LOGIN = _err(401, "invalid email or password")
E_NO_USER = _err(401, "user not found")
NO_CONTENT = (204, b"")

_dumps = orjson.dumps
_loads = orjson.loads


def _user_json(row, token: str) -> tuple[int, bytes]:
    return 200, _dumps({"user": {
        "email": row["email"], "token": token, "username": row["username"], "bio": row["bio"], "image": row["image"],
    }})


# database access

async def _fetchval(query: str, *args):
    conn = pool.take() or await pool.wait()
    try:
        return await conn.fetchval(query, *args)
    finally:
        pool.release(conn) if not conn.is_closed() else pool.discard(conn)


async def _fetchrow(query: str, *args):
    conn = pool.take() or await pool.wait()
    try:
        return await conn.fetchrow(query, *args)
    finally:
        pool.release(conn) if not conn.is_closed() else pool.discard(conn)


# request parsing

def _query(qs: bytes) -> dict:
    """Query string -> {key: raw value}. For a repeated key the first value wins."""
    d: dict = {}
    if qs:
        for item in qs.split(b"&"):
            k, _, v = item.partition(b"=")
            if k not in d:
                d[k] = v
    return d


def _unquote(v: bytes) -> bytes:
    return unquote_to_bytes(v.replace(b"+", b" ")) if (b"%" in v or b"+" in v) else v


def _text(v: bytes) -> str:
    return _unquote(v).decode("utf-8", "replace").replace("\x00", "�")


def _uint(v: bytes) -> int | None:
    v = _unquote(v)
    if not v or len(v) > 19 or not v.isdigit():
        return None
    n = int(v)
    return n if n <= INT64_MAX else None


def _json_object(body: bytes, key: str):
    try:
        d = _loads(body)
    except orjson.JSONDecodeError:
        return None
    if type(d) is not dict:
        return None
    d = d.get(key)
    return d if type(d) is dict else None


def _nonempty(v) -> bool:
    return type(v) is str and v != ""


def _opt_nonempty(v) -> bool:
    return v is None or (type(v) is str and v != "")


def _opt_str(v) -> bool:
    return v is None or type(v) is str


# router

async def handle(method: bytes, path: bytes, query: bytes, authorization: bytes, body: bytes):
    segs = path.split(b"/")
    n = len(segs)
    if n < 3 or segs[1] != b"api" or segs[0]:
        return E_NOT_FOUND
    top = segs[2]
    try:
        if top == b"articles":
            if n == 3:
                if method == b"GET":
                    return await list_articles(authorization, query)
                if method == b"POST":
                    return await create_article(authorization, body)
                return E_METHOD
            second = segs[3]
            if n == 4:
                if second == b"feed":
                    return await feed(authorization, query) if method == b"GET" else E_METHOD
                slug = _text(second)
                if method == b"GET":
                    return await get_article(authorization, slug)
                if method == b"PUT":
                    return await update_article(authorization, slug, body)
                if method == b"DELETE":
                    return await delete_article(authorization, slug)
                return E_METHOD
            third = segs[4]
            if n == 5 and third == b"comments":
                slug = _text(second)
                if method == b"GET":
                    return await list_comments(authorization, slug)
                if method == b"POST":
                    return await add_comment(authorization, slug, body)
                return E_METHOD
            if n == 5 and third == b"favorite":
                slug = _text(second)
                if method == b"POST":
                    return await set_favorite(authorization, slug, True)
                if method == b"DELETE":
                    return await set_favorite(authorization, slug, False)
                return E_METHOD
            if n == 6 and third == b"comments":
                return await delete_comment(authorization, _text(second), segs[5]) if method == b"DELETE" else E_METHOD
            return E_NOT_FOUND
        if top == b"tags":
            if n != 3:
                return E_NOT_FOUND
            return (200, await _fetchval(sql.TAGS)) if method == b"GET" else E_METHOD
        if top == b"user":
            if n != 3:
                return E_NOT_FOUND
            if method == b"GET":
                return await current_user(authorization)
            if method == b"PUT":
                return await update_user(authorization, body)
            return E_METHOD
        if top == b"profiles":
            if n == 4:
                return await get_profile(authorization, _text(segs[3])) if method == b"GET" else E_METHOD
            if n == 5 and segs[4] == b"follow":
                if method == b"POST":
                    return await set_follow(authorization, _text(segs[3]), True)
                if method == b"DELETE":
                    return await set_follow(authorization, _text(segs[3]), False)
                return E_METHOD
            return E_NOT_FOUND
        if top == b"users":
            if n == 3:
                return await register(body) if method == b"POST" else E_METHOD
            if n == 4 and segs[3] == b"login":
                return await login(body) if method == b"POST" else E_METHOD
            return E_NOT_FOUND
        return E_NOT_FOUND
    except asyncpg.UniqueViolationError:
        return E_TAKEN
    except asyncpg.ForeignKeyViolationError:
        return E_NO_USER  # the token's user no longer exists
    except (asyncpg.DataError, asyncpg.ProgramLimitExceededError):  # a value Postgres can't store (class 22 / 54)
        return E_BODY


# users and auth

async def register(body: bytes):
    u = _json_object(body, "user")
    if u is None:
        return E_BODY
    username, email, password = u.get("username"), u.get("email"), u.get("password")
    if not (_nonempty(username) and _nonempty(email) and _nonempty(password)):
        return E_BODY
    password_hash = await _loop.run_in_executor(_executor, auth.hash_password, password)
    if password_hash is None:
        return E_PASSWORD
    row = await _fetchrow(sql.INSERT_USER, username, email, password_hash)
    status, payload = _user_json(row, auth.new_token(row["id"]))
    return 201, payload


async def login(body: bytes):
    u = _json_object(body, "user")
    if u is None:
        return E_BODY
    email, password = u.get("email"), u.get("password")
    if not (_nonempty(email) and _nonempty(password)):
        return E_BODY
    row = await _fetchrow(sql.LOGIN_USER, email)
    if row is None or not await _loop.run_in_executor(_executor, auth.check_password, password, row["password_hash"]):
        return E_LOGIN
    return _user_json(row, auth.new_token(row["id"]))


async def current_user(authorization: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    row = await _fetchrow(sql.GET_USER, viewer)
    if row is None:
        return E_NO_USER
    return _user_json(row, authorization[6:].decode())


async def update_user(authorization: bytes, body: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    u = _json_object(body, "user")
    if u is None:
        return E_BODY
    email, username, password, bio, image = u.get("email"), u.get("username"), u.get("password"), u.get("bio"), u.get("image")
    if not (_opt_nonempty(email) and _opt_nonempty(username) and _opt_nonempty(password) and _opt_str(bio) and _opt_str(image)):
        return E_BODY
    password_hash = None
    if password is not None:
        password_hash = await _loop.run_in_executor(_executor, auth.hash_password, password)
        if password_hash is None:
            return E_PASSWORD
    row = await _fetchrow(sql.UPDATE_USER, viewer, email, username, password_hash, bio, image)
    if row is None:
        return E_NO_USER
    return _user_json(row, authorization[6:].decode())


# profiles

async def get_profile(authorization: bytes, username: str):
    viewer = auth.verify(authorization)
    if viewer < 0:
        return E_BAD_TOKEN
    out = await _fetchval(sql.GET_PROFILE, viewer, username)
    return E_PROFILE_404 if out is None else (200, out)


async def set_follow(authorization: bytes, username: str, follow: bool):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    out = await _fetchval(sql.FOLLOW if follow else sql.UNFOLLOW, viewer, username)
    return E_PROFILE_404 if out is None else (200, out)


# article lists

def _paging(q: dict):
    limit, offset = 20, 0
    v = q.get(b"limit")
    if v is not None:
        limit = _uint(v)
        if limit is None or not 1 <= limit <= 100:
            return None, E_PAGING_LIMIT
    v = q.get(b"offset")
    if v is not None:
        offset = _uint(v)
        if offset is None:
            return None, E_PAGING_OFFSET
    return (limit, offset), None


async def list_articles(authorization: bytes, qs: bytes):
    viewer = auth.verify(authorization)
    if viewer < 0:
        return E_BAD_TOKEN
    q = _query(qs)
    paging, error = _paging(q)
    if error:
        return error
    limit, offset = paging
    # only the first filter that is present is used, in the order tag, author, favorited
    tag = q.get(b"tag")
    if tag:
        return 200, await _fetchval(sql.LIST_TAG[limit], viewer, offset, _text(tag))
    author = q.get(b"author")
    if author:
        return 200, await _fetchval(sql.LIST_AUTHOR[limit], viewer, offset, _text(author))
    favorited = q.get(b"favorited")
    if favorited:
        return 200, await _fetchval(sql.LIST_FAVORITED[limit], viewer, offset, _text(favorited))
    return 200, await _fetchval(sql.LIST_ALL[limit], viewer, offset)


async def feed(authorization: bytes, qs: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    paging, error = _paging(_query(qs))
    if error:
        return error
    return 200, await _fetchval(sql.LIST_FEED[paging[0]], viewer, paging[1])


# articles

async def get_article(authorization: bytes, slug: str):
    viewer = auth.verify(authorization)
    if viewer < 0:
        return E_BAD_TOKEN
    out = await _fetchval(sql.ARTICLE_BY_SLUG, viewer, slug)
    return E_ARTICLE_404 if out is None else (200, out)


async def create_article(authorization: bytes, body: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    a = _json_object(body, "article")
    if a is None:
        return E_BODY
    title, description, text, tags = a.get("title"), a.get("description"), a.get("body"), a.get("tagList")
    if not (_nonempty(title) and _nonempty(description) and _nonempty(text)):
        return E_BODY
    if tags is not None and not (type(tags) is list and all(_nonempty(t) for t in tags)):
        return E_BODY
    conn = pool.take() or await pool.wait()
    try:
        async with conn.transaction():
            article_id = await conn.fetchval(sql.INSERT_ARTICLE, viewer, title, description, text)
            if tags:
                await conn.execute(sql.INSERT_TAGS, tags)
                await conn.execute(sql.INSERT_ARTICLE_TAGS, article_id, tags)
        out = await conn.fetchval(sql.ARTICLE_BY_ID, viewer, article_id)
    finally:
        pool.release(conn) if not conn.is_closed() else pool.discard(conn)
    return 201, out


async def _owned_article(conn, slug: str, viewer: int):
    row = await conn.fetchrow(sql.ARTICLE_OWNER, slug)
    if row is None:
        return None, E_ARTICLE_404
    if row["author_id"] != viewer:
        return None, E_FORBIDDEN
    return row["id"], None


async def update_article(authorization: bytes, slug: str, body: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    a = _json_object(body, "article")
    if a is None:
        return E_BODY
    title, description, text = a.get("title"), a.get("description"), a.get("body")
    if not (_opt_nonempty(title) and _opt_nonempty(description) and _opt_nonempty(text)):
        return E_BODY
    conn = pool.take() or await pool.wait()
    try:
        article_id, error = await _owned_article(conn, slug, viewer)
        if error:
            return error
        await conn.execute(sql.UPDATE_ARTICLE, article_id, title, description, text)
        out = await conn.fetchval(sql.ARTICLE_BY_ID, viewer, article_id)
    finally:
        pool.release(conn) if not conn.is_closed() else pool.discard(conn)
    return 200, out


async def delete_article(authorization: bytes, slug: str):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    conn = pool.take() or await pool.wait()
    try:
        article_id, error = await _owned_article(conn, slug, viewer)
        if error:
            return error
        await conn.execute(sql.DELETE_ARTICLE, article_id)
    finally:
        pool.release(conn) if not conn.is_closed() else pool.discard(conn)
    return NO_CONTENT


async def set_favorite(authorization: bytes, slug: str, favorite: bool):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    out = await _fetchval(sql.FAVORITE if favorite else sql.UNFAVORITE, viewer, slug)
    return E_ARTICLE_404 if out is None else (200, out)


# comments

async def list_comments(authorization: bytes, slug: str):
    viewer = auth.verify(authorization)
    if viewer < 0:
        return E_BAD_TOKEN
    out = await _fetchval(sql.COMMENTS, viewer, slug)
    return E_ARTICLE_404 if out is None else (200, out)


async def add_comment(authorization: bytes, slug: str, body: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    c = _json_object(body, "comment")
    if c is None or not _nonempty(c.get("body")):
        return E_BODY
    out = await _fetchval(sql.ADD_COMMENT, viewer, slug, c["body"])
    return E_ARTICLE_404 if out is None else (201, out)


async def delete_comment(authorization: bytes, slug: str, raw_id: bytes):
    viewer = auth.verify(authorization)
    if viewer <= 0:
        return E_UNAUTHORIZED
    comment_id = _uint(raw_id)
    if comment_id is None:
        return E_COMMENT_404
    row = await _fetchrow(sql.DELETE_COMMENT, comment_id, slug, viewer)
    owner = row[0]
    if owner is None:
        return E_COMMENT_404
    if owner != viewer:
        return E_FORBIDDEN
    return NO_CONTENT
