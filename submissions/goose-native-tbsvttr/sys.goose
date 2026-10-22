// The scheduler owns sockets. Native slice/epoll adapters translate the C ABI
// explicitly instead of depending on aggregate argument register allocation.
// EpollEvent stays packed for the official x86 target; native_sys.c translates
// ARM padding for local verification. No CPU affinity or kernel tuning is used.

struct EpollEvent { events: u32, data: u64 }                 // struct epoll_event: packed, 12 bytes
struct SockAddrIn { family: u16, port: u16, addr: u32, zero: u64 }   // struct sockaddr_in, both numbers big-endian
struct RLimit { cur: u64, max: u64 }

extern "socket" fn sys_socket(domain: i32, kind: i32, protocol: i32) -> i32;
extern "bind" fn sys_bind(fd: i32, addr: const SockAddrIn&, len: u32) -> i32;
extern "listen" fn sys_listen(fd: i32, backlog: i32) -> i32;
extern "accept4" fn sys_accept4(fd: i32, addr: i64, len: i64, flags: i32) -> i32;     // addr, len: NULL
extern "connect" fn sys_connect(fd: i32, addr: const SockAddrIn&, len: u32) -> i32;
extern "setsockopt" fn sys_setsockopt(fd: i32, level: i32, name: i32, value: const i32&, len: u32) -> i32;
extern "native_sys_recv" fn sys_recv(fd: i32, buf: u8[:], flags: i32) -> i64;
extern "native_sys_send" fn sys_send(fd: i32, buf: const u8[:], flags: i32) -> i64;
extern "native_sys_read" fn sys_read(fd: i32, buf: u8[:]) -> i64;
extern "native_sys_write" fn sys_write(fd: i32, buf: const u8[:]) -> i64;
extern fn native_write_atomic_reply(fd: i32, buf: const u8[:]) -> i64;
extern "close" fn sys_close(fd: i32) -> i32;
extern "pipe2" fn sys_pipe2(fds: i32[2]&, flags: i32) -> i32;
extern "epoll_create1" fn sys_epoll_create1(flags: i32) -> i32;
extern "native_sys_epoll_ctl" fn sys_epoll_ctl(epfd: i32, op: i32, fd: i32, ev: EpollEvent&) -> i32;
extern "native_sys_epoll_wait" fn sys_epoll_wait(epfd: i32, evs: EpollEvent[:], timeout: i32) -> i32;
extern "native_sys_getrandom" fn sys_getrandom(buf: u8[:], flags: u32) -> i64;
extern "getrlimit" fn sys_getrlimit(resource: i32, limit: RLimit&) -> i32;
extern "setrlimit" fn sys_setrlimit(resource: i32, limit: const RLimit&) -> i32;
extern "setpriority" fn sys_setpriority(which: i32, who: u32, prio: i32) -> i32;
extern "gettid" fn sys_gettid() -> i32;
extern "gs_os_time_ns" fn wall_ns() -> i64;                    // the Goose runtime's clocks: os itself is main's
extern "gs_os_clock_ns" fn mono_ns() -> i64;
extern "gs_os_sleep_ms" fn nap_ms(ms: i64);

let AF_INET = 2;
let SOCK_STREAM = 1;
let SOCK_NONBLOCK = 0x800;
let SOCK_CLOEXEC = 0x80000;
let SOL_SOCKET = 1;
let SO_REUSEADDR = 2;
let SO_REUSEPORT = 15;
let IPPROTO_TCP = 6;
let TCP_NODELAY = 1;
let MSG_NOSIGNAL = 0x4000;
let MSG_DONTWAIT = 0x40;
let O_NONBLOCK = 0x800;
let O_CLOEXEC = 0x80000;
let RLIMIT_NOFILE = 7;
let PRIO_PROCESS = 0;

let EPOLLIN: u32 = 0x1;
let EPOLLOUT: u32 = 0x4;
let EPOLLERR: u32 = 0x8;
let EPOLLHUP: u32 = 0x10;
let EPOLLRDHUP: u32 = 0x2000;
let EPOLLET: u32 = 0x80000000;
let EPOLL_CTL_ADD = 1;
let EPOLL_CTL_DEL = 2;
let EPOLL_CTL_MOD = 3;

fn bswap16(x: u16) -> u16 { (x << 8) | (x >> 8) }

// "1.2.3.4" as a network-order address; false when it isn't four decimal octets.
fn parse_ipv4(s: const u8[:]) -> u32, bool {
    var octets: u32[4] = [0; 4];
    var k = 0;
    var digits = 0;
    for c in s {
        if c == '.' {
            if digits == 0 || k == 3 { return 0, false; }
            k += 1; digits = 0;
        } else if c >= '0' && c <= '9' {
            octets[k] = octets[k] * 10 + (c - '0');
            digits += 1;
            if octets[k] > 255 || digits > 3 { return 0, false; }
        } else { return 0, false; }
    }
    if k != 3 || digits == 0 { return 0, false; }
    return octets[0] | octets[1] << 8 | octets[2] << 16 | octets[3] << 24, true;
}

fn sockaddr(addr: u32, port: i64) -> SockAddrIn {
    SockAddrIn { family: AF_INET, port: bswap16(port as! u16), addr: addr, zero: 0 }
}

// A blocking TCP connection to addr:port with Nagle off; -1 on failure.
fn connect_to(addr: u32, port: i64) -> i32 {
    let fd = sys_socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if fd < 0 { return -1; }
    let sa = sockaddr(addr, port);
    if sys_connect(fd, sa, 16) != 0 { sys_close(fd); return -1; }
    set_int_option(fd, IPPROTO_TCP, TCP_NODELAY, 1);
    return fd;
}

fn set_int_option(fd: i32, level: i32, name: i32, value: i32) {
    sys_setsockopt(fd, level, name, value, 4);
}

// A non-blocking listener of its own (SO_REUSEPORT spreads new connections over the loops); -1 on failure.
fn listen_on(addr: u32, port: i64) -> i32 {
    let fd = sys_socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if fd < 0 { return -1; }
    set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, 1);
    set_int_option(fd, SOL_SOCKET, SO_REUSEPORT, 1);
    let sa = sockaddr(addr, port);
    if sys_bind(fd, sa, 16) != 0 || sys_listen(fd, 65535) != 0 { sys_close(fd); return -1; }
    return fd;
}

fn epoll_add(epfd: i32, fd: i32, events: u32, data: u64) -> bool {
    var ev = EpollEvent { events: events, data: data };
    return sys_epoll_ctl(epfd, EPOLL_CTL_ADD, fd, ev) == 0;
}

fn epoll_mod(epfd: i32, fd: i32, events: u32, data: u64) -> bool {
    var ev = EpollEvent { events: events, data: data };
    return sys_epoll_ctl(epfd, EPOLL_CTL_MOD, fd, ev) == 0;
}

// Fills buf from the kernel's CSPRNG.
fn random_bytes(buf: u8[:]) {
    var done = 0;
    while done < buf.len {
        let n = sys_getrandom(buf[done..], 0);
        if n <= 0 { abort("getrandom failed"); }
        done += n;
    }
}

// The open-file limit raised to its hard maximum: every user holds a connection.
fn raise_nofile() {
    var lim = RLimit { cur: 0, max: 0 };
    if sys_getrlimit(RLIMIT_NOFILE, lim) == 0 && lim.cur < lim.max {
        lim.cur = lim.max;
        sys_setrlimit(RLIMIT_NOFILE, lim);
    }
}
