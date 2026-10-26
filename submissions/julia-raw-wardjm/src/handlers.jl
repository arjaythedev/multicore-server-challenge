# Routing, authentication, validation, and starting each endpoint's database work.

const R_TAGS = 1
const R_REGISTER = 2
const R_LOGIN = 3
const R_USER_GET = 4
const R_USER_PUT = 5
const R_PROFILE = 6
const R_FOLLOW = 7
const R_UNFOLLOW = 8
const R_LIST = 9
const R_FEED = 10
const R_ARTICLE_GET = 11
const R_ARTICLE_POST = 12
const R_ARTICLE_PUT = 13
const R_ARTICLE_DELETE = 14
const R_FAV = 15
const R_UNFAV = 16
const R_COMMENTS_GET = 17
const R_COMMENT_POST = 18
const R_COMMENT_DELETE = 19

# batched read kinds (ids = their statement ids)
const K_TAGS = S_TAGS
const K_ARTICLE = S_ARTICLE
const K_COMMENTS = S_COMMENTS
const K_PROFILE = S_PROFILE
const K_USER = S_USER
const K_LIST_ALL = S_LIST_ALL
const K_LIST_TAG = S_LIST_TAG
const K_LIST_AUTHOR = S_LIST_AUTHOR
const K_LIST_FAV = S_LIST_FAV
const K_FEED = S_FEED
const K_LOGIN = S_LOGIN
const NKINDS = 11
const KIND_LAYOUT = [L_NONE, L_VKEY, L_VKEY, L_VKEY, L_VIEWER, L_LIST, L_LISTKEY, L_LISTKEY, L_LISTKEY, L_LIST, L_KEY]

const JWT_KEY = Ref{HmacKey}()

# request body field lists
const F_USER_REGISTER = ["username", "email", "password"]
const F_USER_LOGIN = ["email", "password"]
const F_USER_UPDATE = ["email", "username", "password", "bio", "image"]
const F_ARTICLE_CREATE = ["title", "description", "body", "tagList"]
const F_ARTICLE_UPDATE = ["title", "description", "body"]
const F_COMMENT = ["body"]

# percent-decodes v[off, off+n) onto the arena ('+' as space when `plus`); returns the arena offset
function decode_into!(a::Buf, v::Vector{UInt8}, off::Int, n::Int, plus::Bool)
    start = a.len
    reserve!(a, n)
    i = off + 1
    stop = off + n
    @inbounds while i <= stop
        c = v[i]
        if c == UInt8('%') && i + 2 <= stop && hexval(v[i+1]) >= 0 && hexval(v[i+2]) >= 0
            wr!(a, UInt8(hexval(v[i+1]) * 16 + hexval(v[i+2])))
            i += 3
        else
            wr!(a, plus && c == UInt8('+') ? UInt8(' ') : c)
            i += 1
        end
    end
    start
end

# the Authorization header -> viewer id: 0 = no header, -1 = present but invalid
function authenticate(lp::Loop, v::Vector{UInt8}, aoff::Int, alen::Int)
    aoff < 0 && return Int64(0)
    (alen > 6 && bytes_eq(v, aoff, 6, "Token ")) || return Int64(-1)
    jwt_verify(lp.jwt, JWT_KEY[], v, aoff + 6, alen - 6, lp.now)
end

# "limit"/"offset" value at arena[off, off+n): digits only -> value, or -1
function parse_uint(a::Vector{UInt8}, off::Int, n::Int)
    (n <= 0 || n > 18) && return Int64(-1)
    x = Int64(0)
    @inbounds for k in off+1:off+n
        c = a[k]
        (c < UInt8('0') || c > UInt8('9')) && return Int64(-1)
        x = x * 10 + (c - UInt8('0'))
    end
    x
end

# list query: sets limit/offset and the filter (key + kind in r.step); false = 422
function parse_list_query!(r::Req, v::Vector{UInt8}, qoff::Int, qend::Int, feed::Bool)
    a = r.arena
    kind = feed ? K_FEED : K_LIST_ALL
    prio = 4 # tag 1, author 2, favorited 3
    i = qoff
    while i < qend
        j = i
        while j < qend && v[j+1] != UInt8('&')
            j += 1
        end
        # pair v[i, j)
        eq = i
        while eq < j && v[eq+1] != UInt8('=')
            eq += 1
        end
        klen = eq - i
        voff = eq < j ? eq + 1 : j
        vlen = j - voff
        if klen == 5 && bytes_eq(v, i, 5, "limit")
            s = decode_into!(a, v, voff, vlen, true)
            x = parse_uint(a.data, s, a.len - s)
            (x < 1 || x > 100) && return false
            r.limit = Int32(x)
        elseif klen == 6 && bytes_eq(v, i, 6, "offset")
            s = decode_into!(a, v, voff, vlen, true)
            x = parse_uint(a.data, s, a.len - s)
            x < 0 && return false
            r.offset = min(x, Int64(1) << 40) # past every row either way; keeps limit + offset in range
        elseif !feed && vlen > 0
            p = klen == 3 && bytes_eq(v, i, 3, "tag") ? 1 :
                klen == 6 && bytes_eq(v, i, 6, "author") ? 2 :
                klen == 9 && bytes_eq(v, i, 9, "favorited") ? 3 : 0
            if p > 0 && p < prio
                s = decode_into!(a, v, voff, vlen, true)
                if a.len > s
                    prio = p
                    r.key_off = s
                    r.key_len = a.len - s
                    kind = p == 1 ? K_LIST_TAG : p == 2 ? K_LIST_AUTHOR : K_LIST_FAV
                end
            end
        end
        i = j + 1
    end
    r.step = kind
    true
end

# slugify: runs of anything but [A-Za-z0-9] become '-', lowercased, '-' trimmed; then "-" for the id
function slug_prefix!(r::Req, toff::Int, tlen::Int)
    a = r.arena
    start = a.len
    reserve!(a, tlen + 1)
    dash = false
    @inbounds for k in toff+1:toff+tlen
        c = a.data[k]
        if (UInt8('a') <= c <= UInt8('z')) || (UInt8('0') <= c <= UInt8('9'))
            dash && a.len > start && wr!(a, UInt8('-'))
            dash = false
            wr!(a, c)
        elseif UInt8('A') <= c <= UInt8('Z')
            dash && a.len > start && wr!(a, UInt8('-'))
            dash = false
            wr!(a, c + 0x20)
        else
            dash = true
        end
    end
    wr!(a, UInt8('-'))
    r.pfx_off = start
    r.pfx_len = a.len - start
    nothing
end

const SEG_MAX = 6

function handle!(lp::Loop, r::Req, v::Vector{UInt8}, method::Int, t0::Int, tlen::Int, aoff::Int, alen::Int,
    boff::Int, blen::Int)
    tend = t0 + tlen
    q = t0
    while q < tend && v[q+1] != UInt8('?')
        q += 1
    end
    # segments of the path v[t0, q): "/api/..."
    (q - t0 >= 5 && bytes_eq(v, t0, 5, "/api/")) || return respond_error!(lp, r, 404, "not found")
    so = lp.tagoff # scratch (reused by rendering later, not concurrently)
    sl = lp.taglen
    n = 0
    i = t0 + 5
    while true
        j = i
        while j < q && v[j+1] != UInt8('/')
            j += 1
        end
        n += 1
        n > SEG_MAX && return respond_error!(lp, r, 404, "not found")
        so[n] = i
        sl[n] = j - i
        j >= q && break
        i = j + 1
    end
    s1o, s1l = so[1], sl[1]
    route = 0
    k2o = k2l = k3o = k3l = 0
    n >= 2 && (k2o = so[2]; k2l = sl[2])
    n >= 3 && (k3o = so[3]; k3l = sl[3])
    if s1l == 8 && bytes_eq(v, s1o, 8, "articles")
        if n == 1
            route = method == M_GET ? R_LIST : method == M_POST ? R_ARTICLE_POST : 0
        elseif k2l == 0
            route = 0
        elseif n == 2
            if k2l == 4 && bytes_eq(v, k2o, 4, "feed") && method == M_GET
                route = R_FEED
            else
                route = method == M_GET ? R_ARTICLE_GET : method == M_PUT ? R_ARTICLE_PUT :
                        method == M_DELETE ? R_ARTICLE_DELETE : 0
            end
        elseif n == 3 && k3l == 8 && bytes_eq(v, k3o, 8, "favorite")
            route = method == M_POST ? R_FAV : method == M_DELETE ? R_UNFAV : 0
        elseif n == 3 && k3l == 8 && bytes_eq(v, k3o, 8, "comments")
            route = method == M_GET ? R_COMMENTS_GET : method == M_POST ? R_COMMENT_POST : 0
        elseif n == 4 && k3l == 8 && bytes_eq(v, k3o, 8, "comments") && method == M_DELETE
            route = R_COMMENT_DELETE
        end
    elseif s1l == 4 && bytes_eq(v, s1o, 4, "tags")
        n == 1 && method == M_GET && (route = R_TAGS)
    elseif s1l == 4 && bytes_eq(v, s1o, 4, "user")
        n == 1 && (route = method == M_GET ? R_USER_GET : method == M_PUT ? R_USER_PUT : 0)
    elseif s1l == 5 && bytes_eq(v, s1o, 5, "users")
        if n == 1 && method == M_POST
            route = R_REGISTER
        elseif n == 2 && method == M_POST && k2l == 5 && bytes_eq(v, k2o, 5, "login")
            route = R_LOGIN
        end
    elseif s1l == 8 && bytes_eq(v, s1o, 8, "profiles") && k2l > 0
        if n == 2 && method == M_GET
            route = R_PROFILE
        elseif n == 3 && k3l == 6 && bytes_eq(v, k3o, 6, "follow")
            route = method == M_POST ? R_FOLLOW : method == M_DELETE ? R_UNFOLLOW : 0
        end
    end
    route == 0 && return respond_error!(lp, r, 404, "not found")
    r.route = route
    a = r.arena
    if route == R_COMMENT_DELETE
        s = decode_into!(a, v, so[4], sl[4], false)
        r.id = parse_id(a.data, s, a.len - s)
        a.len = s
    end
    # path key: slug or username
    if route != R_TAGS && route != R_REGISTER && route != R_LOGIN && route != R_USER_GET && route != R_USER_PUT &&
       route != R_LIST && route != R_FEED && route != R_ARTICLE_POST
        r.key_off = decode_into!(a, v, k2o, k2l, false)
        r.key_len = a.len - r.key_off
    end

    # auth: tags, register and login ignore the header
    if route != R_TAGS && route != R_REGISTER && route != R_LOGIN
        viewer = authenticate(lp, v, aoff, alen)
        viewer < 0 && return respond_error!(lp, r, 401, "invalid token")
        optional = route == R_PROFILE || route == R_LIST || route == R_ARTICLE_GET || route == R_COMMENTS_GET
        viewer == 0 && !optional && return respond_error!(lp, r, 401, "authentication required")
        r.viewer = viewer
        if route == R_USER_GET || route == R_USER_PUT
            r.tok_off = a.len
            wr!(a, v, aoff + 6, alen - 6)
            r.tok_len = alen - 6
        end
    end

    f = r.f
    bstop = boff + blen # 0-based exclusive -> 1-based inclusive stop is the same number
    if route == R_TAGS
        enqueue!(lp, K_TAGS, r)
    elseif route == R_ARTICLE_GET
        enqueue!(lp, K_ARTICLE, r)
    elseif route == R_COMMENTS_GET
        enqueue!(lp, K_COMMENTS, r)
    elseif route == R_PROFILE
        enqueue!(lp, K_PROFILE, r)
    elseif route == R_USER_GET
        enqueue!(lp, K_USER, r)
    elseif route == R_LIST || route == R_FEED
        parse_list_query!(r, v, q + 1, tend, route == R_FEED) || return respond_error!(lp, r, 422, "invalid limit or offset")
        enqueue!(lp, r.step, r)
    elseif route == R_LOGIN
        (parse_body!(f, a, v, boff + 1, bstop, "user", F_USER_LOGIN) && fnonempty(f, 1) && fnonempty(f, 2)) ||
            return respond_error!(lp, r, 422, "email and password are required")
        r.key_off, r.key_len = f.off[1], f.len[1]
        r.pw_off, r.pw_len = f.off[2], f.len[2]
        enqueue!(lp, K_LOGIN, r)
    elseif route == R_REGISTER
        (parse_body!(f, a, v, boff + 1, bstop, "user", F_USER_REGISTER) && fnonempty(f, 1) && fnonempty(f, 2) &&
         fnonempty(f, 3)) || return respond_error!(lp, r, 422, "username, email and password are required")
        f.len[3] > 72 && return respond_error!(lp, r, 422, "password is longer than 72 bytes")
        r.pw_off, r.pw_len = f.off[3], f.len[3]
        r.flag = true # hash
        r.step = 1
        bcrypt_submit(r)
    elseif route == R_USER_PUT
        ok = parse_body!(f, a, v, boff + 1, bstop, "user", F_USER_UPDATE)
        if ok
            for k in 1:5
                f.state[k] == F_BAD && (ok = false)
            end
            for k in 1:3 # email, username, password can't be empty
                f.state[k] == F_STR && f.len[k] == 0 && (ok = false)
            end
            f.state[3] == F_STR && f.len[3] > 72 && (ok = false)
        end
        ok || return respond_error!(lp, r, 422, "invalid user")
        if f.state[3] == F_STR
            r.pw_off, r.pw_len = f.off[3], f.len[3]
            r.flag = true
            r.step = 1
            bcrypt_submit(r)
        else
            r.hash_len = -1
            r.step = 2
            write_submit!(lp, r)
        end
    elseif route == R_FOLLOW || route == R_UNFOLLOW || route == R_FAV || route == R_UNFAV || route == R_ARTICLE_DELETE
        r.step = 1
        write_submit!(lp, r)
    elseif route == R_COMMENT_DELETE
        r.id < 0 && return respond_error!(lp, r, 404, "comment not found")
        r.step = 1
        write_submit!(lp, r)
    elseif route == R_COMMENT_POST
        (parse_body!(f, a, v, boff + 1, bstop, "comment", F_COMMENT) && fnonempty(f, 1)) ||
            return respond_error!(lp, r, 422, "body is required")
        r.step = 1
        write_submit!(lp, r)
    elseif route == R_ARTICLE_POST
        ok = parse_body!(f, a, v, boff + 1, bstop, "article", F_ARTICLE_CREATE, 4) && fnonempty(f, 1) &&
             fnonempty(f, 2) && fnonempty(f, 3) && f.state[4] != F_BAD && f.state[4] != F_STR
        ok || return respond_error!(lp, r, 422, "title, description and body are required")
        slug_prefix!(r, f.off[1], f.len[1])
        r.step = 1
        write_submit!(lp, r)
    elseif route == R_ARTICLE_PUT
        ok = parse_body!(f, a, v, boff + 1, bstop, "article", F_ARTICLE_UPDATE)
        if ok
            for k in 1:3
                (f.state[k] == F_BAD || (f.state[k] == F_STR && f.len[k] == 0)) && (ok = false)
            end
        end
        ok || return respond_error!(lp, r, 422, "invalid article")
        fstr(f, 1) && slug_prefix!(r, f.off[1], f.len[1])
        r.step = 1
        write_submit!(lp, r)
    end
    nothing
end
