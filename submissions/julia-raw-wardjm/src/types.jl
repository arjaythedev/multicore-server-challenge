# The structs every part shares. One Loop per event-loop thread owns its listener, its client connections, its
# Postgres connections and its request queues: nothing on the request path is shared between threads (bcrypt jobs
# are the one hand-off, through a locked queue and an eventfd).

mutable struct HConn
    fd::Cint
    rbuf::Vector{UInt8}   # EMPTY when idle (buffers go back to the loop's pool)
    rpos::Int             # 0-based start of unparsed bytes
    rlen::Int
    req::Any              # Union{Nothing,Req}: the request in flight
    wpend::Bool           # a response is partly written, waiting for EPOLLOUT
    dead::Bool
    close_after::Bool
end

const EMPTY = UInt8[]

mutable struct Req
    loopid::Int
    conn::HConn
    route::Int
    step::Int
    viewer::Int64
    limit::Int32
    offset::Int64
    id::Int64             # comment id, or the user id read for login
    arena::Buf            # decoded path/query/body strings and the presented token
    tok_off::Int
    tok_len::Int
    key_off::Int          # slug / username / tag / email
    key_len::Int
    hash_off::Int         # bcrypt hash: computed (register/update) or stored (login)
    hash_len::Int
    pw_off::Int           # password to hash/verify
    pw_len::Int
    pfx_off::Int          # article slug prefix "<slugified title>-"
    pfx_len::Int
    f::Fields
    out::Buf              # response, body from HDR_RESERVE on
    status::Int
    rows::Int
    count::Int64
    nstmt::Int            # statements completed in the current Postgres unit
    sqlstate::UInt64      # 0, or the 5 SQLSTATE bytes of the first error
    flag::Bool
    bcrypt_ok::Bool
    seq::Int
    wstart::Int           # response bytes [wstart, out.len) are what's sent; wpos = sent so far
    wpos::Int
end

mutable struct Kind
    id::Int
    stmt::Int
    layout::Int
    maxbatch::Int
    maxinflight::Int
    inflight::Int
    q::Vector{Req}
    qhead::Int
    qlen::Int
    free::Vector{Any}     # Batch objects
end

mutable struct Batch
    kind::Kind
    items::Vector{Req}
    n::Int
end

mutable struct PgConn
    fd::Cint
    idx::Int
    iswrite::Bool
    rbuf::Vector{UInt8}
    rpos::Int
    rlen::Int
    wbuf::Buf
    wpos::Int
    units::Vector{Any}    # ring of Union{Req,Batch} awaiting ReadyForQuery
    uhead::Int
    ulen::Int
    coff::Vector{Int}     # current DataRow: column offsets (0-based into rbuf) and lengths (-1 = NULL)
    clen::Vector{Int}
    ncols::Int
    dirty::Bool           # has unsent bytes
    broken::Bool
end

mutable struct Loop
    id::Int
    epfd::Cint
    lfd::Cint
    efd::Cint
    events::Vector{UInt8}
    conns::Vector{Any}    # by fd: Union{Nothing,HConn}
    bufpool::Vector{Vector{UInt8}}
    reqpool::Vector{Req}
    reads::Vector{PgConn}
    writes::Vector{PgConn}
    pgs::Vector{PgConn}
    kinds::Vector{Kind}
    wq::Vector{Req}       # writes waiting for a connection
    wqhead::Int
    wqlen::Int
    seq::Int
    done_lock::Threads.SpinLock
    done::Vector{Req}     # bcrypt results posted by workers
    done_swap::Vector{Req}
    jwt::JwtScratch
    hdr::Buf
    tagoff::Vector{Int}
    taglen::Vector{Int}
    now::Int64
end
