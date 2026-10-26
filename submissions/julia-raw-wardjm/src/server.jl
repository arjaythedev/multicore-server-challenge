# Startup and the event loop.

const LOOPS = Loop[]

envint(name, default) = parse(Int, get(ENV, name, string(default)))

function new_loop(id::Int, ip::UInt32, port::Int, reads::Vector{PgConn}, writes::Vector{PgConn}, maxbatch::Int)
    epfd = epoll_create()
    lfd = tcp_listen(ip, port)
    efd = eventfd(EFD_NONBLOCK)
    kinds = [Kind(k, k, KIND_LAYOUT[k], maxbatch, length(reads), 0, Vector{Req}(undef, 256), 1, 0, Any[])
             for k in 1:NKINDS]
    pgs = vcat(reads, writes)
    for (i, c) in enumerate(pgs)
        c.idx = i
    end
    lp = Loop(id, epfd, lfd, efd, Vector{UInt8}(undef, 1024 * EV_SIZE), Any[nothing for _ in 1:65536],
        Vector{UInt8}[], Req[], reads, writes, pgs, kinds, Vector{Req}(undef, 256), 1, 0, 0,
        Threads.SpinLock(), Req[], Req[], JwtScratch(), Buf(256), zeros(Int, 64), zeros(Int, 64), Int64(floor(time())))
    epoll_ctl(epfd, EPOLL_CTL_ADD, lfd, EPOLLIN, ev_tag(TAG_LISTEN, lfd))
    epoll_ctl(epfd, EPOLL_CTL_ADD, efd, EPOLLIN, ev_tag(TAG_EFD, efd))
    for c in pgs
        epoll_ctl(epfd, EPOLL_CTL_ADD, c.fd, EPOLLIN | EPOLLOUT | EPOLLET, ev_tag(TAG_PG, c.idx))
    end
    lp
end

# a broken Postgres connection: everything waiting on it fails
function pg_fail!(lp::Loop, c::PgConn)
    c.broken && c.ulen == 0 && return
    @error "postgres connection lost" loop = lp.id conn = c.idx
    c.broken = true
    sys_close(c.fd)
    while c.ulen > 0
        u = pop_unit!(c)
        if u isa Batch
            u.kind.inflight -= 1
            for j in 1:u.n
                respond_error!(lp, u.items[j], 500, "database connection lost")
            end
            u.n = 0
        else
            respond_error!(lp, u::Req, 500, "database connection lost")
        end
    end
end

function drain_done!(lp::Loop)
    eventfd_drain(lp.efd)
    lock(lp.done_lock)
    lp.done, lp.done_swap = lp.done_swap, lp.done
    unlock(lp.done_lock)
    for r in lp.done_swap
        try
            bcrypt_done!(lp, r)
        catch e
            @error "bcrypt completion" exception = (e, catch_backtrace())
        end
    end
    empty!(lp.done_swap)
end

function handle_event!(lp::Loop, ev::UInt32, d::UInt64)
    tag = d >> 32
    x = Int(d & 0xffffffff)
    if tag == TAG_HTTP
        conn = @inbounds lp.conns[x+1]
        conn === nothing && return
        conn = conn::HConn
        if ev & (EPOLLIN | EPOLLRDHUP | EPOLLHUP | EPOLLERR) != 0
            http_readable!(lp, conn)
        end
        if ev & EPOLLOUT != 0 && !conn.dead
            http_writable!(lp, conn)
        end
    elseif tag == TAG_PG
        c = @inbounds lp.pgs[x]
        c.broken && return
        if ev & (EPOLLIN | EPOLLHUP | EPOLLERR) != 0
            pg_readable!(lp, c) || pg_fail!(lp, c)
        end
        if ev & EPOLLOUT != 0 && !c.broken && c.dirty
            pg_flush!(c) || pg_fail!(lp, c)
        end
    elseif tag == TAG_LISTEN
        accept_all!(lp)
    elseif tag == TAG_EFD
        drain_done!(lp)
    end
    nothing
end

function run_loop(lp::Loop)
    evs = lp.events
    maxev = length(evs) ÷ EV_SIZE
    while true
        n = epoll_wait(lp.epfd, evs, maxev, -1)
        if n < 0
            errno() == EINTR && continue
            error("epoll_wait: errno $(errno())")
        end
        lp.now = unsafe_trunc(Int64, time())
        for i in 1:n
            try
                handle_event!(lp, ev_events(evs, i), ev_data(evs, i))
            catch e
                @error "event" exception = (e, catch_backtrace())
            end
        end
        try
            pump_reads!(lp)
            pump_writes!(lp)
            for c in lp.pgs
                if c.dirty && !c.broken
                    pg_flush!(c) || pg_fail!(lp, c)
                end
            end
        catch e
            @error "dispatch" exception = (e, catch_backtrace())
        end
    end
end

function app_sorts_tags(c::SyncConn)
    rows = sync_query(c, "SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database " *
                         "WHERE datname = current_database()")
    prov, coll, loc = rows[1][1], rows[1][2], rows[1][3]
    cp(x) = x !== nothing && lowercase(x) in ("c", "posix", "c.utf-8", "c.utf8")
    (prov == "c" && cp(coll)) || (prov == "b" && cp(loc))
end

function main()
    nloops = envint("LOOPS", 2)
    nreads = envint("DB_READ_CONNS", 3)
    nwrites = envint("DB_WRITE_CONNS", 4)
    nbcrypt = envint("BCRYPT_THREADS", 2)
    nice = envint("BCRYPT_NICE", 5)
    BCRYPT_WAIT_MS[] = envint("BCRYPT_WAIT_MS", 40)
    maxbatch = envint("BATCH_MAX", 64)
    READ_DEPTH[] = envint("READ_DEPTH", 1)
    WRITE_DEPTH[] = envint("WRITE_DEPTH", 2)
    need = 1 + nloops + nbcrypt
    Threads.nthreads() >= need || error("need $need threads (julia -t $need), have $(Threads.nthreads())")
    nloops * (nreads + nwrites) <= 95 || error("too many Postgres connections")

    cfg = parse_database_url(ENV["DATABASE_URL"])
    JWT_KEY[] = HmacKey(Vector{UInt8}(ENV["JWT_SECRET"]))
    host = get(ENV, "HOST", "0.0.0.0")
    port = envint("PORT", 3000)
    ip = parse_ipv4(host)

    first = pg_connect(cfg)
    APP_SORTS_TAGS[] = app_sorts_tags(first)
    stmts = statements(APP_SORTS_TAGS[])
    sys_close(first.fd)

    JOB_EFD[] = eventfd(EFD_SEMAPHORE)
    for id in 1:nloops
        conns = PgConn[]
        for k in 1:nreads+nwrites
            sc = pg_connect(cfg)
            sync_prepare(sc, stmts)
            push!(conns, PgConn(sc, k, k > nreads))
        end
        push!(LOOPS, new_loop(id, ip, port, conns[1:nreads], conns[nreads+1:end], maxbatch))
    end
    for w in 1:nbcrypt
        spawn_on(() -> bcrypt_worker(nice), 1 + nloops + w)
    end
    for lp in LOOPS
        spawn_on(() -> run_loop(lp), 1 + lp.id)
    end
    println(stderr, "conduit: listening on $host:$port with $nloops loops, $(nloops * (nreads + nwrites)) Postgres ",
        "connections, $nbcrypt bcrypt threads; tags sorted by ", APP_SORTS_TAGS[] ? "the app" : "Postgres")
    stats = envint("STATS", 0)
    if stats > 0
        # allocation and GC pause rates, for tuning
        g0 = Base.gc_num()
        while true
            sleep(stats)
            g = Base.gc_num()
            d = Base.GC_Diff(g, g0)
            println(stderr, "stats: alloc ", round(d.allocd / 2^20 / stats; digits=2), " MiB/s, ", d.pause, " GCs, ",
                round(d.total_time / 1e6; digits=1), " ms in GC")
            g0 = g
        end
    end
    wait(Condition())
end
