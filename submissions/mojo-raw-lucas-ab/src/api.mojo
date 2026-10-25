# The Conduit API: routing, and each endpoint as a chain of steps. route() starts a request; on_result() runs
# when one of its Postgres batches is done and on_bcrypt() when its bcrypt job is. Each returns True when the
# response is ready in w.out, False when the request moved on to another step (or, for route(), is waiting).
#
# Check order everywhere: authentication (401), then the body and query (422), then lookups (404, 403).

from buf import BytePtr, ByteBuf
from http import Request, error_response, Response, eq_lit, METHOD_GET, METHOD_POST, METHOD_PUT, METHOD_DELETE
from server import Worker
from pg import Results
from json import put_json_str
from jsonin import Json, T_ARRAY, T_NULL, T_STRING
from bcrypt import HASH_LEN, MAX_PASSWORD_BYTES
from bcrypt_worker import OP_HASH, OP_VERIFY, BCRYPT_COST
from reqs import *
import sql

# What a Postgres batch is for
comptime K_TAGS = 1
comptime K_REGISTER = 2
comptime K_LOGIN_LOOKUP = 3
comptime K_USER_GET = 4
comptime K_USER_UPDATE = 5
comptime K_PROFILE = 6
comptime K_FOLLOW_LOOKUP = 7  # Conn.aux: 1 follow, 0 unfollow
comptime K_FOLLOW_DONE = 8
comptime K_LIST = 9
comptime K_ARTICLE = 10  # one full article, 200
comptime K_ARTICLE_CREATE = 11
comptime K_ARTICLE_CREATED = 12  # the full article, 201
comptime K_ARTICLE_EDIT_LOOKUP = 13
comptime K_AFTER_WRITE = 14  # a write, then the full article (200)
comptime K_ARTICLE_DELETE_LOOKUP = 15
comptime K_NO_CONTENT = 16  # a delete: 204
comptime K_FAVORITE_LOOKUP = 17  # Conn.aux: 1 favorite, 0 unfavorite
comptime K_COMMENTS_LOOKUP = 18
comptime K_COMMENTS = 19
comptime K_COMMENT_CREATE_LOOKUP = 20
comptime K_COMMENT_CREATED = 21
comptime K_COMMENT_DELETE_LOOKUP = 22  # Conn.aux: the comment id

# Conn.stage while waiting for a bcrypt worker
comptime S_NONE = 0
comptime S_REGISTER_HASH = 1
comptime S_LOGIN_VERIFY = 2
comptime S_UPDATE_HASH = 3


def route(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    """Starts one request. True if it now waits (Postgres or bcrypt), False if it was answered already."""
    var path = p.unsafe_offset(req.path_off)
    var n = req.path_len
    var m = req.method
    var keep = req.keep_alive
    if eq_lit(path, n, "/api/tags"):
        if m != METHOD_GET:
            return not_found(w, keep)
        w.conn(fd).ctx.len = 0
        var i = w.pg_read()
        w.pgs[i].bind_begin(sql.STMT_TAGS, 0)
        w.pgs[i].bind_end()
        return send_batch(w, i, fd, K_TAGS)
    if eq_lit(path, n, "/api/users") and m == METHOD_POST:
        return register(w, fd, p, req)
    if eq_lit(path, n, "/api/users/login") and m == METHOD_POST:
        return login(w, fd, p, req)
    if eq_lit(path, n, "/api/user") and (m == METHOD_GET or m == METHOD_PUT):
        if not auth_required(w, fd, p, req):
            return False
        if m == METHOD_PUT:
            return update_user(w, fd, p, req)
        var i = w.pg_read()
        w.pgs[i].bind_begin(sql.STMT_USER_BY_ID, 1)
        w.pgs[i].param_int(w.conn(fd).uid)
        w.pgs[i].bind_end()
        return send_batch(w, i, fd, K_USER_GET)
    if n > 14 and eq_lit(path, 14, "/api/profiles/"):
        var s = split_path(path, n, 14)
        if s.count == 1 and s.len0 > 0 and m == METHOD_GET:
            return get_profile(w, fd, p, req, path.unsafe_offset(s.off0), s.len0)
        if s.count == 2 and s.len0 > 0 and eq_lit(path.unsafe_offset(s.off1), s.len1, "follow"):
            if m == METHOD_POST or m == METHOD_DELETE:
                return follow(w, fd, p, req, path.unsafe_offset(s.off0), s.len0, m == METHOD_POST)
        return not_found(w, keep)
    if eq_lit(path, n, "/api/articles"):
        if m == METHOD_GET:
            return list_articles(w, fd, p, req, False)
        if m == METHOD_POST:
            return create_article(w, fd, p, req)
        return not_found(w, keep)
    if eq_lit(path, n, "/api/articles/feed") and m == METHOD_GET:
        return list_articles(w, fd, p, req, True)
    if n > 14 and eq_lit(path, 14, "/api/articles/"):
        var s = split_path(path, n, 14)
        if s.len0 == 0 or s.count > 3:
            return not_found(w, keep)
        var slug = path.unsafe_offset(s.off0)
        if s.count == 1:
            if m == METHOD_GET:
                return get_article(w, fd, p, req, slug, s.len0)
            if m == METHOD_PUT:
                return update_article(w, fd, p, req, slug, s.len0)
            if m == METHOD_DELETE:
                return delete_article(w, fd, p, req, slug, s.len0)
            return not_found(w, keep)
        var what = path.unsafe_offset(s.off1)
        if s.count == 2 and eq_lit(what, s.len1, "favorite") and (m == METHOD_POST or m == METHOD_DELETE):
            return favorite(w, fd, p, req, slug, s.len0, m == METHOD_POST)
        if eq_lit(what, s.len1, "comments"):
            if s.count == 2 and m == METHOD_GET:
                return list_comments(w, fd, p, req, slug, s.len0)
            if s.count == 2 and m == METHOD_POST:
                return create_comment(w, fd, p, req, slug, s.len0)
            if s.count == 3 and m == METHOD_DELETE:
                return delete_comment(w, fd, p, req, slug, s.len0, path.unsafe_offset(s.off2), s.len2)
        return not_found(w, keep)
    return not_found(w, keep)


def not_found(mut w: Worker, keep: Bool) -> Bool:
    error_response(w.out, 404, keep, "not found")
    return False


def unprocessable(mut w: Worker, keep: Bool, msg: StaticString) -> Bool:
    error_response(w.out, 422, keep, msg)
    return False


def bind_segment(mut w: Worker, i: Int, seg: BytePtr, n: Int):
    """Binds a percent-decoded path segment as a text parameter."""
    w.tmp.len = 0
    percent_decode(seg, n, w.tmp, False)
    w.pgs[i].param_text(w.tmp.ptr, w.tmp.len)


# --- users -------------------------------------------------------------------------------------------------


def register(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    var json = Json(p, 0)
    var u = body_object(p, req, "user", json)
    if u < 0:
        return unprocessable(w, req.keep_alive, 'body must be {"user": {...}}')
    ref c = w.conn(fd)
    c.ctx.len = 0
    ctx_put(c.ctx, p, 0)  # field 0: no token
    # ctx: 1 username, 2 email
    if ctx_string_field(json, u, "username", c.ctx) <= 0 or ctx_string_field(json, u, "email", c.ctx) <= 0:
        return unprocessable(w, req.keep_alive, "username, email and password must be non-empty strings")
    w.tmp.len = 0
    var pl = string_field(json, u, "password", w.tmp)
    if pl <= 0:
        return unprocessable(w, req.keep_alive, "username, email and password must be non-empty strings")
    if pl > MAX_PASSWORD_BYTES:
        return unprocessable(w, req.keep_alive, "password must be at most 72 bytes")
    c.stage = S_REGISTER_HASH
    if not w.bc_submit(fd, OP_HASH, BCRYPT_COST, w.tmp.ptr, w.tmp.len, w.tmp.ptr, 0):
        c.stage = S_NONE
        error_response(w.out, 500, req.keep_alive, "busy")
        return False
    return True


def login(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    var json = Json(p, 0)
    var u = body_object(p, req, "user", json)
    if u < 0:
        return unprocessable(w, req.keep_alive, 'body must be {"user": {...}}')
    ref c = w.conn(fd)
    c.ctx.len = 0
    ctx_put(c.ctx, p, 0)  # field 0: no token
    var pl = ctx_string_field(json, u, "password", c.ctx)  # field 1, for the bcrypt step
    w.tmp.len = 0
    var el = string_field(json, u, "email", w.tmp)
    if pl <= 0 or el <= 0:
        return unprocessable(w, req.keep_alive, "email and password must be non-empty strings")
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_USER_BY_EMAIL, 1)
    w.pgs[i].param_text(w.tmp.ptr, w.tmp.len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, K_LOGIN_LOOKUP)


def update_user(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    """PUT /api/user. ctx: 0 token, 1 email, 2 username, 3 bio, 4 image (NULL = unchanged)."""
    var json = Json(p, 0)
    var u = body_object(p, req, "user", json)
    if u < 0:
        return unprocessable(w, req.keep_alive, 'body must be {"user": {...}}')
    ref c = w.conn(fd)
    var keys: List[StaticString] = ["email", "username", "bio", "image"]
    for k in range(4):
        var l = ctx_string_field(json, u, keys[k], c.ctx)
        if l == -2 or (l == 0 and k < 2):
            return unprocessable(w, req.keep_alive, "fields must be strings; email and username non-empty")
    w.tmp.len = 0
    var pl = string_field(json, u, "password", w.tmp)
    if pl == -2 or pl == 0:
        return unprocessable(w, req.keep_alive, "password must be a non-empty string")
    if pl > MAX_PASSWORD_BYTES:
        return unprocessable(w, req.keep_alive, "password must be at most 72 bytes")
    if pl > 0:
        c.stage = S_UPDATE_HASH
        if not w.bc_submit(fd, OP_HASH, BCRYPT_COST, w.tmp.ptr, w.tmp.len, w.tmp.ptr, 0):
            c.stage = S_NONE
            error_response(w.out, 500, req.keep_alive, "busy")
            return False
        return True
    run_user_update(w, fd, BytePtr.unsafe_dangling(), -1)
    return True


def run_user_update(mut w: Worker, fd: Int, hash: BytePtr, hash_len: Int):
    var i = w.pg_write()
    w.pgs[i].bind_begin(sql.STMT_USER_UPDATE, 6)
    w.pgs[i].param_int(w.conn(fd).uid)
    param_ctx(w, i, fd, 1)  # email
    param_ctx(w, i, fd, 2)  # username
    if hash_len < 0:
        w.pgs[i].param_null()
    else:
        w.pgs[i].param_text(hash, hash_len)
    param_ctx(w, i, fd, 3)  # bio
    param_ctx(w, i, fd, 4)  # image
    w.pgs[i].bind_end()
    _ = send_batch(w, i, fd, K_USER_UPDATE)


def put_user_fields(mut out: ByteBuf, res: Results):
    """"email":..,"username":..,"bio":..,"image":.. from a row (id, username, email, bio, image, ...)."""
    out.put_str('"email":')
    put_col_str(out, res, 2)
    out.put_str(',"username":')
    put_col_str(out, res, 1)
    out.put_str(',"bio":')
    put_col_str(out, res, 3)
    out.put_str(',"image":')
    put_col_str(out, res, 4)


def respond_user_row(mut w: Worker, fd: Int, status: Int, res: Results, fresh_token: Bool):
    """{"user": {...}} for the current row, with a fresh token or the presented one (ctx field 0)."""
    var resp = Response(w.out, status, w.conn(fd).keep_alive)
    w.out.put_str('{"user":{')
    put_user_fields(w.out, res)
    w.out.put_str(',"token":"')
    if fresh_token:
        w.jwt.sign(res.column_int(0), w.out)
    else:
        var n = 0
        var t = ctx_get(w.conn(fd).ctx, 0, n)
        w.out.put_bytes(t, n)
    w.out.put_str('"}}')
    resp.finish(w.out)


# --- profiles ----------------------------------------------------------------------------------------------


def get_profile(mut w: Worker, fd: Int, p: BytePtr, req: Request, user: BytePtr, user_len: Int) -> Bool:
    if not auth_optional(w, fd, p, req):
        return False
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_PROFILE, 2)
    w.pgs[i].param_int(w.conn(fd).uid)
    bind_segment(w, i, user, user_len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, K_PROFILE)


def follow(mut w: Worker, fd: Int, p: BytePtr, req: Request, user: BytePtr, user_len: Int, add: Bool) -> Bool:
    if not auth_required(w, fd, p, req):
        return False
    w.conn(fd).aux = 1 if add else 0
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_USER_BY_USERNAME, 1)
    bind_segment(w, i, user, user_len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, K_FOLLOW_LOOKUP)


# --- articles ----------------------------------------------------------------------------------------------


def list_articles(mut w: Worker, fd: Int, p: BytePtr, req: Request, feed: Bool) -> Bool:
    if feed:
        if not auth_required(w, fd, p, req):
            return False
    elif not auth_optional(w, fd, p, req):
        return False
    var q = Query()
    if not parse_query(p, req, w.qbuf, q):
        return unprocessable(w, req.keep_alive, "limit must be 1..100 and offset >= 0")
    var viewer = w.conn(fd).uid
    var i = w.pg_read()
    var list_stmt = sql.STMT_LIST_ALL
    var f_off = 0
    var f_len = -1
    if feed:
        list_stmt = sql.STMT_FEED
    elif q.tag_len > 0:  # only the first filter of tag, author, favorited applies
        list_stmt = sql.STMT_LIST_TAG
        f_off = q.tag_off
        f_len = q.tag_len
    elif q.author_len > 0:
        list_stmt = sql.STMT_LIST_AUTHOR
        f_off = q.author_off
        f_len = q.author_len
    elif q.fav_len > 0:
        list_stmt = sql.STMT_LIST_FAVORITED
        f_off = q.fav_off
        f_len = q.fav_len
    var filter = w.qbuf.ptr.unsafe_offset(f_off)
    w.pgs[i].bind_begin(list_stmt, 4 if f_len > 0 else 3)
    w.pgs[i].param_int(viewer)
    w.pgs[i].param_int(q.limit)
    w.pgs[i].param_int(q.offset)
    if f_len > 0:
        w.pgs[i].param_text(filter, f_len)
    w.pgs[i].bind_end()  # one statement: the page and its capped count (sql.list_statement)
    return send_batch(w, i, fd, K_LIST)


def get_article(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int) -> Bool:
    if not auth_optional(w, fd, p, req):
        return False
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_ARTICLE_BY_SLUG, 2)
    w.pgs[i].param_int(w.conn(fd).uid)
    bind_segment(w, i, slug, slug_len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, K_ARTICLE)


def create_article(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    """ctx: 0 token, 1 title, 2 description, 3 body, 4 the tags as a text[] literal (NULL when none)."""
    if not auth_required(w, fd, p, req):
        return False
    var json = Json(p, 0)
    var a = body_object(p, req, "article", json)
    var keep = req.keep_alive
    if a < 0:
        return unprocessable(w, keep, 'body must be {"article": {...}}')
    ref c = w.conn(fd)
    var keys: List[StaticString] = ["title", "description", "body"]
    for k in range(3):
        if ctx_string_field(json, a, keys[k], c.ctx) <= 0:
            return unprocessable(w, keep, "title, description and body must be non-empty strings")
    var tl = json.get(a, "tagList")
    var ntags = 0
    var at = c.ctx.len
    ctx_put_len(c.ctx, 0)
    if tl >= 0 and json.kind(tl) != T_NULL:
        if json.kind(tl) != T_ARRAY:
            return unprocessable(w, keep, "tagList must be an array of non-empty strings")
        var start = c.ctx.len
        ntags = pg_text_array_literal(json, tl, c.ctx)
        if ntags < 0:
            return unprocessable(w, keep, "tagList must be an array of non-empty strings")
        ctx_set_len(c.ctx, at, c.ctx.len - start)
    if ntags == 0:
        c.ctx.len = at
        ctx_put(c.ctx, p, -1)

    # One batch, so one implicit transaction: the article and its tags commit together or not at all.
    var i = w.pg_write()
    w.pgs[i].bind_begin(sql.STMT_ARTICLE_INSERT, 4)
    w.pgs[i].param_int(c.uid)
    param_ctx(w, i, fd, 1)
    param_ctx(w, i, fd, 2)
    param_ctx(w, i, fd, 3)
    w.pgs[i].bind_end()
    if ntags > 0:
        w.pgs[i].bind_begin(sql.STMT_TAGS_INSERT, 1)
        param_ctx(w, i, fd, 4)
        w.pgs[i].bind_end()
        w.pgs[i].bind_begin(sql.STMT_ARTICLE_TAGS_INSERT, 1)
        param_ctx(w, i, fd, 4)
        w.pgs[i].bind_end()
    return send_batch(w, i, fd, K_ARTICLE_CREATE)


def update_article(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int) -> Bool:
    """ctx: 0 token, 1 title, 2 description, 3 body (NULL = unchanged)."""
    if not auth_required(w, fd, p, req):
        return False
    var json = Json(p, 0)
    var a = body_object(p, req, "article", json)
    var keep = req.keep_alive
    if a < 0:
        return unprocessable(w, keep, 'body must be {"article": {...}}')
    ref c = w.conn(fd)
    var keys: List[StaticString] = ["title", "description", "body"]
    for k in range(3):
        var l = ctx_string_field(json, a, keys[k], c.ctx)
        if l == -2 or l == 0:
            return unprocessable(w, keep, "title, description and body must be non-empty strings")
    return owner_lookup(w, fd, slug, slug_len, K_ARTICLE_EDIT_LOOKUP)


def delete_article(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int) -> Bool:
    if not auth_required(w, fd, p, req):
        return False
    return owner_lookup(w, fd, slug, slug_len, K_ARTICLE_DELETE_LOOKUP)


def owner_lookup(mut w: Worker, fd: Int, slug: BytePtr, slug_len: Int, kind: Int) -> Bool:
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_ARTICLE_OWNER, 1)
    bind_segment(w, i, slug, slug_len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, kind)


def favorite(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int, add: Bool) -> Bool:
    if not auth_required(w, fd, p, req):
        return False
    w.conn(fd).aux = 1 if add else 0
    return article_id_lookup(w, fd, slug, slug_len, K_FAVORITE_LOOKUP)


def article_id_lookup(mut w: Worker, fd: Int, slug: BytePtr, slug_len: Int, kind: Int) -> Bool:
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_ARTICLE_ID, 1)
    bind_segment(w, i, slug, slug_len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, kind)


# --- comments ----------------------------------------------------------------------------------------------


def list_comments(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int) -> Bool:
    if not auth_optional(w, fd, p, req):
        return False
    return article_id_lookup(w, fd, slug, slug_len, K_COMMENTS_LOOKUP)


def create_comment(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int) -> Bool:
    """ctx: 0 token, 1 body."""
    if not auth_required(w, fd, p, req):
        return False
    var json = Json(p, 0)
    var cm = body_object(p, req, "comment", json)
    if cm < 0:
        return unprocessable(w, req.keep_alive, 'body must be {"comment": {...}}')
    if ctx_string_field(json, cm, "body", w.conn(fd).ctx) <= 0:
        return unprocessable(w, req.keep_alive, "body must be a non-empty string")
    return article_id_lookup(w, fd, slug, slug_len, K_COMMENT_CREATE_LOOKUP)


def delete_comment(mut w: Worker, fd: Int, p: BytePtr, req: Request, slug: BytePtr, slug_len: Int, id: BytePtr,
                   id_len: Int) -> Bool:
    if not auth_required(w, fd, p, req):
        return False
    var cid = parse_uint(id, id_len, 18)
    if cid <= 0:
        return not_found(w, req.keep_alive)  # a non-integer id names no comment
    w.conn(fd).aux = cid
    var i = w.pg_read()
    w.pgs[i].bind_begin(sql.STMT_COMMENT_OWNER, 2)
    w.pgs[i].param_int(cid)
    bind_segment(w, i, slug, slug_len)
    w.pgs[i].bind_end()
    return send_batch(w, i, fd, K_COMMENT_DELETE_LOOKUP)


# --- Postgres results --------------------------------------------------------------------------------------


def article_by_id(mut w: Worker, i: Int, fd: Int, id: Int):
    """Appends ARTICLE_FULL_SELECT WHERE a.id = id to the batch being written on connection i."""
    w.pgs[i].bind_begin(sql.STMT_ARTICLE_BY_ID, 2)
    w.pgs[i].param_int(w.conn(fd).uid)
    w.pgs[i].param_int(id)
    w.pgs[i].bind_end()


def respond_article(mut w: Worker, fd: Int, status: Int, mut res: Results):
    """The current row as {"article": {...}} (the row must be there)."""
    var resp = Response(w.out, status, w.conn(fd).keep_alive)
    w.out.put_str('{"article":')
    put_article(w.out, res, True, w.arr)
    w.out.put(125)
    resp.finish(w.out)


def on_result(mut w: Worker, fd: Int, kind: Int, mut res: Results) -> Bool:
    """Handles a finished Postgres batch. True when the response is ready in w.out."""
    var keep = w.conn(fd).keep_alive
    if kind == K_TAGS:
        var resp = Response(w.out, 200, keep)
        w.out.put_str('{"tags":[')
        var first = True
        while res.next_row():
            if not first:
                w.out.put(44)
            first = False
            var l = 0
            var v = res.column(0, l)
            put_json_str(w.out, v, l)
        if res.error_state != 0:
            w.out.len = resp.status_at
            db_error(w, fd, res.error_state)
            return True
        w.out.put_str("]}")
        resp.finish(w.out)
        return True

    if kind == K_LIST:
        # Every row carries the count; an empty page is one row whose article columns are NULL.
        var resp = Response(w.out, 200, keep)
        w.out.put_str('{"articles":[')
        var first = True
        var rows = 0
        while res.next_row():
            rows += 1
            var idl = 0
            _ = res.column(0, idl)
            if idl < 0:
                continue
            if not first:
                w.out.put(44)
            first = False
            put_article(w.out, res, False, w.arr)
        if res.error_state != 0 or rows == 0:
            w.out.len = resp.status_at
            db_error(w, fd, res.error_state)
            return True
        # The last row is still in the batch's buffer.
        w.out.put_str('],"articlesCount":')
        put_col_raw(w.out, res, sql.LIST_COUNT_COLUMN)
        w.out.put(125)
        resp.finish(w.out)
        return True

    if kind == K_COMMENTS:
        var resp = Response(w.out, 200, keep)
        w.out.put_str('{"comments":[')
        var first = True
        while res.next_row():
            if not first:
                w.out.put(44)
            first = False
            put_comment(w.out, res, 7)
        if res.error_state != 0:
            w.out.len = resp.status_at
            db_error(w, fd, res.error_state)
            return True
        w.out.put_str("]}")
        resp.finish(w.out)
        return True

    if kind == K_AFTER_WRITE:
        res.skip_statement()  # the write itself returns no rows

    var row = res.next_row()
    if res.error_state != 0:
        db_error(w, fd, res.error_state)
        return True

    if kind == K_REGISTER:
        if not row:
            error_response(w.out, 500, keep, "insert returned nothing")
        else:
            respond_user_row(w, fd, 201, res, True)
        return True
    if kind == K_USER_GET or kind == K_USER_UPDATE:
        if not row:
            error_response(w.out, 401, keep, "unknown user")
        else:
            respond_user_row(w, fd, 200, res, False)
        return True
    if kind == K_LOGIN_LOOKUP:
        if not row:
            error_response(w.out, 401, keep, "wrong email or password")
            return True
        var hl = 0
        var hash = res.column(5, hl)
        ref c = w.conn(fd)
        var pl = 0
        var pw = ctx_get(c.ctx, 1, pl)
        if hl != HASH_LEN or not w.bc_submit(fd, OP_VERIFY, 0, pw, pl, hash, hl):
            error_response(w.out, 401 if hl != HASH_LEN else 500, keep, "cannot verify password")
            return True
        # Keep only what the response needs: the user id and the rendered user fields (ctx field 1).
        c.uid = res.column_int(0)
        c.ctx.len = 0
        ctx_put(c.ctx, pw, 0)
        var at = c.ctx.len
        ctx_put_len(c.ctx, 0)
        var start = c.ctx.len
        put_user_fields(c.ctx, res)
        ctx_set_len(c.ctx, at, c.ctx.len - start)
        c.stage = S_LOGIN_VERIFY
        return False

    if kind == K_PROFILE:
        if not row:
            error_response(w.out, 404, keep, "no such user")
            return True
        var resp = Response(w.out, 200, keep)
        w.out.put_str('{"profile":{')
        put_profile_fields(w.out, res, 1)
        w.out.put_str(',"following":')
        put_col_bool(w.out, res, 4)
        w.out.put_str("}}")
        resp.finish(w.out)
        return True
    if kind == K_FOLLOW_LOOKUP:
        if not row:
            error_response(w.out, 404, keep, "no such user")
            return True
        # ctx field 1: the profile fields, for the response after the write
        ref c = w.conn(fd)
        var at = c.ctx.len
        ctx_put_len(c.ctx, 0)
        var start = c.ctx.len
        put_profile_fields(c.ctx, res, 1)
        ctx_set_len(c.ctx, at, c.ctx.len - start)
        var i = w.pg_write()
        w.pgs[i].bind_begin(sql.STMT_FOLLOW if c.aux == 1 else sql.STMT_UNFOLLOW, 2)
        w.pgs[i].param_int(c.uid)
        w.pgs[i].param_int(res.column_int(0))
        w.pgs[i].bind_end()
        _ = send_batch(w, i, fd, K_FOLLOW_DONE)
        return False
    if kind == K_FOLLOW_DONE:
        var resp = Response(w.out, 200, keep)
        w.out.put_str('{"profile":{')
        var n = 0
        var fields = ctx_get(w.conn(fd).ctx, 1, n)
        w.out.put_bytes(fields, n)
        w.out.put_str(',"following":')
        w.out.put_str("true" if w.conn(fd).aux == 1 else "false")
        w.out.put_str("}}")
        resp.finish(w.out)
        return True

    if kind == K_ARTICLE or kind == K_ARTICLE_CREATED or kind == K_AFTER_WRITE:
        if not row:
            error_response(w.out, 404, keep, "no such article")
            return True
        respond_article(w, fd, 201 if kind == K_ARTICLE_CREATED else 200, res)
        return True
    if kind == K_ARTICLE_CREATE:
        if not row:
            error_response(w.out, 500, keep, "insert returned nothing")
            return True
        var id = res.column_int(0)
        res.skip_statement()  # the rest of the insert's statement
        res.skip_statement()  # tags
        res.skip_statement()  # article_tags
        if res.error_state != 0:
            db_error(w, fd, res.error_state)
            return True
        var i = w.pg_read()
        article_by_id(w, i, fd, id)
        _ = send_batch(w, i, fd, K_ARTICLE_CREATED)
        return False
    if kind == K_ARTICLE_EDIT_LOOKUP or kind == K_ARTICLE_DELETE_LOOKUP:
        if not row:
            error_response(w.out, 404, keep, "no such article")
            return True
        if res.column_int(1) != w.conn(fd).uid:
            error_response(w.out, 403, keep, "not your article")
            return True
        var id = res.column_int(0)
        var i = w.pg_write()
        if kind == K_ARTICLE_DELETE_LOOKUP:
            w.pgs[i].bind_begin(sql.STMT_ARTICLE_DELETE, 1)
            w.pgs[i].param_int(id)
            w.pgs[i].bind_end()
            _ = send_batch(w, i, fd, K_NO_CONTENT)
            return False
        w.pgs[i].bind_begin(sql.STMT_ARTICLE_UPDATE, 4)
        w.pgs[i].param_int(id)
        param_ctx(w, i, fd, 1)
        param_ctx(w, i, fd, 2)
        param_ctx(w, i, fd, 3)
        w.pgs[i].bind_end()
        article_by_id(w, i, fd, id)
        _ = send_batch(w, i, fd, K_AFTER_WRITE)
        return False
    if kind == K_NO_CONTENT:
        var resp = Response(w.out, 204, keep)
        resp.finish(w.out)
        return True
    if kind == K_FAVORITE_LOOKUP:
        if not row:
            error_response(w.out, 404, keep, "no such article")
            return True
        var id = res.column_int(0)
        var i = w.pg_write()
        w.pgs[i].bind_begin(sql.STMT_FAVORITE if w.conn(fd).aux == 1 else sql.STMT_UNFAVORITE, 2)
        w.pgs[i].param_int(w.conn(fd).uid)
        w.pgs[i].param_int(id)
        w.pgs[i].bind_end()
        article_by_id(w, i, fd, id)
        _ = send_batch(w, i, fd, K_AFTER_WRITE)
        return False
    if kind == K_COMMENTS_LOOKUP:
        if not row:
            error_response(w.out, 404, keep, "no such article")
            return True
        var i = w.pg_read()
        w.pgs[i].bind_begin(sql.STMT_COMMENTS, 2)
        w.pgs[i].param_int(w.conn(fd).uid)
        w.pgs[i].param_int(res.column_int(0))
        w.pgs[i].bind_end()
        _ = send_batch(w, i, fd, K_COMMENTS)
        return False
    if kind == K_COMMENT_CREATE_LOOKUP:
        if not row:
            error_response(w.out, 404, keep, "no such article")
            return True
        var i = w.pg_write()
        w.pgs[i].bind_begin(sql.STMT_COMMENT_INSERT, 3)
        w.pgs[i].param_int(res.column_int(0))
        w.pgs[i].param_int(w.conn(fd).uid)
        param_ctx(w, i, fd, 1)
        w.pgs[i].bind_end()
        _ = send_batch(w, i, fd, K_COMMENT_CREATED)
        return False
    if kind == K_COMMENT_CREATED:
        if not row:
            error_response(w.out, 500, keep, "insert returned nothing")
            return True
        var resp = Response(w.out, 201, keep)
        w.out.put_str('{"comment":')
        put_comment(w.out, res, -1)
        w.out.put(125)
        resp.finish(w.out)
        return True
    if kind == K_COMMENT_DELETE_LOOKUP:
        if not row:
            error_response(w.out, 404, keep, "no such comment")
            return True
        if res.column_int(0) != w.conn(fd).uid:
            error_response(w.out, 403, keep, "not your comment")
            return True
        var i = w.pg_write()
        w.pgs[i].bind_begin(sql.STMT_COMMENT_DELETE, 1)
        w.pgs[i].param_int(w.conn(fd).aux)
        w.pgs[i].bind_end()
        _ = send_batch(w, i, fd, K_NO_CONTENT)
        return False
    error_response(w.out, 500, keep, "internal error")
    return True


# --- bcrypt results ----------------------------------------------------------------------------------------


def on_bcrypt(mut w: Worker, fd: Int, ok: Bool, hash: BytePtr, hash_len: Int) -> Bool:
    """Handles a bcrypt worker's reply. True when the response is ready in w.out."""
    ref c = w.conn(fd)
    var keep = c.keep_alive
    var stage = c.stage
    c.stage = S_NONE
    if stage == S_LOGIN_VERIFY:
        if not ok:
            error_response(w.out, 401, keep, "wrong email or password")
            return True
        var resp = Response(w.out, 200, keep)
        w.out.put_str('{"user":{')
        var n = 0
        var fields = ctx_get(c.ctx, 1, n)
        w.out.put_bytes(fields, n)
        w.out.put_str(',"token":"')
        w.jwt.sign(c.uid, w.out)
        w.out.put_str('"}}')
        resp.finish(w.out)
        return True
    if not ok or hash_len != HASH_LEN:
        error_response(w.out, 500, keep, "hashing failed")
        return True
    if stage == S_REGISTER_HASH:
        var i = w.pg_write()
        w.pgs[i].bind_begin(sql.STMT_USER_INSERT, 3)
        param_ctx(w, i, fd, 1)  # username
        param_ctx(w, i, fd, 2)  # email
        w.pgs[i].param_text(hash, hash_len)
        w.pgs[i].bind_end()
        _ = send_batch(w, i, fd, K_REGISTER)
        return False
    if stage == S_UPDATE_HASH:
        run_user_update(w, fd, hash, hash_len)
        return False
    error_response(w.out, 500, keep, "internal error")
    return True
