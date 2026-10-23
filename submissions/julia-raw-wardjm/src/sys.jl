# Thin libc layer: sockets, epoll, eventfd. Linux x86-64 only.
# Every call that can block in the kernel is `gc_safe=true`, so a thread parked in epoll_wait or a bcrypt worker
# never holds up a stop-the-world collection.

const AF_INET = Cint(2)
const SOCK_STREAM = Cint(1)
const SOCK_NONBLOCK = Cint(0o4000)
const SOCK_CLOEXEC = Cint(0o2000000)
const SOL_SOCKET = Cint(1)
const SO_REUSEADDR = Cint(2)
const SO_REUSEPORT = Cint(15)
const SO_KEEPALIVE = Cint(9)
const IPPROTO_TCP = Cint(6)
const TCP_NODELAY = Cint(1)

const EPOLL_CTL_ADD = Cint(1)
const EPOLL_CTL_DEL = Cint(2)
const EPOLL_CTL_MOD = Cint(3)
const EPOLLIN = UInt32(0x001)
const EPOLLOUT = UInt32(0x004)
const EPOLLERR = UInt32(0x008)
const EPOLLHUP = UInt32(0x010)
const EPOLLRDHUP = UInt32(0x2000)
const EPOLLET = UInt32(1) << 31

const EAGAIN = Cint(11)
const EINTR = Cint(4)
const EINPROGRESS = Cint(115)

const MSG_NOSIGNAL = Cint(0x4000)
const MSG_DONTWAIT = Cint(0x40)

const EFD_SEMAPHORE = Cint(1)
const EFD_NONBLOCK = Cint(0o4000)
const EFD_CLOEXEC = Cint(0o2000000)

const F_GETFL = Cint(3)
const F_SETFL = Cint(4)
const O_NONBLOCK = Cint(0o4000)

const EV_SIZE = 12 # struct epoll_event is packed on x86-64: u32 events, u64 data

errno() = Base.Libc.errno()

sys_close(fd::Integer) = ccall(:close, Cint, (Cint,), fd)

function set_nonblocking(fd::Integer)
    fl = ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_GETFL, Cint(0))
    ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_SETFL, fl | O_NONBLOCK)
end

function setsockopt_int(fd::Integer, level::Cint, opt::Cint, v::Integer)
    r = Ref{Cint}(v)
    ccall(:setsockopt, Cint, (Cint, Cint, Cint, Ptr{Cint}, Cuint), fd, level, opt, r, Cuint(4))
end

# struct sockaddr_in as 16 bytes: family (host order), port and address in network order
function sockaddr_in(ip::UInt32, port::Integer)
    sa = zeros(UInt8, 16)
    sa[1] = UInt8(AF_INET & 0xff)
    sa[2] = UInt8(AF_INET >> 8)
    sa[3] = UInt8((port >> 8) & 0xff)
    sa[4] = UInt8(port & 0xff)
    sa[5] = UInt8(ip >> 24)
    sa[6] = UInt8((ip >> 16) & 0xff)
    sa[7] = UInt8((ip >> 8) & 0xff)
    sa[8] = UInt8(ip & 0xff)
    sa
end

function parse_ipv4(s::AbstractString)
    p = split(s, '.')
    length(p) == 4 || error("not an IPv4 address: $s")
    v = UInt32(0)
    for x in p
        v = (v << 8) | parse(UInt8, x)
    end
    v
end

function resolve_ipv4(host::AbstractString)
    occursin(r"^\d+\.\d+\.\d+\.\d+$", host) && return parse_ipv4(host)
    host == "localhost" && return parse_ipv4("127.0.0.1")
    a = Sockets.getaddrinfo(host, Sockets.IPv4)
    UInt32(a.host)
end

function tcp_listen(ip::UInt32, port::Integer)
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, Cint(0))
    fd < 0 && error("socket: errno $(errno())")
    setsockopt_int(fd, SOL_SOCKET, SO_REUSEADDR, 1)
    setsockopt_int(fd, SOL_SOCKET, SO_REUSEPORT, 1)
    sa = sockaddr_in(ip, port)
    r = GC.@preserve sa ccall(:bind, Cint, (Cint, Ptr{UInt8}, Cuint), fd, pointer(sa), Cuint(16))
    r < 0 && error("bind port $port: errno $(errno())")
    ccall(:listen, Cint, (Cint, Cint), fd, Cint(65535)) < 0 && error("listen: errno $(errno())")
    fd
end

# blocking connect (startup only)
function tcp_connect(ip::UInt32, port::Integer)
    fd = ccall(:socket, Cint, (Cint, Cint, Cint), AF_INET, SOCK_STREAM | SOCK_CLOEXEC, Cint(0))
    fd < 0 && error("socket: errno $(errno())")
    sa = sockaddr_in(ip, port)
    r = GC.@preserve sa @ccall gc_safe = true connect(fd::Cint, pointer(sa)::Ptr{UInt8}, Cuint(16)::Cuint)::Cint
    r < 0 && error("connect to port $port: errno $(errno())")
    setsockopt_int(fd, IPPROTO_TCP, TCP_NODELAY, 1)
    fd
end

@inline accept4(fd::Cint) =
    ccall(:accept4, Cint, (Cint, Ptr{Cvoid}, Ptr{Cvoid}, Cint), fd, C_NULL, C_NULL, SOCK_NONBLOCK | SOCK_CLOEXEC)

@inline sys_recv(fd::Cint, p::Ptr{UInt8}, n::Integer) = ccall(:recv, Int, (Cint, Ptr{UInt8}, Csize_t, Cint), fd, p, n, Cint(0))
@inline sys_send(fd::Cint, p::Ptr{UInt8}, n::Integer) =
    ccall(:send, Int, (Cint, Ptr{UInt8}, Csize_t, Cint), fd, p, n, MSG_NOSIGNAL | MSG_DONTWAIT)

# blocking variants for startup
recv_blocking(fd::Cint, p::Ptr{UInt8}, n::Integer) =
    @ccall gc_safe = true recv(fd::Cint, p::Ptr{UInt8}, n::Csize_t, Cint(0)::Cint)::Int
send_blocking(fd::Cint, p::Ptr{UInt8}, n::Integer) =
    @ccall gc_safe = true send(fd::Cint, p::Ptr{UInt8}, n::Csize_t, MSG_NOSIGNAL::Cint)::Int

epoll_create() = ccall(:epoll_create1, Cint, (Cint,), Cint(0o2000000))

function epoll_ctl(epfd::Cint, op::Cint, fd::Integer, events::UInt32, data::UInt64)
    ev = Ref{NTuple{12,UInt8}}()
    p = Base.unsafe_convert(Ptr{UInt8}, ev)
    GC.@preserve ev begin
        unsafe_store!(Ptr{UInt32}(p), events)
        unsafe_store!(Ptr{UInt64}(p + 4), data)
        ccall(:epoll_ctl, Cint, (Cint, Cint, Cint, Ptr{UInt8}), epfd, op, fd, p)
    end
end

@inline epoll_wait(epfd::Cint, evs::Vector{UInt8}, maxev::Integer, timeout::Integer) =
    GC.@preserve evs @ccall gc_safe = true epoll_wait(epfd::Cint, pointer(evs)::Ptr{UInt8}, maxev::Cint, timeout::Cint)::Cint

@inline ev_events(evs::Vector{UInt8}, i::Integer) = GC.@preserve evs unsafe_load(Ptr{UInt32}(pointer(evs) + (i - 1) * EV_SIZE))
@inline ev_data(evs::Vector{UInt8}, i::Integer) = GC.@preserve evs unsafe_load(Ptr{UInt64}(pointer(evs) + (i - 1) * EV_SIZE + 4))

eventfd(flags::Cint) = ccall(:eventfd, Cint, (Cuint, Cint), Cuint(0), flags | EFD_CLOEXEC)

function eventfd_signal(fd::Cint)
    v = Ref{UInt64}(1)
    ccall(:write, Int, (Cint, Ptr{UInt64}, Csize_t), fd, v, Csize_t(8))
end

# non-blocking drain
function eventfd_drain(fd::Cint)
    v = Ref{UInt64}(0)
    ccall(:read, Int, (Cint, Ptr{UInt64}, Csize_t), fd, v, Csize_t(8))
end

# blocking read of one count (EFD_SEMAPHORE): a worker sleeps here
function eventfd_wait(fd::Cint)
    v = Ref{UInt64}(0)
    while true
        r = @ccall gc_safe = true read(fd::Cint, v::Ptr{UInt64}, Csize_t(8)::Csize_t)::Int
        r == 8 && return
        errno() == EINTR || error("eventfd read: errno $(errno())")
    end
end

gettid() = ccall(:syscall, Clong, (Clong,), Clong(186)) # SYS_gettid

# lower one thread's scheduling priority (Linux nice values are per thread)
set_thread_nice(n::Integer) = ccall(:setpriority, Cint, (Cint, Cuint, Cint), Cint(0), Cuint(gettid()), Cint(n))

# pins a sticky task to Julia thread `tid` (1-based) and starts it
function spawn_on(f, tid::Integer)
    t = Task(f)
    t.sticky = true
    ccall(:jl_set_task_tid, Cint, (Any, Cint), t, tid - 1)
    schedule(t)
    t
end
