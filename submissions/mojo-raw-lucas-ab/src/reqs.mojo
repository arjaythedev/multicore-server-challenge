# What every endpoint shares: the request context (Conn.ctx fields), authentication, issuing a Postgres batch,
# body/query/path parsing, and rendering rows as JSON.

from buf import BytePtr, ByteBuf
from http import Request, error_response, eq_lit
from server import Worker
from pg import Pending, Results
from json import put_json_str, put_json_str_or_null, put_timestamp
from jsonin import Json, T_OBJECT, T_NULL

# --- request context: length-prefixed fields in Conn.ctx --------------------------------------------------
#
# Field 0 is always the presented token (empty when anonymous); endpoints append their own fields after it.

comptime CTX_NULL = 0xFFFFFFFF


def ctx_put(mut b: ByteBuf, p: BytePtr, n: Int):
    """Appends a field; n < 0 stores NULL."""
    ctx_put_len(b, n)
    if n > 0:
        b.put_bytes(p, n)


def ctx_put_len(mut b: ByteBuf, n: Int):
    var v = n if n >= 0 else CTX_NULL
    b.put(UInt8(v & 0xFF))
    b.put(UInt8((v >> 8) & 0xFF))
    b.put(UInt8((v >> 16) & 0xFF))
    b.put(UInt8((v >> 24) & 0xFF))


def ctx_set_len(b: ByteBuf, at: Int, n: Int):
    """Patches the length of the field that starts at `at` (written with ctx_put_len(b, 0) beforehand)."""
    var v = n if n >= 0 else CTX_NULL
    b.ptr[unsafe_offset=at] = UInt8(v & 0xFF)
    b.ptr[unsafe_offset=at + 1] = UInt8((v >> 8) & 0xFF)
    b.ptr[unsafe_offset=at + 2] = UInt8((v >> 16) & 0xFF)
    b.ptr[unsafe_offset=at + 3] = UInt8((v >> 24) & 0xFF)


def ctx_get(b: ByteBuf, idx: Int, mut n: Int) -> BytePtr:
    """Field `idx`; n = -1 for NULL."""
    var off = 0
    for _ in range(idx):
        var l = ctx_len(b, off)
        off += 4 + (l if l >= 0 else 0)
    n = ctx_len(b, off)
    return b.ptr.unsafe_offset(off + 4)


@inline(.always)
def ctx_len(b: ByteBuf, off: Int) -> Int:
    var v = (
        Int(b.ptr[unsafe_offset=off])
        | (Int(b.ptr[unsafe_offset=off + 1]) << 8)
        | (Int(b.ptr[unsafe_offset=off + 2]) << 16)
        | (Int(b.ptr[unsafe_offset=off + 3]) << 24)
    )
    return -1 if v == CTX_NULL else v


def param_ctx(mut w: Worker, pi: Int, fd: Int, idx: Int):
    """Binds ctx field `idx` of `fd`'s request as a text parameter (NULL stays NULL)."""
    var n = 0
    var p = ctx_get(w.conn(fd).ctx, idx, n)
    if n < 0:
        w.pgs[pi].param_null()
    else:
        w.pgs[pi].param_text(p, n)


def send_batch(mut w: Worker, i: Int, fd: Int, kind: Int) -> Bool:
    """Ends the batch being written on connection `i` and records who waits for it. On a write connection the
    batch is a member of the next commit group (Worker.pg_write), sent with the others at the end of the round."""
    var p = Pending(fd, w.conn(fd).gen, kind, w.conn(fd).keep_alive)
    if i >= w.n_read:
        w.pgs[i].end_member(p)
    else:
        w.pgs[i].sync()
        w.pgs[i].push(p)
    return True


# --- authentication ----------------------------------------------------------------------------------------

comptime AUTH_NONE = 0  # no Authorization header
comptime AUTH_OK = 1
comptime AUTH_BAD = 2  # a header that isn't a valid "Token <jwt>"


def authenticate(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Int:
    """Verifies the request's token (every time: rule 7). Sets Conn.uid (0 when anonymous) and starts Conn.ctx
    with field 0 = the token."""
    ref c = w.conn(fd)
    c.uid = 0
    c.ctx.len = 0
    if req.auth_len == 0:
        ctx_put(c.ctx, p, 0)
        return AUTH_NONE
    var a = p.unsafe_offset(req.auth_off)
    if req.auth_len < 7 or not eq_lit(a, 6, "Token "):
        return AUTH_BAD
    var tok = a.unsafe_offset(6)
    var tok_len = req.auth_len - 6
    var uid = w.jwt.verify(tok, tok_len)
    if uid < 0:
        return AUTH_BAD
    ref c2 = w.conn(fd)
    c2.uid = uid
    ctx_put(c2.ctx, tok, tok_len)
    return AUTH_OK


def auth_required(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    """False (with a 401 written) unless the request carries a valid token."""
    if authenticate(w, fd, p, req) != AUTH_OK:
        error_response(w.out, 401, req.keep_alive, "unauthorized")
        return False
    return True


def auth_optional(mut w: Worker, fd: Int, p: BytePtr, req: Request) -> Bool:
    """No header is anonymous; a header that is present but invalid is a 401 (written, returns False)."""
    if authenticate(w, fd, p, req) == AUTH_BAD:
        error_response(w.out, 401, req.keep_alive, "unauthorized")
        return False
    return True


# --- request bodies ----------------------------------------------------------------------------------------


def body_object(p: BytePtr, req: Request, wrapper: StaticString, mut json: Json) -> Int:
    """Parses the body into `json`; returns the token of body[wrapper] if it's an object, else -1."""
    json = Json(p.unsafe_offset(req.body_off), req.body_len)
    if not json.ok:
        return -1
    var t = json.get(0, wrapper)
    return t if json.kind(t) == T_OBJECT else -1


def string_field(json: Json, obj: Int, key: StaticString, mut out: ByteBuf) -> Int:
    """Decodes obj[key] into `out` (appending). Returns its length, -1 if absent or null, -2 if not a string."""
    var t = json.get(obj, key)
    if t < 0 or json.kind(t) == T_NULL:
        return -1
    var start = out.len
    if not json.string_value(t, out):
        return -2
    return out.len - start


def ctx_string_field(json: Json, obj: Int, key: StaticString, mut ctx: ByteBuf) -> Int:
    """string_field, stored as the next ctx field (NULL when absent or null). Same return values."""
    var at = ctx.len
    ctx_put_len(ctx, 0)
    var l = string_field(json, obj, key, ctx)
    if l == -2:
        return -2
    ctx_set_len(ctx, at, l)
    return l


# --- paths and query strings -------------------------------------------------------------------------------


@inline(.always)
def hexval(c: UInt8) -> Int:
    if c >= 48 and c <= 57:
        return Int(c) - 48
    var l = c | 0x20
    if l >= 97 and l <= 102:
        return Int(l) - 87
    return -1


def percent_decode(p: BytePtr, n: Int, mut out: ByteBuf, plus_is_space: Bool):
    """%XX escapes (and '+' in query strings, as browsers and Go do); malformed escapes are kept as they are."""
    var i = 0
    while i < n:
        var c = p[unsafe_offset=i]
        if c == 37 and i + 2 < n:
            var hi = hexval(p[unsafe_offset=i + 1])
            var lo = hexval(p[unsafe_offset=i + 2])
            if hi >= 0 and lo >= 0:
                out.put(UInt8(hi * 16 + lo))
                i += 3
                continue
        out.put(32 if (plus_is_space and c == 43) else c)
        i += 1


struct Query(ImplicitlyCopyable):
    """GET /api/articles parameters. Filter values are (offset, length) into the worker's qbuf; length -1 when the
    parameter is absent. An empty filter counts as absent."""

    var limit: Int
    var offset: Int
    var tag_off: Int
    var tag_len: Int
    var author_off: Int
    var author_len: Int
    var fav_off: Int
    var fav_len: Int

    def __init__(out self):
        self.limit = 20
        self.offset = 0
        self.tag_off = 0
        self.tag_len = -1
        self.author_off = 0
        self.author_len = -1
        self.fav_off = 0
        self.fav_len = -1


def parse_uint(p: BytePtr, n: Int, max_digits: Int) -> Int:
    """Digits only (leading zeros allowed), at most `max_digits` significant ones; -1 otherwise."""
    if n == 0:
        return -1
    var v = 0
    var sig = 0
    for i in range(n):
        var c = p[unsafe_offset=i]
        if c < 48 or c > 57:
            return -1
        if sig > 0 or c != 48:
            sig += 1
            if sig > max_digits:
                return -1
            v = v * 10 + Int(c) - 48
    return v


def parse_query(p: BytePtr, req: Request, mut vals: ByteBuf, mut q: Query) -> Bool:
    """Fills `q` from the query string, decoding values into `vals`. False when limit/offset are invalid: limit
    must be an integer 1..100 and offset an integer >= 0 (SPEC.md). The first occurrence of a parameter wins."""
    q = Query()
    vals.len = 0
    var s = p.unsafe_offset(req.query_off)
    var n = req.query_len
    var seen_limit = False
    var seen_offset = False
    var i = 0
    while i < n:
        var k0 = i
        while i < n and s[unsafe_offset=i] != 38 and s[unsafe_offset=i] != 61:  # & =
            i += 1
        var key = s.unsafe_offset(k0)
        var key_len = i - k0
        var v0 = i
        var v1 = i
        if i < n and s[unsafe_offset=i] == 61:
            i += 1
            v0 = i
            while i < n and s[unsafe_offset=i] != 38:
                i += 1
            v1 = i
        i += 1  # skip '&'
        var at = vals.len
        percent_decode(s.unsafe_offset(v0), v1 - v0, vals, True)
        var vl = vals.len - at
        var v = vals.ptr.unsafe_offset(at)
        if eq_lit(key, key_len, "limit"):
            if not seen_limit:
                seen_limit = True
                q.limit = parse_uint(v, vl, 3)
                if q.limit < 1 or q.limit > 100:
                    return False
        elif eq_lit(key, key_len, "offset"):
            if not seen_offset:
                seen_offset = True
                q.offset = parse_uint(v, vl, 18)
                if q.offset < 0:
                    return False
        elif eq_lit(key, key_len, "tag"):
            if q.tag_len < 0 and vl > 0:
                q.tag_off = at
                q.tag_len = vl
        elif eq_lit(key, key_len, "author"):
            if q.author_len < 0 and vl > 0:
                q.author_off = at
                q.author_len = vl
        elif eq_lit(key, key_len, "favorited"):
            if q.fav_len < 0 and vl > 0:
                q.fav_off = at
                q.fav_len = vl
    return True


struct PathSegs(ImplicitlyCopyable):
    """Up to three segments after a known prefix, as (offset, length) into the raw path."""

    var count: Int
    var off0: Int
    var len0: Int
    var off1: Int
    var len1: Int
    var off2: Int
    var len2: Int

    def __init__(out self):
        self.count = 0
        self.off0 = 0
        self.len0 = 0
        self.off1 = 0
        self.len1 = 0
        self.off2 = 0
        self.len2 = 0


def split_path(path: BytePtr, n: Int, start: Int) -> PathSegs:
    """Segments of path[start:n]; count 4 means "too many". Empty segments (a//b or a trailing /) count too."""
    var s = PathSegs()
    var i = start
    while i <= n:
        var j = i
        while j < n and path[unsafe_offset=j] != 47:
            j += 1
        if s.count == 0:
            s.off0 = i
            s.len0 = j - i
        elif s.count == 1:
            s.off1 = i
            s.len1 = j - i
        elif s.count == 2:
            s.off2 = i
            s.len2 = j - i
        s.count += 1
        if s.count > 3:
            return s
        i = j + 1
        if j >= n:
            break
    return s


def pg_text_array_literal(json: Json, arr_tok: Int, mut out: ByteBuf) -> Int:
    """Writes the JSON array of strings as a Postgres text[] literal ({"a","b"}). Returns its element count, or -1
    if an element isn't a non-empty string."""
    var count = 0
    out.put(123)  # {
    var i = arr_tok + 1
    var end = json.toks[arr_tok].next
    while i < end:
        if count > 0:
            out.put(44)
        out.put(34)
        var start = out.len
        if not json.string_value(i, out) or out.len == start:
            return -1
        # Escape " and \ inside the element (in place, from the back).
        var extra = 0
        for k in range(start, out.len):
            var c = out.ptr[unsafe_offset=k]
            if c == 34 or c == 92:
                extra += 1
        if extra > 0:
            var old_end = out.len
            out.reserve(extra)
            out.len += extra
            var dst = out.len - 1
            var k = old_end - 1
            while k >= start:
                var c = out.ptr[unsafe_offset=k]
                out.ptr[unsafe_offset=dst] = c
                dst -= 1
                if c == 34 or c == 92:
                    out.ptr[unsafe_offset=dst] = 92
                    dst -= 1
                k -= 1
        out.put(34)
        count += 1
        i = json.toks[i].next
    out.put(125)  # }
    return count


# --- rendering rows ----------------------------------------------------------------------------------------


@inline(.always)
def col(res: Results, idx: Int, mut n: Int) -> BytePtr:
    return res.column(idx, n)


def put_col_str(mut out: ByteBuf, res: Results, idx: Int):
    var n = 0
    var p = res.column(idx, n)
    put_json_str_or_null(out, p, n)


def put_col_raw(mut out: ByteBuf, res: Results, idx: Int):
    """A column written as is (integers)."""
    var n = 0
    var p = res.column(idx, n)
    out.put_bytes(p, n)


def put_col_bool(mut out: ByteBuf, res: Results, idx: Int):
    out.put_str("true" if res.column_bool(idx) else "false")


def put_col_time(mut out: ByteBuf, res: Results, idx: Int):
    var n = 0
    var p = res.column(idx, n)
    put_timestamp(out, p, n)


def put_profile_fields(mut out: ByteBuf, res: Results, username: Int):
    """"username":..,"bio":..,"image":.. from columns username, username+1, username+2."""
    out.put_str('"username":')
    put_col_str(out, res, username)
    out.put_str(',"bio":')
    put_col_str(out, res, username + 1)
    out.put_str(',"image":')
    put_col_str(out, res, username + 2)


def put_pg_array(mut out: ByteBuf, p: BytePtr, n: Int, mut scratch: ByteBuf):
    """A Postgres text[] in text form ({a,"b c"}) as a JSON array of strings, in the same order."""
    out.put(91)  # [
    var i = 1  # past '{'
    var first = True
    while i < n - 1:
        if not first:
            out.put(44)
        first = False
        if p[unsafe_offset=i] == 34:  # quoted: backslash escapes inside
            scratch.len = 0
            i += 1
            while i < n and p[unsafe_offset=i] != 34:
                if p[unsafe_offset=i] == 92 and i + 1 < n:
                    i += 1
                scratch.put(p[unsafe_offset=i])
                i += 1
            i += 1  # closing quote
            put_json_str(out, scratch.ptr, scratch.len)
        else:
            var s = i
            while i < n - 1 and p[unsafe_offset=i] != 44:
                i += 1
            put_json_str(out, p.unsafe_offset(s), i - s)
        i += 1  # the comma
    out.put(93)  # ]


def put_article(mut out: ByteBuf, res: Results, full: Bool, mut scratch: ByteBuf):
    """An Article object from an ARTICLE_LIST_SELECT row, or an ARTICLE_FULL_SELECT row with `full`."""
    var b = 1 if full else 0  # columns after description shift by one when body is there
    out.put_str('{"slug":')
    put_col_str(out, res, 1)
    out.put_str(',"title":')
    put_col_str(out, res, 2)
    out.put_str(',"description":')
    put_col_str(out, res, 3)
    if full:
        out.put_str(',"body":')
        put_col_str(out, res, 4)
    out.put_str(',"tagList":')
    var n = 0
    var tags = res.column(6 + b, n)
    put_pg_array(out, tags, n, scratch)
    out.put_str(',"createdAt":')
    put_col_time(out, res, 4 + b)
    out.put_str(',"updatedAt":')
    put_col_time(out, res, 5 + b)
    out.put_str(',"favorited":')
    put_col_bool(out, res, 8 + b)
    out.put_str(',"favoritesCount":')
    put_col_raw(out, res, 7 + b)
    out.put_str(',"author":{')
    put_profile_fields(out, res, 9 + b)
    out.put_str(',"following":')
    put_col_bool(out, res, 12 + b)
    out.put_str("}}")


def put_comment(mut out: ByteBuf, res: Results, following_col: Int):
    """A Comment from (id, body, created_at, updated_at, username, bio, image[, following]); following_col -1
    means false."""
    out.put_str('{"id":')
    put_col_raw(out, res, 0)
    out.put_str(',"createdAt":')
    put_col_time(out, res, 2)
    out.put_str(',"updatedAt":')
    put_col_time(out, res, 3)
    out.put_str(',"body":')
    put_col_str(out, res, 1)
    out.put_str(',"author":{')
    put_profile_fields(out, res, 4)
    out.put_str(',"following":')
    if following_col < 0:
        out.put_str("false")
    else:
        put_col_bool(out, res, following_col)
    out.put_str("}}")


def db_error(mut w: Worker, fd: Int, state: Int):
    """Unique violations and bad input (SQLSTATE classes 23 and 22) are the client's fault: 422."""
    # The packed SQLSTATE has its first character at bits 32..39 (see pg.sqlstate).
    var c0 = (state >> 32) & 0xFF
    var c1 = (state >> 24) & 0xFF
    var keep = w.conn(fd).keep_alive
    if c0 == 0x32 and (c1 == 0x33 or c1 == 0x32):  # "23..." or "22..."
        error_response(w.out, 422, keep, "already taken or invalid")
    else:
        error_response(w.out, 500, keep, "database error")
