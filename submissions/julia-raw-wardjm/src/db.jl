# Queues, dispatch and Postgres callbacks.
#
# Reads: requests wait in their kind's queue. Whenever a read connection has room (fewer than READ_DEPTH units in
# flight), the kind whose oldest request has waited longest sends everything it has queued (up to its max batch)
# as one statement. No timer: at low load a batch is one request and nothing waits; under load batches grow by
# themselves while the connections are busy.
#
# Writes go to connections of their own, so a read never queues behind a commit's WAL flush.

const READ_DEPTH = Ref(1)
const WRITE_DEPTH = Ref(2)

# ---------------- queues ----------------

function enqueue!(lp::Loop, kid::Int, r::Req)
    k = @inbounds lp.kinds[kid]
    lp.seq += 1
    r.seq = lp.seq
    if k.qlen == length(k.q)
        old = k.q
        n = length(old)
        new = Vector{Req}(undef, 2n)
        for j in 0:n-1
            new[j+1] = old[mod1(k.qhead + j, n)]
        end
        k.q = new
        k.qhead = 1
    end
    @inbounds k.q[mod1(k.qhead + k.qlen, length(k.q))] = r
    k.qlen += 1
    nothing
end

function write_submit!(lp::Loop, r::Req)
    if lp.wqlen == length(lp.wq)
        old = lp.wq
        n = length(old)
        new = Vector{Req}(undef, 2n)
        for j in 0:n-1
            new[j+1] = old[mod1(lp.wqhead + j, n)]
        end
        lp.wq = new
        lp.wqhead = 1
    end
    @inbounds lp.wq[mod1(lp.wqhead + lp.wqlen, length(lp.wq))] = r
    lp.wqlen += 1
    nothing
end

function take_batch!(k::Kind)
    b = isempty(k.free) ? Batch(k, Vector{Req}(undef, k.maxbatch), 0) : pop!(k.free)::Batch
    n = min(k.qlen, k.maxbatch)
    q = k.q
    @inbounds for j in 1:n
        b.items[j] = q[k.qhead]
        k.qhead = k.qhead == length(q) ? 1 : k.qhead + 1
    end
    k.qlen -= n
    b.n = n
    k.inflight += 1
    b
end

function pump_reads!(lp::Loop)
    depth = READ_DEPTH[]
    for c in lp.reads
        c.broken && continue
        while c.ulen < depth
            best = 0
            oldest = typemax(Int)
            @inbounds for kid in 1:NKINDS
                k = lp.kinds[kid]
                if k.qlen > 0 && k.inflight < k.maxinflight
                    s = k.q[k.qhead].seq
                    if s < oldest
                        oldest = s
                        best = kid
                    end
                end
            end
            best == 0 && return
            b = take_batch!(lp.kinds[best])
            encode_batch!(c.wbuf, b)
            push_unit!(c, b)
        end
    end
end

function pump_writes!(lp::Loop)
    depth = WRITE_DEPTH[]
    while lp.wqlen > 0
        best = nothing
        bl = depth
        for c in lp.writes
            if !c.broken && c.ulen < bl
                bl = c.ulen
                best = c
            end
        end
        best === nothing && return
        r = @inbounds lp.wq[lp.wqhead]
        lp.wqhead = lp.wqhead == length(lp.wq) ? 1 : lp.wqhead + 1
        lp.wqlen -= 1
        r.nstmt = 0
        r.rows = 0
        r.sqlstate = 0
        encode_write!(best.wbuf, r)
        push_unit!(best, r)
    end
end

# ---------------- encoding ----------------

function encode_batch!(w::Buf, b::Batch)
    k = b.kind
    l = k.layout
    n = b.n
    it = b.items
    np = l == L_NONE ? 1 : l == L_VIEWER ? 2 : l == L_VKEY ? 3 : l == L_LIST ? 4 : l == L_LISTKEY ? 5 : 2
    p = bind_begin!(w, k.stmt, np)
    a = p_arr_begin!(w, OID_INT4)
    for j in 0:n-1
        a_int4!(w, j)
    end
    p_arr_end!(w, a, n)
    if l != L_NONE && l != L_KEY
        a = p_arr_begin!(w, OID_INT8)
        @inbounds for j in 1:n
            a_int8!(w, it[j].viewer)
        end
        p_arr_end!(w, a, n)
    end
    if l == L_LIST || l == L_LISTKEY
        a = p_arr_begin!(w, OID_INT4)
        @inbounds for j in 1:n
            a_int4!(w, it[j].limit)
        end
        p_arr_end!(w, a, n)
        a = p_arr_begin!(w, OID_INT8)
        @inbounds for j in 1:n
            a_int8!(w, it[j].offset)
        end
        p_arr_end!(w, a, n)
    end
    if l == L_VKEY || l == L_LISTKEY || l == L_KEY
        a = p_arr_begin!(w, OID_TEXT)
        @inbounds for j in 1:n
            r = it[j]
            a_text!(w, r.arena.data, r.key_off, r.key_len)
        end
        p_arr_end!(w, a, n)
    end
    bind_end!(w, p)
    wr_sync!(w)
end

@inline p_field!(w::Buf, r::Req, k::Int) =
    r.f.state[k] == F_STR ? p_text!(w, r.arena.data, r.f.off[k], r.f.len[k]) : p_null!(w)
@inline p_key!(w::Buf, r::Req) = p_text!(w, r.arena.data, r.key_off, r.key_len)

function p_tags!(w::Buf, r::Req)
    f = r.f
    a = p_arr_begin!(w, OID_TEXT)
    for j in 1:f.ntags
        a_text!(w, r.arena.data, f.toff[j], f.tlen[j])
    end
    p_arr_end!(w, a, f.ntags)
end

function encode_write!(w::Buf, r::Req)
    route = r.route
    v = r.viewer
    if route == R_REGISTER
        p = bind_begin!(w, S_USER_INSERT, 3)
        p_field!(w, r, 1)
        p_field!(w, r, 2)
        p_text!(w, r.arena.data, r.hash_off, r.hash_len)
        bind_end!(w, p)
    elseif route == R_USER_PUT
        p = bind_begin!(w, S_USER_UPDATE, 6)
        p_int8!(w, v)
        p_field!(w, r, 1)
        p_field!(w, r, 2)
        r.hash_len > 0 ? p_text!(w, r.arena.data, r.hash_off, r.hash_len) : p_null!(w)
        p_field!(w, r, 4)
        p_field!(w, r, 5)
        bind_end!(w, p)
    elseif route == R_FOLLOW || route == R_UNFOLLOW
        p = bind_begin!(w, route == R_FOLLOW ? S_FOLLOW : S_UNFOLLOW, 2)
        p_int8!(w, v)
        p_key!(w, r)
        bind_end!(w, p)
    elseif route == R_FAV || route == R_UNFAV
        p = bind_begin!(w, route == R_FAV ? S_FAV_INSERT : S_FAV_DELETE, 2)
        p_int8!(w, v)
        p_key!(w, r)
        bind_end!(w, p)
        p = bind_begin!(w, S_ARTICLE_BY_SLUG, 2)
        p_int8!(w, v)
        p_key!(w, r)
        bind_end!(w, p)
    elseif route == R_COMMENT_POST
        p = bind_begin!(w, S_COMMENT_INSERT, 3)
        p_int8!(w, v)
        p_key!(w, r)
        p_field!(w, r, 1)
        bind_end!(w, p)
    elseif route == R_ARTICLE_POST
        p = bind_begin!(w, S_ARTICLE_INSERT, 5)
        p_int8!(w, v)
        p_text!(w, r.arena.data, r.pfx_off, r.pfx_len)
        p_field!(w, r, 1)
        p_field!(w, r, 2)
        p_field!(w, r, 3)
        bind_end!(w, p)
        if r.f.state[4] == F_ARR && r.f.ntags > 0
            p = bind_begin!(w, S_TAGS_INSERT, 1)
            p_tags!(w, r)
            bind_end!(w, p)
            p = bind_begin!(w, S_ARTICLE_TAGS_INSERT, 1)
            p_tags!(w, r)
            bind_end!(w, p)
        end
        p = bind_begin!(w, S_ARTICLE_BY_CURRVAL, 1)
        p_int8!(w, v)
        bind_end!(w, p)
    elseif route == R_ARTICLE_PUT && r.step == 1
        p = bind_begin!(w, S_ARTICLE_UPDATE, 6)
        p_int8!(w, v)
        p_key!(w, r)
        p_field!(w, r, 1)
        p_field!(w, r, 2)
        p_field!(w, r, 3)
        r.pfx_len >= 0 ? p_text!(w, r.arena.data, r.pfx_off, r.pfx_len) : p_null!(w)
        bind_end!(w, p)
    elseif route == R_ARTICLE_DELETE && r.step == 1
        p = bind_begin!(w, S_ARTICLE_DELETE, 2)
        p_key!(w, r)
        p_int8!(w, v)
        bind_end!(w, p)
    elseif (route == R_ARTICLE_PUT || route == R_ARTICLE_DELETE) && r.step == 2
        p = bind_begin!(w, S_ARTICLE_AUTHOR, 1)
        p_key!(w, r)
        bind_end!(w, p)
    elseif route == R_COMMENT_DELETE && r.step == 1
        p = bind_begin!(w, S_COMMENT_DELETE, 3)
        p_int8!(w, r.id)
        p_key!(w, r)
        p_int8!(w, v)
        bind_end!(w, p)
    elseif route == R_COMMENT_DELETE && r.step == 2
        p = bind_begin!(w, S_COMMENT_AUTHOR, 2)
        p_int8!(w, r.id)
        p_key!(w, r)
        bind_end!(w, p)
    else
        error("no write for route $route step $(r.step)")
    end
    wr_sync!(w)
end

# ---------------- callbacks ----------------

function on_row(lp::Loop, c::PgConn, u)
    if u isa Batch
        i = Int(col_i32(c, 1))
        (i < 0 || i >= u.n) && return
        batch_row!(lp, c, u.kind.id, @inbounds u.items[i+1])
    else
        single_row!(lp, c, u::Req)
    end
end

function on_complete(lp::Loop, c::PgConn, u, off::Int, n::Int)
    u isa Req || return
    r = u::Req
    r.nstmt += 1
    # "DELETE <n>": rows deleted
    v = c.rbuf
    if n > 7 && bytes_eq(v, off, 7, "DELETE ")
        r.count = parse_id(v, off + 7, n - 7)
    end
end

function on_error(lp::Loop, c::PgConn, u, code::UInt64)
    if u isa Batch
        for j in 1:u.n
            r = u.items[j]
            r.sqlstate == 0 && (r.sqlstate = code)
        end
    else
        r = u::Req
        r.sqlstate == 0 && (r.sqlstate = code)
    end
end

function on_ready(lp::Loop, c::PgConn, u)
    if u isa Batch
        b = u::Batch
        k = b.kind
        k.inflight -= 1
        for j in 1:b.n
            r = b.items[j]
            try
                batch_done!(lp, k.id, r)
            catch e
                @error "batch completion" exception = (e, catch_backtrace())
                respond_error!(lp, r, 500, "internal error")
            end
        end
        b.n = 0
        push!(k.free, b)
    else
        r = u::Req
        try
            single_done!(lp, r)
        catch e
            @error "write completion" exception = (e, catch_backtrace())
            respond_error!(lp, r, 500, "internal error")
        end
    end
end

# ---------------- batched reads ----------------

function batch_row!(lp::Loop, c::PgConn, kid::Int, r::Req)
    r.sqlstate != 0 && return
    b = r.out
    if kid == K_ARTICLE
        r.rows += 1
        wr!(b, "{\"article\":")
        wr_article!(lp, b, c, 2, true)
        wr!(b, UInt8('}'))
    elseif kid == K_COMMENTS
        # i, a.id, comment id, body, created, updated, username, bio, image, following
        r.rows == 0 && wr!(b, "{\"comments\":[")
        r.rows += 1
        if !col_null(c, 3)
            r.count > 0 && wr!(b, UInt8(','))
            r.count += 1
            wr_comment!(b, c, 3, col_bool(c, 10))
        end
    elseif kid == K_TAGS
        r.rows += 1
        wr!(b, "{\"tags\":")
        wr_tags_plain!(b, c, 2)
        wr!(b, UInt8('}'))
    elseif kid == K_PROFILE
        r.rows += 1
        wr_profile!(b, c, 2, col_bool(c, 5))
    elseif kid == K_USER
        r.rows += 1
        wr_user!(lp, r, c, 2, false)
    elseif kid == K_LOGIN
        # i, id, username, email, bio, image, password_hash
        r.rows += 1
        r.id = col_i64(c, 2)
        wr_user!(lp, r, c, 2, true)
        a = r.arena
        r.hash_off = a.len
        r.hash_len = c.clen[7]
        wr!(a, c.rbuf, c.coff[7], c.clen[7])
    else
        # lists: i, count, article columns (NULL on an empty page)
        if r.rows == 0
            r.count = col_i64(c, 2)
            wr!(b, "{\"articles\":[")
        end
        r.rows += 1
        if !col_null(c, 3)
            r.flag && wr!(b, UInt8(','))
            r.flag = true
            wr_article!(lp, b, c, 3, false)
        end
    end
    nothing
end

# the tag list is already sorted by Postgres (ORDER BY name)
function wr_tags_plain!(b::Buf, c::PgConn, k::Int)
    off = c.coff[k]
    v = c.rbuf
    wr!(b, UInt8('['))
    if c.clen[k] >= 12 && load_be(Int32, v, off) > 0
        n = Int(load_be(Int32, v, off + 12))
        p = off + 20
        for j in 1:n
            l = Int(load_be(Int32, v, p))
            p += 4
            j > 1 && wr!(b, UInt8(','))
            wr_jstr!(b, v, p, l)
            p += max(l, 0)
        end
    end
    wr!(b, UInt8(']'))
end

function batch_done!(lp::Loop, kid::Int, r::Req)
    if r.sqlstate != 0
        return respond_error!(lp, r, 500, "database error")
    end
    if kid == K_ARTICLE || kid == K_PROFILE || kid == K_TAGS
        r.rows == 0 && return respond_error!(lp, r, 404, "not found")
        respond!(lp, r, 200)
    elseif kid == K_COMMENTS
        r.rows == 0 && return respond_error!(lp, r, 404, "article not found")
        wr!(r.out, "]}")
        respond!(lp, r, 200)
    elseif kid == K_USER
        r.rows == 0 && return respond_error!(lp, r, 401, "user not found")
        respond!(lp, r, 200)
    elseif kid == K_LOGIN
        r.rows == 0 && return respond_error!(lp, r, 401, "invalid email or password")
        r.flag = false # verify
        r.step = 2
        bcrypt_submit(r)
    else
        if r.rows == 0
            wr!(r.out, "{\"articles\":[")
        end
        wr!(r.out, "],\"articlesCount\":")
        put_int!(r.out, r.count)
        wr!(r.out, UInt8('}'))
        respond!(lp, r, 200)
    end
end

# ---------------- writes ----------------

function single_row!(lp::Loop, c::PgConn, r::Req)
    r.sqlstate != 0 && return
    route = r.route
    b = r.out
    r.rows += 1
    if route == R_REGISTER
        wr_user!(lp, r, c, 1, true)
    elseif route == R_USER_PUT
        wr_user!(lp, r, c, 1, false)
    elseif route == R_FOLLOW || route == R_UNFOLLOW
        wr_profile!(b, c, 1, route == R_FOLLOW)
    elseif route == R_FAV || route == R_UNFAV || route == R_ARTICLE_POST || (route == R_ARTICLE_PUT && r.step == 1)
        wr!(b, "{\"article\":")
        wr_article!(lp, b, c, 1, true)
        wr!(b, UInt8('}'))
    elseif route == R_COMMENT_POST
        wr!(b, "{\"comment\":")
        wr_comment!(b, c, 1, false)
        wr!(b, UInt8('}'))
    else
        # author checks
        r.count = col_i64(c, 1) # author_id
    end
    nothing
end

function single_done!(lp::Loop, r::Req)
    route = r.route
    st = r.sqlstate
    if st != 0
        if st == SQL_UNIQUE
            return respond_error!(lp, r, 422, "username or email is already taken")
        elseif st == SQL_FK
            return respond_error!(lp, r, 404, "not found")
        end
        return respond_error!(lp, r, 500, "database error")
    end
    if route == R_REGISTER
        r.rows == 0 && return respond_error!(lp, r, 500, "insert returned nothing")
        respond!(lp, r, 201)
    elseif route == R_USER_PUT
        r.rows == 0 && return respond_error!(lp, r, 401, "user not found")
        respond!(lp, r, 200)
    elseif route == R_FOLLOW || route == R_UNFOLLOW
        r.rows == 0 && return respond_error!(lp, r, 404, "profile not found")
        respond!(lp, r, 200)
    elseif route == R_FAV || route == R_UNFAV
        r.rows == 0 && return respond_error!(lp, r, 404, "article not found")
        respond!(lp, r, 200)
    elseif route == R_COMMENT_POST
        r.rows == 0 && return respond_error!(lp, r, 404, "article not found")
        respond!(lp, r, 201)
    elseif route == R_ARTICLE_POST
        r.rows == 0 && return respond_error!(lp, r, 500, "insert returned nothing")
        respond!(lp, r, 201)
    elseif r.step == 1 && route == R_ARTICLE_PUT
        r.rows > 0 && return respond!(lp, r, 200)
        r.step = 2
        write_submit!(lp, r)
    elseif r.step == 1 # article / comment delete
        r.count > 0 && return respond!(lp, r, 204)
        r.step = 2
        write_submit!(lp, r)
    else
        # step 2: why didn't it match? no row = 404, someone else's = 403
        r.rows == 0 && return respond_error!(lp, r, 404, "not found")
        r.count != r.viewer && return respond_error!(lp, r, 403, "not the author")
        # ours after all: it changed between the two statements
        respond_error!(lp, r, 404, "not found")
    end
end

# ---------------- bcrypt results ----------------

function bcrypt_done!(lp::Loop, r::Req)
    if r.route == R_LOGIN
        r.bcrypt_ok || return respond_error!(lp, r, 401, "invalid email or password")
        respond!(lp, r, 200)
    else
        (r.bcrypt_ok && r.hash_len > 0) || return respond_error!(lp, r, 500, "hashing failed")
        r.step = 2
        write_submit!(lp, r)
    end
end
