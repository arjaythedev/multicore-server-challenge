#![allow(dead_code, non_camel_case_types)]

use std::ffi::{c_int, c_long, c_uint, c_void};
use std::io;
use std::net::{Ipv4Addr, SocketAddrV4, ToSocketAddrs};

pub type rlim_t = u64;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct rlimit {
    pub rlim_cur: rlim_t,
    pub rlim_max: rlim_t,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct timespec {
    pub tv_sec: i64,
    pub tv_nsec: c_long,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct pollfd {
    pub fd: c_int,
    pub events: i16,
    pub revents: i16,
}

pub const POLLIN: i16 = 0x0001;
pub const POLLOUT: i16 = 0x0004;
pub const POLLERR: i16 = 0x0008;
pub const POLLHUP: i16 = 0x0010;

pub const SIGPIPE: c_int = 13;
pub const SIG_IGN: usize = 1;
pub const CLOCK_REALTIME: c_int = 0;
#[cfg(target_os = "linux")]
pub const CLOCK_MONOTONIC: c_int = 1;
#[cfg(not(target_os = "linux"))]
pub const CLOCK_MONOTONIC: c_int = 6;

pub const AF_INET: c_int = 2;
pub const SOCK_STREAM: c_int = 1;
pub const IPPROTO_TCP: c_int = 6;
pub const SOL_SOCKET: c_int = 1;
pub const TCP_NODELAY: c_int = 1;

pub const F_GETFL: c_int = 3;
pub const F_SETFL: c_int = 4;

#[cfg(target_os = "linux")]
pub const RLIMIT_NOFILE: c_int = 7;
#[cfg(not(target_os = "linux"))]
pub const RLIMIT_NOFILE: c_int = 8;

#[cfg(target_os = "linux")]
pub const O_NONBLOCK: c_int = 0o4000;
#[cfg(not(target_os = "linux"))]
pub const O_NONBLOCK: c_int = 0x0004;

#[cfg(target_os = "linux")]
pub const SOCK_NONBLOCK: c_int = 0o4000;
#[cfg(target_os = "linux")]
pub const SOCK_CLOEXEC: c_int = 0o2000000;

#[cfg(target_os = "linux")]
pub const EFD_NONBLOCK: c_int = 0o4000;
#[cfg(target_os = "linux")]
pub const EFD_CLOEXEC: c_int = 0o2000000;

#[cfg(target_os = "linux")]
pub const SO_REUSEADDR: c_int = 2;
#[cfg(not(target_os = "linux"))]
pub const SO_REUSEADDR: c_int = 0x0004;

#[cfg(target_os = "linux")]
pub const SO_REUSEPORT: c_int = 15;
#[cfg(not(target_os = "linux"))]
pub const SO_REUSEPORT: c_int = 0x0200;

#[cfg(target_os = "linux")]
pub const MSG_NOSIGNAL: c_int = 0x4000;
#[cfg(not(target_os = "linux"))]
pub const MSG_NOSIGNAL: c_int = 0x20000;

#[cfg(target_os = "linux")]
pub const EAGAIN: c_int = 11;
#[cfg(not(target_os = "linux"))]
pub const EAGAIN: c_int = 35;

pub const EINTR: c_int = 4;

#[cfg(target_os = "linux")]
pub const EINPROGRESS: c_int = 115;
#[cfg(not(target_os = "linux"))]
pub const EINPROGRESS: c_int = 36;

#[cfg(target_os = "linux")]
pub const TCP_DEFER_ACCEPT: c_int = 9;
#[cfg(target_os = "linux")]
pub const TCP_QUICKACK: c_int = 12;

pub const PRIO_PROCESS: c_int = 0;

#[cfg(target_os = "linux")]
pub const CLONE_FILES: c_int = 0x0000_0400;
#[cfg(target_os = "linux")]
pub const SCHED_BATCH: c_int = 3;
#[cfg(target_os = "linux")]
pub const SCHED_IDLE: c_int = 5;

#[cfg(target_os = "linux")]
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct sched_param {
    pub sched_priority: c_int,
}

#[cfg(target_os = "linux")]
pub const EPOLL_CTL_ADD: c_int = 1;
#[cfg(target_os = "linux")]
pub const EPOLL_CTL_DEL: c_int = 2;
#[cfg(target_os = "linux")]
pub const EPOLL_CTL_MOD: c_int = 3;
#[cfg(target_os = "linux")]
pub const EPOLLIN: u32 = 0x001;
#[cfg(target_os = "linux")]
pub const EPOLLOUT: u32 = 0x004;
#[cfg(target_os = "linux")]
pub const EPOLLERR: u32 = 0x008;
#[cfg(target_os = "linux")]
pub const EPOLLHUP: u32 = 0x010;
#[cfg(target_os = "linux")]
pub const EPOLLRDHUP: u32 = 0x2000;

#[cfg(target_os = "linux")]
#[cfg_attr(target_arch = "x86_64", repr(C, packed))]
#[cfg_attr(not(target_arch = "x86_64"), repr(C))]
#[derive(Clone, Copy, Default)]
pub struct epoll_event {
    pub events: u32,
    pub u64_data: u64,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct sockaddr_in {
    #[cfg(not(target_os = "linux"))]
    pub sin_len: u8,
    #[cfg(not(target_os = "linux"))]
    pub sin_family: u8,
    #[cfg(target_os = "linux")]
    pub sin_family: u16,
    pub sin_port: u16,
    pub sin_addr: u32,
    pub sin_zero: [u8; 8],
}

unsafe extern "C" {
    pub fn signal(sig: c_int, handler: usize) -> usize;
    pub fn getrlimit(resource: c_int, rlim: *mut rlimit) -> c_int;
    pub fn setrlimit(resource: c_int, rlim: *const rlimit) -> c_int;
    pub fn clock_gettime(clk_id: c_int, tp: *mut timespec) -> c_int;
    pub fn nanosleep(req: *const timespec, rem: *mut timespec) -> c_int;
    pub fn memchr(s: *const c_void, c: c_int, n: usize) -> *const c_void;
    pub fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
    pub fn setsockopt(
        socket: c_int,
        level: c_int,
        name: c_int,
        value: *const c_void,
        option_len: u32,
    ) -> c_int;
    pub fn bind(socket: c_int, address: *const c_void, address_len: u32) -> c_int;
    pub fn listen(socket: c_int, backlog: c_int) -> c_int;
    pub fn accept(socket: c_int, address: *mut c_void, address_len: *mut u32) -> c_int;
    pub fn connect(socket: c_int, address: *const c_void, address_len: u32) -> c_int;
    pub fn recv(socket: c_int, buf: *mut c_void, len: usize, flags: c_int) -> isize;
    pub fn send(socket: c_int, buf: *const c_void, len: usize, flags: c_int) -> isize;
    pub fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
    pub fn write(fd: c_int, buf: *const c_void, count: usize) -> isize;
    pub fn close(fd: c_int) -> c_int;
    pub fn fcntl(fd: c_int, cmd: c_int, ...) -> c_int;
    pub fn poll(fds: *mut pollfd, nfds: c_uint, timeout: c_int) -> c_int;
    pub fn setpriority(which: c_int, who: c_uint, prio: c_int) -> c_int;

    #[cfg(target_os = "linux")]
    pub fn accept4(
        socket: c_int,
        address: *mut c_void,
        address_len: *mut u32,
        flags: c_int,
    ) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn epoll_create1(flags: c_int) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, event: *mut epoll_event) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn epoll_wait(
        epfd: c_int,
        events: *mut epoll_event,
        maxevents: c_int,
        timeout: c_int,
    ) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn eventfd(initval: c_uint, flags: c_int) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn getrandom(buf: *mut c_void, buflen: usize, flags: c_uint) -> isize;
    #[cfg(target_os = "linux")]
    pub fn sched_getaffinity(pid: c_int, cpusetsize: usize, mask: *mut u8) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn sched_setscheduler(pid: c_int, policy: c_int, param: *const sched_param) -> c_int;
    #[cfg(target_os = "linux")]
    pub fn unshare(flags: c_int) -> c_int;
}

/// Isolates the calling thread's file descriptor table (`CLONE_FILES`) so socket
/// `accept4`/`close`/`recv`/`send` operations never contend on a shared kernel `files_struct` lock.
#[inline]
pub fn unshare_files() {
    #[cfg(target_os = "linux")]
    unsafe {
        let _ = unshare(CLONE_FILES);
    }
}

/// Places the calling thread under `SCHED_BATCH` (preventing wakeup preemption of running
/// Postgres backends) and optionally sets its `nice` value.
#[inline]
pub fn set_sched_batch(nice_val: c_int) {
    #[cfg(target_os = "linux")]
    unsafe {
        let param = sched_param { sched_priority: 0 };
        let _ = sched_setscheduler(0, SCHED_BATCH, &param);
        if nice_val != 0 {
            let _ = setpriority(PRIO_PROCESS, 0, nice_val);
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = nice_val;
}

/// Places background CPU-bound helpers under `SCHED_IDLE` (with fallback to `nice 19`) so
/// background hashing never preempts PostgreSQL backends or I/O loops.
#[inline]
pub fn set_sched_idle() {
    #[cfg(target_os = "linux")]
    unsafe {
        let param = sched_param { sched_priority: 0 };
        let _ = sched_setscheduler(0, SCHED_IDLE, &param);
        let _ = setpriority(PRIO_PROCESS, 0, 19);
    }
}

#[inline]
pub fn find_byte(needle: u8, haystack: &[u8]) -> Option<usize> {
    if haystack.is_empty() {
        return None;
    }
    let ptr = unsafe {
        memchr(
            haystack.as_ptr().cast(),
            c_int::from(needle),
            haystack.len(),
        )
    };
    if ptr.is_null() {
        None
    } else {
        Some((ptr as usize) - (haystack.as_ptr() as usize))
    }
}

#[inline]
pub fn set_nonblocking(fd: c_int) {
    unsafe {
        let flags = fcntl(fd, F_GETFL, 0);
        if flags >= 0 {
            let _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK);
        }
    }
}

#[inline]
pub fn set_tcp_nodelay(fd: c_int) {
    let one: c_int = 1;
    unsafe {
        let _ = setsockopt(
            fd,
            IPPROTO_TCP,
            TCP_NODELAY,
            (&one as *const c_int).cast(),
            std::mem::size_of::<c_int>() as u32,
        );
    }
}

#[inline]
pub fn disable_quickack(fd: c_int) {
    #[cfg(target_os = "linux")]
    unsafe {
        let zero: c_int = 0;
        let _ = setsockopt(
            fd,
            IPPROTO_TCP,
            TCP_QUICKACK,
            (&zero as *const c_int).cast(),
            std::mem::size_of::<c_int>() as u32,
        );
    }
    #[cfg(not(target_os = "linux"))]
    let _ = fd;
}

#[inline]
pub fn clock_ms() -> i64 {
    let mut ts = timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        clock_gettime(CLOCK_MONOTONIC, &mut ts);
    }
    ts.tv_sec * 1000 + (ts.tv_nsec as i64) / 1_000_000
}

#[inline]
pub fn clock_us() -> i64 {
    let mut ts = timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        clock_gettime(CLOCK_MONOTONIC, &mut ts);
    }
    ts.tv_sec * 1_000_000 + (ts.tv_nsec as i64) / 1_000
}

#[inline]
pub fn unix_now() -> i64 {
    let mut ts = timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        clock_gettime(CLOCK_REALTIME, &mut ts);
    }
    ts.tv_sec
}

pub fn fill_random(buf: &mut [u8]) -> bool {
    #[cfg(target_os = "linux")]
    unsafe {
        let n = getrandom(buf.as_mut_ptr().cast(), buf.len(), 0);
        return n == buf.len() as isize;
    }
    #[cfg(not(target_os = "linux"))]
    {
        use std::io::Read;
        if let Ok(mut f) = std::fs::File::open("/dev/urandom") {
            return f.read_exact(buf).is_ok();
        }
        false
    }
}

/// Counts how many CPUs this process is allowed to run on (respecting systemd AllowedCPUs),
/// without pinning any thread (Rule 13 compliant).
pub fn usable_cpus() -> usize {
    #[cfg(target_os = "linux")]
    unsafe {
        let mut mask = [0u8; 128];
        if sched_getaffinity(0, mask.len(), mask.as_mut_ptr()) == 0 {
            let mut count = 0usize;
            for &b in &mask {
                count += b.count_ones() as usize;
            }
            if count > 0 {
                return count;
            }
        }
    }
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
}

pub fn raise_nofile_limit() {
    unsafe {
        signal(SIGPIPE, SIG_IGN);
        let mut rl = rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if getrlimit(RLIMIT_NOFILE, &mut rl) == 0 {
            rl.rlim_cur = rl.rlim_max;
            let _ = setrlimit(RLIMIT_NOFILE, &rl);
        }
    }
}

pub fn resolve_ipv4(host: &str, port: u16) -> Ipv4Addr {
    host.parse::<Ipv4Addr>()
        .or_else(|_| {
            (host, port)
                .to_socket_addrs()
                .ok()
                .and_then(|mut it| {
                    it.find_map(|sa| match sa {
                        std::net::SocketAddr::V4(v4) => Some(*v4.ip()),
                        _ => None,
                    })
                })
                .ok_or(())
        })
        .unwrap_or(Ipv4Addr::LOCALHOST)
}

pub fn open_listener(
    addr: SocketAddrV4,
    defer_accept_s: c_int,
    delayed_ack: bool,
) -> io::Result<c_int> {
    let fd = unsafe { socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let one: c_int = 1;
    unsafe {
        let _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEADDR,
            (&one as *const c_int).cast(),
            std::mem::size_of::<c_int>() as u32,
        );
        let _ = setsockopt(
            fd,
            SOL_SOCKET,
            SO_REUSEPORT,
            (&one as *const c_int).cast(),
            std::mem::size_of::<c_int>() as u32,
        );
    }
    set_tcp_nodelay(fd);
    set_nonblocking(fd);

    let sin = sockaddr_in {
        #[cfg(not(target_os = "linux"))]
        sin_len: std::mem::size_of::<sockaddr_in>() as u8,
        sin_family: AF_INET as _,
        sin_port: addr.port().to_be(),
        sin_addr: u32::from_ne_bytes(addr.ip().octets()),
        sin_zero: [0; 8],
    };

    if unsafe {
        bind(
            fd,
            (&sin as *const sockaddr_in).cast(),
            std::mem::size_of::<sockaddr_in>() as u32,
        )
    } < 0
    {
        let err = io::Error::last_os_error();
        unsafe { close(fd) };
        return Err(err);
    }

    if unsafe { listen(fd, 65535) } < 0 {
        let err = io::Error::last_os_error();
        unsafe { close(fd) };
        return Err(err);
    }

    if delayed_ack {
        disable_quickack(fd);
    }
    #[cfg(target_os = "linux")]
    if defer_accept_s > 0 {
        unsafe {
            let _ = setsockopt(
                fd,
                IPPROTO_TCP,
                TCP_DEFER_ACCEPT,
                (&defer_accept_s as *const c_int).cast(),
                std::mem::size_of::<c_int>() as u32,
            );
        }
    }
    #[cfg(not(target_os = "linux"))]
    let _ = defer_accept_s;

    Ok(fd)
}

