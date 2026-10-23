# HTTP/1.1 over raw non-blocking sockets. A connection holds a read buffer only while it has unparsed bytes: a
# request's strings are decoded into its Req before it is dispatched, so idle and waiting connections hold none.
# A response is the Req's out buffer: the body is written from HDR_RESERVE on, and the header right before it,
# so it goes out in one send.

const HDR_RESERVE = 128
const RBUF_SIZE = 16384
const MAX_REQUEST = 1 << 20

const M_GET = 1
const M_POST = 2
const M_PUT = 3
const M_DELETE = 4

const TAG_LISTEN = UInt64(1)
const TAG_HTTP = UInt64(2)
const TAG_PG = UInt64(3)
const TAG_EFD = UInt64(4)

@inline ev_tag(t::UInt64, x::Integer) = (t << 32) | UInt64(UInt32(x))

const DUMMY_CONN = HConn(Cint(-1), EMPTY, 0, 0, nothing, false, true, false)

function new_req(lp::Loop)
    if isempty(lp.reqpool)
        return Req(lp.id, DUMMY_CONN, 0, 0, 0, 0, 0, 0, Buf(1024), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, Fields(),
            Buf(8192), 0, 0, 0, 0, 0, false, false, 0, 0, 0)
    end
    pop!(lp.reqpool)
end

function release_req!(lp::Loop, r::Req)
    r.conn = DUMMY_CONN
    # keep oversized buffers from pinning memory
    length(r.out.data) > (1 << 18) && (r.out = Buf(8192))
    length(r.arena.data) > (1 << 16) && (r.arena = Buf(1024))
    push!(lp.reqpool, r)
    nothing
end

@inline function take_rbuf(lp::Loop)
    isempty(lp.bufpool) ? Vector{UInt8}(undef, RBUF_SIZE) : pop!(lp.bufpool)
end

@inline function drop_rbuf!(lp::Loop, conn::HConn)
    if conn.rbuf !== EMPTY
        length(conn.rbuf) == RBUF_SIZE && length(lp.bufpool) < 4096 && push!(lp.bufpool, conn.rbuf)
        conn.rbuf = EMPTY
    end
    conn.rpos = 0
    conn.rlen = 0
    nothing
end

function close_conn!(lp::Loop, conn::HConn)
    conn.dead && return
    conn.dead = true
    sys_close(conn.fd)
    lp.conns[conn.fd+1] === conn && (lp.conns[conn.fd+1] = nothing)
    drop_rbuf!(lp, conn)
    nothing
end

function accept_all!(lp::Loop)
    while true
        fd = accept4(lp.lfd)
        if fd < 0
            e = errno()
            e == EINTR && continue
            return # EAGAIN, or out of descriptors: the next connection retries
        end
        setsockopt_int(fd, IPPROTO_TCP, TCP_NODELAY, 1)
        conn = HConn(fd, EMPTY, 0, 0, nothing, false, false, false)
        if fd + 1 > length(lp.conns)
            n = length(lp.conns)
            resize!(lp.conns, max(fd + 1, 2n))
            for k in n+1:length(lp.conns)
                lp.conns[k] = nothing
            end
        end
        lp.conns[fd+1] = conn
        epoll_ctl(lp.epfd, EPOLL_CTL_ADD, fd, EPOLLIN | EPOLLOUT | EPOLLRDHUP | EPOLLET, ev_tag(TAG_HTTP, fd))
    end
end

function http_readable!(lp::Loop, conn::HConn)
    while true
        conn.rbuf === EMPTY && (conn.rbuf = take_rbuf(lp))
        if conn.rlen == length(conn.rbuf)
            if conn.rpos > 0
                n = conn.rlen - conn.rpos
                copyto!(conn.rbuf, 1, conn.rbuf, conn.rpos + 1, n)
                conn.rlen = n
                conn.rpos = 0
            elseif length(conn.rbuf) < MAX_REQUEST
                conn.rbuf = resize!(copy(conn.rbuf), 2 * length(conn.rbuf))
            else
                close_conn!(lp, conn)
                return
            end
        end
        space = length(conn.rbuf) - conn.rlen
        n = GC.@preserve conn sys_recv(conn.fd, pointer(conn.rbuf, conn.rlen + 1), space)
        if n > 0
            conn.rlen += n
            n < space && break
        elseif n == 0
            close_conn!(lp, conn)
            return
        else
            e = errno()
            e == EAGAIN && break
            e == EINTR && continue
            close_conn!(lp, conn)
            return
        end
    end
    if conn.req === nothing
        http_process!(lp, conn)
    end
    conn.req === nothing && conn.rlen == conn.rpos && drop_rbuf!(lp, conn)
    nothing
end

function http_writable!(lp::Loop, conn::HConn)
    if conn.wpend
        r = conn.req
        r isa Req && send_pending!(lp, r)
    end
end

# parses and starts as many requests as are complete, one at a time
function http_process!(lp::Loop, conn::HConn)
    while conn.req === nothing && !conn.dead && conn.rlen > conn.rpos
        parse_request!(lp, conn) || break
    end
    if !conn.dead && conn.rlen == conn.rpos
        drop_rbuf!(lp, conn)
    end
    nothing
end

@inline lower(c::UInt8) = UInt8('A') <= c <= UInt8('Z') ? c + 0x20 : c

# case-insensitive header-name match against a lowercase name
@inline function hname_eq(v::Vector{UInt8}, off::Int, n::Int, name::String)
    n == sizeof(name) || return false
    @inbounds for k in 1:n
        lower(v[off+k]) == codeunit(name, k) || return false
    end
    true
end

@inline function find_crlf2(v::Vector{UInt8}, from::Int, stop::Int)
    stop - from < 4 && return -1
    p = GC.@preserve v ccall(:memmem, Ptr{UInt8}, (Ptr{UInt8}, Csize_t, Ptr{UInt8}, Csize_t),
        pointer(v, from + 1), stop - from, pointer(CRLF2), 4)
    p == C_NULL ? -1 : Int(p - pointer(v)) # 0-based offset of the \r\n\r\n
end
const CRLF2 = b"\r\n\r\n"

# false when the request isn't complete yet (or the connection was closed)
function parse_request!(lp::Loop, conn::HConn)
    v = conn.rbuf
    s = conn.rpos
    e = conn.rlen
    h = find_crlf2(v, s, e)
    if h < 0
        if e - s > 65536
            close_conn!(lp, conn)
        end
        return false
    end
    hend = h + 4
    # request line
    i = s
    while i < h && v[i+1] != UInt8(' ')
        i += 1
    end
    mlen = i - s
    method = mlen == 3 && bytes_eq(v, s, 3, "GET") ? M_GET :
             mlen == 4 && bytes_eq(v, s, 4, "POST") ? M_POST :
             mlen == 3 && bytes_eq(v, s, 3, "PUT") ? M_PUT :
             mlen == 6 && bytes_eq(v, s, 6, "DELETE") ? M_DELETE : 0
    t0 = i + 1
    i = t0
    while i < h && v[i+1] != UInt8(' ') && v[i+1] != UInt8('\r')
        i += 1
    end
    tlen = i - t0
    # HTTP/1.0 closes unless asked otherwise
    close_after = i + 8 < h && v[i+1] == UInt8(' ') && bytes_eq(v, i + 1, 8, "HTTP/1.0")
    # headers
    while i < h && v[i+1] != UInt8('\n')
        i += 1
    end
    i += 1
    clen = 0
    auth_off = -1
    auth_len = 0
    chunked = false
    while i < h
        ls = i
        while i < h + 2 && v[i+1] != UInt8('\r')
            i += 1
        end
        le = i # line is v[ls, le)
        i += 2
        c = ls
        while c < le && v[c+1] != UInt8(':')
            c += 1
        end
        c >= le && continue
        nlen = c - ls
        vs = c + 1
        while vs < le && (v[vs+1] == UInt8(' ') || v[vs+1] == UInt8('\t'))
            vs += 1
        end
        ve = le
        while ve > vs && (v[ve] == UInt8(' ') || v[ve] == UInt8('\t'))
            ve -= 1
        end
        if hname_eq(v, ls, nlen, "content-length")
            clen = 0
            for k in vs+1:ve
                d = v[k]
                (d < UInt8('0') || d > UInt8('9')) && (clen = -1; break)
                clen = clen * 10 + (d - UInt8('0'))
                clen > MAX_REQUEST && (clen = -1; break)
            end
        elseif hname_eq(v, ls, nlen, "authorization")
            auth_off = vs
            auth_len = ve - vs
        elseif hname_eq(v, ls, nlen, "connection")
            if ve - vs == 5 && hname_eq(v, vs, 5, "close")
                close_after = true
            elseif ve - vs == 10 && hname_eq(v, vs, 10, "keep-alive")
                close_after = false
            end
        elseif hname_eq(v, ls, nlen, "transfer-encoding")
            chunked = true
        end
    end
    if clen < 0 || chunked
        conn.close_after = true
        r = new_req(lp)
        start_req!(lp, r, conn)
        conn.rpos = conn.rlen
        respond_error!(lp, r, 400, "bad request framing")
        return false
    end
    total = hend - s + clen
    if e - s < total
        if s + total > length(v)
            # make room for the body
            n = e - s
            nb = Vector{UInt8}(undef, max(RBUF_SIZE, total))
            copyto!(nb, 1, v, s + 1, n)
            conn.rbuf = nb
            conn.rpos = 0
            conn.rlen = n
        end
        return false
    end
    conn.rpos = s + total
    conn.close_after |= close_after
    r = new_req(lp)
    start_req!(lp, r, conn)
    handle!(lp, r, v, method, t0, tlen, auth_off, auth_len, hend, clen)
    true
end

function start_req!(lp::Loop, r::Req, conn::HConn)
    r.conn = conn
    conn.req = r
    r.route = 0
    r.step = 0
    r.viewer = 0
    r.limit = 20
    r.offset = 0
    r.id = 0
    reset!(r.arena)
    r.tok_off = r.tok_len = 0
    r.key_off = r.key_len = 0
    r.hash_off = r.hash_len = 0
    r.pw_off = r.pw_len = 0
    r.pfx_off = 0
    r.pfx_len = -1
    r.out.len = HDR_RESERVE
    r.status = 200
    r.rows = 0
    r.count = 0
    r.nstmt = 0
    r.sqlstate = 0
    r.flag = false
    r.bcrypt_ok = false
    nothing
end

const STATUS_LINE = Dict(
    200 => "HTTP/1.1 200 OK\r\n",
    201 => "HTTP/1.1 201 Created\r\n",
    204 => "HTTP/1.1 204 No Content\r\n",
    400 => "HTTP/1.1 400 Bad Request\r\n",
    401 => "HTTP/1.1 401 Unauthorized\r\n",
    403 => "HTTP/1.1 403 Forbidden\r\n",
    404 => "HTTP/1.1 404 Not Found\r\n",
    422 => "HTTP/1.1 422 Unprocessable Entity\r\n",
    500 => "HTTP/1.1 500 Internal Server Error\r\n")
const STATUS_LINES = [get(STATUS_LINE, s, "") for s in 1:600]

# sends r.out (body from HDR_RESERVE) with the given status
function respond!(lp::Loop, r::Req, status::Int)
    h = lp.hdr
    reset!(h)
    wr!(h, @inbounds STATUS_LINES[status])
    if status != 204
        wr!(h, "Content-Type: application/json\r\nContent-Length: ")
        put_int!(h, r.out.len - HDR_RESERVE)
        wr!(h, "\r\n")
    else
        r.out.len = HDR_RESERVE
    end
    r.conn.close_after && wr!(h, "Connection: close\r\n")
    wr!(h, "\r\n")
    start = HDR_RESERVE - h.len
    copyto!(r.out.data, start + 1, h.data, 1, h.len)
    r.wstart = start
    r.wpos = start
    send_pending!(lp, r)
end

function respond_error!(lp::Loop, r::Req, status::Int, msg::String)
    r.out.len = HDR_RESERVE
    wr!(r.out, "{\"errors\":{\"body\":[")
    wr_jstr!(r.out, msg)
    wr!(r.out, "]}}")
    respond!(lp, r, status)
end

function send_pending!(lp::Loop, r::Req)
    conn = r.conn
    if conn.dead
        conn.req === r && (conn.req = nothing)
        release_req!(lp, r)
        return
    end
    b = r.out
    while r.wpos < b.len
        n = GC.@preserve b sys_send(conn.fd, pointer(b.data, r.wpos + 1), b.len - r.wpos)
        if n < 0
            e = errno()
            if e == EAGAIN
                conn.wpend = true
                return
            end
            e == EINTR && continue
            conn.req = nothing
            release_req!(lp, r)
            close_conn!(lp, conn)
            return
        end
        r.wpos += n
    end
    conn.wpend = false
    conn.req = nothing
    release_req!(lp, r)
    if conn.close_after
        close_conn!(lp, conn)
    elseif conn.rlen > conn.rpos
        http_process!(lp, conn)
    end
    nothing
end
