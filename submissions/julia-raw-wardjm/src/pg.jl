# PostgreSQL wire protocol 3.0. Connecting, authenticating (SCRAM-SHA-256, cleartext or trust) and preparing
# statements happen at startup on a blocking socket. After that a connection is non-blocking, lives in its loop's
# epoll set, and carries pipelined Bind/Execute.../Sync units. Every parameter and every result column is binary.

const OID_INT4 = UInt32(23)
const OID_INT8 = UInt32(20)
const OID_TEXT = UInt32(25)
const OID_INT4ARR = UInt32(1007)
const OID_INT8ARR = UInt32(1016)
const OID_TEXTARR = UInt32(1009)

struct DbConfig
    ip::UInt32
    port::Int
    user::String
    password::String
    database::String
end

function percent_decode(s::AbstractString)
    out = UInt8[]
    cu = codeunits(s)
    i = 1
    while i <= length(cu)
        if cu[i] == UInt8('%') && i + 2 <= length(cu)
            push!(out, parse(UInt8, String(cu[i+1:i+2]); base=16))
            i += 3
        else
            push!(out, cu[i])
            i += 1
        end
    end
    String(out)
end

function parse_database_url(url::AbstractString)
    m = match(r"^postgres(?:ql)?://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?]*)(?::(\d+))?(?:/([^?]*))?", url)
    m === nothing && error("DATABASE_URL: can't parse $url")
    user = m[1] === nothing ? "postgres" : percent_decode(m[1])
    pass = m[2] === nothing ? "" : percent_decode(m[2])
    host = m[3] === nothing || isempty(m[3]) ? "127.0.0.1" : m[3]
    port = m[4] === nothing ? 5432 : parse(Int, m[4])
    db = m[5] === nothing || isempty(m[5]) ? user : percent_decode(m[5])
    DbConfig(resolve_ipv4(host), port, user, pass, db)
end

# ---------------- message encoding ----------------

@inline function msg_begin!(b::Buf, t::UInt8)
    wr!(b, t)
    p = b.len
    wr!(b, 0x00, 0x00, 0x00, 0x00)
    p
end
@inline msg_end!(b::Buf, p::Int) = patch_be32!(b, p, b.len - p)

@inline function wr!(b::Buf, x1::UInt8, x2::UInt8, x3::UInt8, x4::UInt8)
    reserve!(b, 4)
    @inbounds begin
        b.data[b.len+1] = x1; b.data[b.len+2] = x2; b.data[b.len+3] = x3; b.data[b.len+4] = x4
    end
    b.len += 4
    nothing
end

@inline function wr_cstr!(b::Buf, s::String)
    wr!(b, s)
    wr!(b, 0x00)
end

const STMT_NAMES = [string("s", i) for i in 1:64]

# Bind (unnamed portal, all parameters and results binary). Returns the position for bind_end!.
@inline function bind_begin!(b::Buf, stmt::Int, nparams::Int)
    p = msg_begin!(b, UInt8('B'))
    wr!(b, 0x00)                       # portal ""
    wr_cstr!(b, @inbounds STMT_NAMES[stmt])
    wr_be16_pair!(b, 1, 1)             # one format code: binary
    put_be!(b, Int16(nparams))
    p
end

@inline function wr_be16_pair!(b::Buf, x::Integer, y::Integer)
    put_be!(b, Int16(x))
    put_be!(b, Int16(y))
end

@inline function bind_end!(b::Buf, p::Int)
    wr_be16_pair!(b, 1, 1)             # results: binary
    msg_end!(b, p)
    # Execute "" 0
    wr!(b, UInt8('E'))
    put_be!(b, Int32(9))
    wr!(b, 0x00)
    put_be!(b, Int32(0))
end

@inline function wr_sync!(b::Buf)
    wr!(b, UInt8('S'))
    put_be!(b, Int32(4))
end

@inline function p_int8!(b::Buf, x::Int64)
    put_be!(b, Int32(8))
    put_be!(b, x)
end
@inline function p_int4!(b::Buf, x::Int32)
    put_be!(b, Int32(4))
    put_be!(b, x)
end
@inline p_null!(b::Buf) = put_be!(b, Int32(-1))
@inline function p_text!(b::Buf, v::Vector{UInt8}, off::Int, n::Int)
    put_be!(b, Int32(n))
    wr!(b, v, off, n)
end
@inline function p_text!(b::Buf, s::String)
    put_be!(b, Int32(sizeof(s)))
    wr!(b, s)
end

# a one-dimensional array parameter: begin, then elements, then end with the count
@inline function p_arr_begin!(b::Buf, elem::UInt32)
    p = b.len
    put_be!(b, Int32(0))              # length, patched
    put_be!(b, Int32(1))              # ndim
    put_be!(b, Int32(0))              # has nulls
    put_be!(b, elem)
    put_be!(b, Int32(0))              # dim size, patched
    put_be!(b, Int32(1))              # lower bound
    p
end
@inline function p_arr_end!(b::Buf, p::Int, n::Int)
    patch_be32!(b, p, b.len - p - 4)
    patch_be32!(b, p + 16, n)
end
@inline function a_int4!(b::Buf, x::Integer)
    put_be!(b, Int32(4))
    put_be!(b, Int32(x))
end
@inline function a_int8!(b::Buf, x::Integer)
    put_be!(b, Int32(8))
    put_be!(b, Int64(x))
end
@inline function a_text!(b::Buf, v::Vector{UInt8}, off::Int, n::Int)
    put_be!(b, Int32(n))
    wr!(b, v, off, n)
end

# ---------------- blocking startup ----------------

mutable struct SyncConn
    fd::Cint
    buf::Vector{UInt8}
    len::Int
    pos::Int
end

function sync_send(c::SyncConn, b::Buf)
    off = 0
    GC.@preserve b while off < b.len
        n = send_blocking(c.fd, pointer(b.data, off + 1), b.len - off)
        n <= 0 && error("postgres send failed: errno $(errno())")
        off += n
    end
end

# next message: (type, body bytes)
function sync_recv(c::SyncConn)
    while true
        if c.len - c.pos >= 5
            t = c.buf[c.pos+1]
            l = Int(load_be(Int32, c.buf, c.pos + 1))
            if c.len - c.pos >= 1 + l
                body = c.buf[c.pos+6:c.pos+1+l]
                c.pos += 1 + l
                return t, body
            end
        end
        if c.pos > 0
            copyto!(c.buf, 1, c.buf, c.pos + 1, c.len - c.pos)
            c.len -= c.pos
            c.pos = 0
        end
        c.len == length(c.buf) && resize!(c.buf, 2 * length(c.buf))
        n = GC.@preserve c recv_blocking(c.fd, pointer(c.buf, c.len + 1), length(c.buf) - c.len)
        n <= 0 && error("postgres connection closed during startup")
        c.len += n
    end
end

function pg_error_text(body::Vector{UInt8})
    parts = String[]
    i = 1
    while i <= length(body) && body[i] != 0x00
        f = Char(body[i])
        j = findnext(==(0x00), body, i + 1)
        (f == 'M' || f == 'C' || f == 'D') && push!(parts, "$f=" * String(body[i+1:j-1]))
        i = j + 1
    end
    join(parts, " ")
end

function pbkdf2_sha256(password::Vector{UInt8}, salt::Vector{UInt8}, iters::Int)
    key = HmacKey(password)
    m = Hmac()
    u = zeros(UInt8, 32)
    hmac_start!(m, key)
    msg = vcat(salt, UInt8[0, 0, 0, 1])
    hmac_update!(m, msg, 0, length(msg))
    hmac_final!(m, key, u)
    out = copy(u)
    for _ in 2:iters
        hmac_start!(m, key)
        hmac_update!(m, u, 0, 32)
        hmac_final!(m, key, u)
        out .⊻= u
    end
    out
end

function scram_auth(c::SyncConn, cfg::DbConfig)
    nonce = b64std_encode(rand(UInt8, 18))
    first_bare = "n=,r=" * nonce
    first = "n,," * first_bare
    b = Buf(256)
    p = msg_begin!(b, UInt8('p'))
    wr_cstr!(b, "SCRAM-SHA-256")
    put_be!(b, Int32(sizeof(first)))
    wr!(b, first)
    msg_end!(b, p)
    sync_send(c, b)
    t, body = sync_recv(c)
    t == UInt8('E') && error("postgres auth: " * pg_error_text(body))
    (t == UInt8('R') && load_be(Int32, body, 0) == 11) || error("SCRAM: unexpected message")
    server_first = String(body[5:end])
    attrs = Dict{Char,String}()
    for kv in split(server_first, ',')
        attrs[kv[1]] = String(kv[3:end])
    end
    r = attrs['r']
    startswith(r, nonce) || error("SCRAM: bad nonce")
    salt = b64std_decode(attrs['s'])
    iters = parse(Int, attrs['i'])
    salted = pbkdf2_sha256(Vector{UInt8}(cfg.password), salt, iters)
    client_key = hmac_sha256(salted, Vector{UInt8}("Client Key"))
    stored_key = sha256(client_key)
    final_wo_proof = "c=biws,r=" * r
    auth_msg = Vector{UInt8}(first_bare * "," * server_first * "," * final_wo_proof)
    client_sig = hmac_sha256(stored_key, auth_msg)
    proof = client_key .⊻ client_sig
    final = final_wo_proof * ",p=" * b64std_encode(proof)
    b.len = 0
    p = msg_begin!(b, UInt8('p'))
    wr!(b, final)
    msg_end!(b, p)
    sync_send(c, b)
    t, body = sync_recv(c)
    t == UInt8('E') && error("postgres auth: " * pg_error_text(body))
    (t == UInt8('R') && load_be(Int32, body, 0) == 12) || error("SCRAM: unexpected final message")
    server_key = hmac_sha256(salted, Vector{UInt8}("Server Key"))
    want = "v=" * b64std_encode(hmac_sha256(server_key, auth_msg))
    String(body[5:end]) == want || error("SCRAM: server signature mismatch")
end

# session settings sent in the startup packet: generic plans (no planning per execution), no JIT, no parallel
# workers for these tiny queries, and no Memoize, so no request is handed a row another request's lookup fetched
const SESSION_PARAMS = [
    "plan_cache_mode" => "force_generic_plan",
    "jit" => "off",
    "max_parallel_workers_per_gather" => "0",
    "enable_memoize" => "off",
    "application_name" => "conduit-julia",
]

function pg_connect(cfg::DbConfig)
    fd = tcp_connect(cfg.ip, cfg.port)
    c = SyncConn(fd, Vector{UInt8}(undef, 1 << 16), 0, 0)
    b = Buf(256)
    p = b.len
    put_be!(b, Int32(0))
    put_be!(b, Int32(196608))
    for (k, v) in vcat(["user" => cfg.user, "database" => cfg.database], SESSION_PARAMS)
        wr_cstr!(b, k)
        wr_cstr!(b, v)
    end
    wr!(b, 0x00)
    patch_be32!(b, p, b.len)
    sync_send(c, b)
    while true
        t, body = sync_recv(c)
        if t == UInt8('R')
            code = load_be(Int32, body, 0)
            if code == 0
                continue
            elseif code == 3
                b.len = 0
                p = msg_begin!(b, UInt8('p'))
                wr_cstr!(b, cfg.password)
                msg_end!(b, p)
                sync_send(c, b)
            elseif code == 10
                scram_auth(c, cfg)
            else
                error("postgres auth method $code not supported")
            end
        elseif t == UInt8('E')
            error("postgres: " * pg_error_text(body))
        elseif t == UInt8('Z')
            return c
        end
    end
end

# runs a simple query; returns the rows as text
function sync_query(c::SyncConn, sql::String)
    b = Buf(256)
    p = msg_begin!(b, UInt8('Q'))
    wr_cstr!(b, sql)
    msg_end!(b, p)
    sync_send(c, b)
    rows = Vector{Vector{Union{Nothing,String}}}()
    err = ""
    while true
        t, body = sync_recv(c)
        if t == UInt8('D')
            n = load_be(Int16, body, 0)
            pos = 2
            row = Union{Nothing,String}[]
            for _ in 1:n
                l = load_be(Int32, body, pos)
                pos += 4
                if l < 0
                    push!(row, nothing)
                else
                    push!(row, String(body[pos+1:pos+l]))
                    pos += l
                end
            end
            push!(rows, row)
        elseif t == UInt8('E')
            err = pg_error_text(body)
        elseif t == UInt8('Z')
            isempty(err) || error("postgres: $err\n$sql")
            return rows
        end
    end
end

function sync_prepare(c::SyncConn, stmts::Vector{Tuple{String,Vector{UInt32}}})
    b = Buf(4096)
    for (i, (sql, oids)) in enumerate(stmts)
        p = msg_begin!(b, UInt8('P'))
        wr_cstr!(b, STMT_NAMES[i])
        wr_cstr!(b, sql)
        put_be!(b, Int16(length(oids)))
        for o in oids
            put_be!(b, o)
        end
        msg_end!(b, p)
    end
    wr_sync!(b)
    sync_send(c, b)
    while true
        t, body = sync_recv(c)
        t == UInt8('E') && error("prepare: " * pg_error_text(body))
        t == UInt8('Z') && return
    end
end

function PgConn(c::SyncConn, idx::Int, iswrite::Bool)
    set_nonblocking(c.fd)
    rbuf = Vector{UInt8}(undef, 1 << 18)
    n = c.len - c.pos
    n > 0 && copyto!(rbuf, 1, c.buf, c.pos + 1, n)
    PgConn(c.fd, idx, iswrite, rbuf, 0, n, Buf(1 << 16), 0, Vector{Any}(undef, 64), 1, 0,
        zeros(Int, 32), zeros(Int, 32), 0, false, false)
end

# ---------------- runtime ----------------

@inline function push_unit!(c::PgConn, u)
    if c.ulen == length(c.units)
        # grow the ring, unrolled from head
        old = c.units
        n = length(old)
        new = Vector{Any}(undef, 2n)
        for k in 0:n-1
            new[k+1] = old[mod1(c.uhead + k, n)]
        end
        c.units = new
        c.uhead = 1
    end
    @inbounds c.units[mod1(c.uhead + c.ulen, length(c.units))] = u
    c.ulen += 1
    c.dirty = true
    nothing
end

@inline head_unit(c::PgConn) = @inbounds c.units[c.uhead]

@inline function pop_unit!(c::PgConn)
    u = @inbounds c.units[c.uhead]
    @inbounds c.units[c.uhead] = nothing
    c.uhead = c.uhead == length(c.units) ? 1 : c.uhead + 1
    c.ulen -= 1
    u
end

# sends what's buffered; false on a broken connection
function pg_flush!(c::PgConn)
    b = c.wbuf
    while c.wpos < b.len
        n = GC.@preserve b sys_send(c.fd, pointer(b.data, c.wpos + 1), b.len - c.wpos)
        if n < 0
            e = errno()
            e == EAGAIN && return true   # EPOLLOUT resumes
            e == EINTR && continue
            c.broken = true
            return false
        end
        c.wpos += n
    end
    b.len = 0
    c.wpos = 0
    c.dirty = false
    true
end

# column accessors for the current DataRow
@inline col_null(c::PgConn, k::Int) = @inbounds c.clen[k] < 0
@inline col_i64(c::PgConn, k::Int) = load_be(Int64, c.rbuf, @inbounds c.coff[k])
@inline col_i32(c::PgConn, k::Int) = load_be(Int32, c.rbuf, @inbounds c.coff[k])
@inline col_bool(c::PgConn, k::Int) = @inbounds c.rbuf[c.coff[k]+1] != 0x00

function parse_row!(c::PgConn, off::Int)
    v = c.rbuf
    n = Int(load_be(Int16, v, off))
    if n > length(c.coff)
        resize!(c.coff, n)
        resize!(c.clen, n)
    end
    p = off + 2
    @inbounds for k in 1:n
        l = Int(load_be(Int32, v, p))
        p += 4
        c.coff[k] = p
        c.clen[k] = l
        l > 0 && (p += l)
    end
    c.ncols = n
    nothing
end

function sqlstate_of(v::Vector{UInt8}, off::Int, stop::Int)
    i = off
    while i < stop && v[i+1] != 0x00
        f = v[i+1]
        j = i + 1
        while j < stop && v[j+1] != 0x00
            j += 1
        end
        if f == UInt8('C') && j - i - 1 == 5
            x = UInt64(0)
            for k in i+2:i+6
                x = (x << 8) | v[k]
            end
            return x, i, j
        end
        i = j + 1
    end
    UInt64(1), 0, 0
end

sqlstate(s::String) = foldl((x, c) -> (x << 8) | UInt8(c), s; init=UInt64(0))
const SQL_UNIQUE = sqlstate("23505")
const SQL_FK = sqlstate("23503")

# reads and dispatches everything available; false when the connection is gone
function pg_readable!(lp, c::PgConn)
    while true
        if length(c.rbuf) - c.rlen < 4096
            if c.rpos > 0
                n = c.rlen - c.rpos
                n > 0 && copyto!(c.rbuf, 1, c.rbuf, c.rpos + 1, n)
                c.rlen = n
                c.rpos = 0
            end
            length(c.rbuf) - c.rlen < 4096 && resize!(c.rbuf, 2 * length(c.rbuf))
        end
        space = length(c.rbuf) - c.rlen
        n = GC.@preserve c sys_recv(c.fd, pointer(c.rbuf, c.rlen + 1), space)
        if n < 0
            e = errno()
            e == EAGAIN && return true
            e == EINTR && continue
            return false
        end
        n == 0 && return false
        c.rlen += n
        pg_dispatch!(lp, c)
        n < space && return true
    end
end

function pg_dispatch!(lp, c::PgConn)
    v = c.rbuf
    while c.rlen - c.rpos >= 5
        p = c.rpos
        t = @inbounds v[p+1]
        l = Int(load_be(Int32, v, p + 1))
        if c.rlen - p < 1 + l
            1 + l > length(v) && resize!(c.rbuf, 2 + l + length(v))
            break
        end
        body = p + 5
        stop = p + 1 + l
        if t == UInt8('D')
            parse_row!(c, body)
            on_row(lp, c, head_unit(c))
        elseif t == UInt8('C')
            on_complete(lp, c, head_unit(c), body, stop - body - 1)
        elseif t == UInt8('E')
            code, mi, mj = sqlstate_of(v, body, stop)
            u = head_unit(c)
            if code != SQL_UNIQUE && code != SQL_FK
                @warn "postgres error" err = pg_error_text(v[body+1:stop])
            end
            on_error(lp, c, u, code)
        elseif t == UInt8('Z')
            u = pop_unit!(c)
            on_ready(lp, c, u)
        end
        # '1' '2' 'n' 'T' 'N' 'S' 'A' 's' 'I': nothing to do
        c.rpos = stop
    end
    if c.rpos == c.rlen
        c.rpos = 0
        c.rlen = 0
    end
    nothing
end
