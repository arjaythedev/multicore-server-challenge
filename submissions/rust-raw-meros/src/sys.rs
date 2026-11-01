//! The only place with raw system calls: sockets with `SO_REUSEPORT`, epoll, eventfd, scheduling class and the
//! descriptor limit. `std` has no API for these. Each wrapper is safe to call: it owns the invariants and turns
//! `errno` into `io::Error`.
//!
//! Linux x86-64 only (the challenge box). Constants are the Linux values from `<sys/epoll.h>` and friends.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

mod ffi {
    use std::ffi::{c_int, c_long, c_uint, c_void};

    #[repr(C)]
    pub struct SockAddrIn {
        pub family: u16,
        pub port: u16,
        pub addr: u32,
        pub zero: [u8; 8],
    }

    /// `struct epoll_event` is packed on x86-64 (12 bytes).
    #[repr(C, packed)]
    #[derive(Clone, Copy)]
    pub struct EpollEvent {
        pub events: u32,
        pub data: u64,
    }

    #[repr(C)]
    pub struct RLimit {
        pub cur: u64,
        pub max: u64,
    }

    #[repr(C)]
    pub struct SchedParam {
        pub priority: c_int,
    }

    unsafe extern "C" {
        pub fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
        pub fn setsockopt(
            fd: c_int,
            level: c_int,
            name: c_int,
            value: *const c_void,
            len: c_uint,
        ) -> c_int;
        pub fn bind(fd: c_int, addr: *const SockAddrIn, len: c_uint) -> c_int;
        pub fn listen(fd: c_int, backlog: c_int) -> c_int;
        pub fn accept4(fd: c_int, addr: *mut c_void, len: *mut c_uint, flags: c_int) -> c_int;
        pub fn read(fd: c_int, buf: *mut c_void, len: usize) -> isize;
        pub fn write(fd: c_int, buf: *const c_void, len: usize) -> isize;
        pub fn epoll_create1(flags: c_int) -> c_int;
        pub fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, event: *mut EpollEvent) -> c_int;
        pub fn epoll_wait(
            epfd: c_int,
            events: *mut EpollEvent,
            max: c_int,
            timeout_ms: c_int,
        ) -> c_int;
        pub fn eventfd(initval: c_uint, flags: c_int) -> c_int;
        pub fn getrlimit(resource: c_int, rlim: *mut RLimit) -> c_int;
        pub fn setrlimit(resource: c_int, rlim: *const RLimit) -> c_int;
        pub fn sched_setscheduler(pid: c_int, policy: c_int, param: *const SchedParam) -> c_int;
        pub fn gettid() -> c_long;
    }
}

const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const SOCK_NONBLOCK: i32 = 0o4000;
const SOCK_CLOEXEC: i32 = 0o2000000;
const SOL_SOCKET: i32 = 1;
const SO_REUSEADDR: i32 = 2;
const SO_REUSEPORT: i32 = 15;
const IPPROTO_TCP: i32 = 6;
const TCP_NODELAY: i32 = 1;
const EFD_NONBLOCK: i32 = 0o4000;
const EFD_CLOEXEC: i32 = 0o2000000;
const EPOLL_CLOEXEC: i32 = 0o2000000;
const EPOLL_CTL_ADD: i32 = 1;
const EPOLL_CTL_DEL: i32 = 2;
const EPOLL_CTL_MOD: i32 = 3;
const RLIMIT_NOFILE: i32 = 7;
const SCHED_BATCH: i32 = 3;
const SCHED_IDLE: i32 = 5;

/// Readable.
pub const EPOLLIN: u32 = 0x001;
/// Writable.
pub const EPOLLOUT: u32 = 0x004;
/// Error condition on the descriptor.
pub const EPOLLERR: u32 = 0x008;
/// Hang-up: both directions closed.
pub const EPOLLHUP: u32 = 0x010;
/// Peer closed its writing half.
pub const EPOLLRDHUP: u32 = 0x2000;
/// Edge-triggered: report a transition, not a level.
pub const EPOLLET: u32 = 1 << 31;

fn check(ret: i32) -> io::Result<i32> {
    if ret < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(ret)
    }
}

fn set_int_option(fd: RawFd, level: i32, name: i32, value: i32) -> io::Result<()> {
    // SAFETY: `value` outlives the call and the length matches its type.
    let ret = unsafe {
        ffi::setsockopt(
            fd,
            level,
            name,
            (&raw const value).cast(),
            size_of::<i32>() as u32,
        )
    };
    check(ret).map(|_| ())
}

/// A non-blocking IPv4 listener with `SO_REUSEPORT`, so every io thread owns one and the kernel spreads the
/// connections between them.
pub fn listen_reuseport(ip: [u8; 4], port: u16, backlog: i32) -> io::Result<OwnedFd> {
    // SAFETY: plain system call; the result is checked and wrapped in an `OwnedFd` straight away.
    let fd = check(unsafe { ffi::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0) })?;
    // SAFETY: `fd` is a fresh descriptor that nothing else owns.
    let owned = unsafe { OwnedFd::from_raw_fd(fd) };
    set_int_option(fd, SOL_SOCKET, SO_REUSEADDR, 1)?;
    set_int_option(fd, SOL_SOCKET, SO_REUSEPORT, 1)?;
    // Accepted sockets inherit this: every response leaves in one write, so Nagle only adds delay.
    set_int_option(fd, IPPROTO_TCP, TCP_NODELAY, 1)?;
    let addr = ffi::SockAddrIn {
        family: AF_INET as u16,
        port: port.to_be(),
        addr: u32::from_ne_bytes(ip),
        zero: [0; 8],
    };
    // SAFETY: `addr` is a valid `sockaddr_in` and the length is its size.
    check(unsafe { ffi::bind(fd, &addr, size_of::<ffi::SockAddrIn>() as u32) })?;
    // SAFETY: plain system call on an owned descriptor.
    check(unsafe { ffi::listen(fd, backlog) })?;
    Ok(owned)
}

/// Accepts one connection, non-blocking. `Ok(None)` when the queue is empty.
pub fn accept(listener: RawFd) -> io::Result<Option<OwnedFd>> {
    // SAFETY: null address pointers are allowed; the flags make the new descriptor non-blocking and close-on-exec.
    let ret = unsafe {
        ffi::accept4(
            listener,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            SOCK_NONBLOCK | SOCK_CLOEXEC,
        )
    };
    if ret >= 0 {
        // SAFETY: `ret` is a fresh descriptor that nothing else owns.
        return Ok(Some(unsafe { OwnedFd::from_raw_fd(ret) }));
    }
    let err = io::Error::last_os_error();
    match err.kind() {
        io::ErrorKind::WouldBlock => Ok(None),
        _ => Err(err),
    }
}

/// Result of a non-blocking read or write.
#[derive(Debug, PartialEq, Eq)]
pub enum Io {
    /// This many bytes moved (for a read, 0 never occurs here: it is `Eof`).
    Done(usize),
    /// The socket is not ready; wait for the next epoll event.
    WouldBlock,
    /// The peer closed its writing half (read only).
    Eof,
}

/// Reads into `buf` from a non-blocking descriptor.
pub fn read_nonblocking(fd: RawFd, buf: &mut [u8]) -> io::Result<Io> {
    loop {
        // SAFETY: `buf` is valid for writes of `buf.len()` bytes.
        let n = unsafe { ffi::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if n > 0 {
            return Ok(Io::Done(n as usize));
        }
        if n == 0 {
            return Ok(Io::Eof);
        }
        let err = io::Error::last_os_error();
        match err.kind() {
            io::ErrorKind::WouldBlock => return Ok(Io::WouldBlock),
            io::ErrorKind::Interrupted => continue,
            _ => return Err(err),
        }
    }
}

/// Reads into the spare capacity of `buf` and extends its length by what arrived. Does not allocate: a buffer
/// without spare capacity reads nothing and reports `WouldBlock`-free `Done(0)`, so the caller must grow it first.
pub fn read_into_vec(fd: RawFd, buf: &mut Vec<u8>) -> io::Result<Io> {
    let spare = buf.spare_capacity_mut();
    if spare.is_empty() {
        return Ok(Io::Done(0));
    }
    loop {
        // SAFETY: the pointer and length describe the spare capacity of `buf`, which is valid for writes.
        let n = unsafe { ffi::read(fd, spare.as_mut_ptr().cast(), spare.len()) };
        if n > 0 {
            // SAFETY: the kernel initialised the first `n` spare bytes.
            unsafe { buf.set_len(buf.len() + n as usize) };
            return Ok(Io::Done(n as usize));
        }
        if n == 0 {
            return Ok(Io::Eof);
        }
        let err = io::Error::last_os_error();
        match err.kind() {
            io::ErrorKind::WouldBlock => return Ok(Io::WouldBlock),
            io::ErrorKind::Interrupted => continue,
            _ => return Err(err),
        }
    }
}

/// Writes from `buf` to a non-blocking descriptor.
pub fn write_nonblocking(fd: RawFd, buf: &[u8]) -> io::Result<Io> {
    loop {
        // SAFETY: `buf` is valid for reads of `buf.len()` bytes.
        let n = unsafe { ffi::write(fd, buf.as_ptr().cast(), buf.len()) };
        if n >= 0 {
            return Ok(Io::Done(n as usize));
        }
        let err = io::Error::last_os_error();
        match err.kind() {
            io::ErrorKind::WouldBlock => return Ok(Io::WouldBlock),
            io::ErrorKind::Interrupted => continue,
            _ => return Err(err),
        }
    }
}

/// One readiness report: the registered token and the event bits.
#[derive(Clone, Copy)]
pub struct Event {
    pub token: u64,
    pub bits: u32,
}

/// An epoll instance.
pub struct Epoll {
    fd: OwnedFd,
    raw: Vec<ffi::EpollEvent>,
}

impl Epoll {
    /// A new epoll that reports up to `capacity` events per wait.
    pub fn new(capacity: usize) -> io::Result<Epoll> {
        // SAFETY: plain system call; the result is checked and wrapped straight away.
        let fd = check(unsafe { ffi::epoll_create1(EPOLL_CLOEXEC) })?;
        Ok(Epoll {
            // SAFETY: `fd` is a fresh descriptor that nothing else owns.
            fd: unsafe { OwnedFd::from_raw_fd(fd) },
            raw: vec![ffi::EpollEvent { events: 0, data: 0 }; capacity],
        })
    }

    fn control(&self, op: i32, fd: RawFd, events: u32, token: u64) -> io::Result<()> {
        let mut event = ffi::EpollEvent {
            events,
            data: token,
        };
        // SAFETY: `event` is valid for the duration of the call.
        check(unsafe { ffi::epoll_ctl(self.fd.as_raw_fd(), op, fd, &mut event) }).map(|_| ())
    }

    /// Starts watching `fd`; `token` comes back with every event.
    pub fn add(&self, fd: RawFd, events: u32, token: u64) -> io::Result<()> {
        self.control(EPOLL_CTL_ADD, fd, events, token)
    }

    /// Changes the watched events of `fd`.
    pub fn modify(&self, fd: RawFd, events: u32, token: u64) -> io::Result<()> {
        self.control(EPOLL_CTL_MOD, fd, events, token)
    }

    /// Stops watching `fd` (closing the descriptor does this too, unless it was duplicated).
    pub fn remove(&self, fd: RawFd) -> io::Result<()> {
        self.control(EPOLL_CTL_DEL, fd, 0, 0)
    }

    /// Waits up to `timeout_ms` (-1 = forever) and appends the ready events to `out`.
    pub fn wait(&mut self, timeout_ms: i32, out: &mut Vec<Event>) -> io::Result<()> {
        out.clear();
        // SAFETY: `raw` has room for `raw.len()` events.
        let n = unsafe {
            ffi::epoll_wait(
                self.fd.as_raw_fd(),
                self.raw.as_mut_ptr(),
                self.raw.len() as i32,
                timeout_ms,
            )
        };
        if n < 0 {
            let err = io::Error::last_os_error();
            return if err.kind() == io::ErrorKind::Interrupted {
                Ok(())
            } else {
                Err(err)
            };
        }
        out.extend(self.raw[..n as usize].iter().map(|e| Event {
            token: e.data,
            bits: e.events,
        }));
        Ok(())
    }
}

/// A counter descriptor that wakes an epoll loop from another thread.
pub struct EventFd(OwnedFd);

impl EventFd {
    pub fn new() -> io::Result<EventFd> {
        // SAFETY: plain system call; the result is checked and wrapped straight away.
        let fd = check(unsafe { ffi::eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC) })?;
        // SAFETY: `fd` is a fresh descriptor that nothing else owns.
        Ok(EventFd(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    pub fn raw(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    /// Adds 1 to the counter, which makes the descriptor readable.
    pub fn notify(&self) {
        let one = 1u64.to_ne_bytes();
        // A full counter (WouldBlock) already means "wake up", so the result needs no handling.
        let _ = write_nonblocking(self.raw(), &one);
    }

    /// Resets the counter.
    pub fn drain(&self) {
        let mut sink = [0u8; 8];
        let _ = read_nonblocking(self.raw(), &mut sink);
    }
}

/// Raises the soft limit on open descriptors to the hard limit and returns the new soft limit.
pub fn raise_nofile_limit() -> io::Result<u64> {
    let mut limit = ffi::RLimit { cur: 0, max: 0 };
    // SAFETY: `limit` is valid for writes.
    check(unsafe { ffi::getrlimit(RLIMIT_NOFILE, &mut limit) })?;
    limit.cur = limit.max;
    // SAFETY: `limit` is valid for reads.
    check(unsafe { ffi::setrlimit(RLIMIT_NOFILE, &limit) })?;
    Ok(limit.cur)
}

/// Scheduling class of the calling thread. Both classes are allowed without privileges and only ever lower the
/// priority, so a thread in them yields the CPU to the io and database threads.
#[derive(Clone, Copy)]
pub enum SchedClass {
    /// Runs only when no normal thread wants the CPU.
    Idle,
    /// Like normal, but never preempts for wake-ups and counts as CPU-bound.
    Batch,
}

/// Puts the calling thread into a scheduling class.
pub fn set_thread_sched(class: SchedClass) -> io::Result<()> {
    let policy = match class {
        SchedClass::Idle => SCHED_IDLE,
        SchedClass::Batch => SCHED_BATCH,
    };
    let param = ffi::SchedParam { priority: 0 };
    // SAFETY: pid 0 is the calling thread; `param` is valid for reads.
    check(unsafe { ffi::sched_setscheduler(0, policy, &param) }).map(|_| ())
}

/// Linux thread id, for log lines.
pub fn thread_id() -> i64 {
    // SAFETY: no arguments, cannot fail.
    unsafe { ffi::gettid() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn eventfd_wakes_epoll() {
        let mut epoll = Epoll::new(4).unwrap();
        let wake = EventFd::new().unwrap();
        epoll.add(wake.raw(), EPOLLIN, 7).unwrap();
        let mut events = Vec::new();
        epoll.wait(0, &mut events).unwrap();
        assert!(events.is_empty());
        wake.notify();
        epoll.wait(100, &mut events).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].token, 7);
        wake.drain();
        epoll.wait(0, &mut events).unwrap();
        assert!(events.is_empty());
    }

    #[test]
    fn listener_accepts_and_moves_bytes() {
        let listener = listen_reuseport([127, 0, 0, 1], 38417, 16).unwrap();
        let mut client = std::net::TcpStream::connect(("127.0.0.1", 38417)).unwrap();
        let mut accepted = None;
        for _ in 0..100 {
            accepted = accept(listener.as_raw_fd()).unwrap();
            if accepted.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let accepted = accepted.expect("a connection");
        let mut buf = [0u8; 16];
        assert_eq!(
            read_nonblocking(accepted.as_raw_fd(), &mut buf).unwrap(),
            Io::WouldBlock
        );
        use std::io::Write;
        client.write_all(b"hello").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        assert_eq!(
            read_nonblocking(accepted.as_raw_fd(), &mut buf).unwrap(),
            Io::Done(5)
        );
        assert_eq!(&buf[..5], b"hello");
        assert_eq!(
            write_nonblocking(accepted.as_raw_fd(), b"ok").unwrap(),
            Io::Done(2)
        );
    }

    #[test]
    fn nofile_limit_is_raised() {
        assert!(raise_nofile_limit().unwrap() >= 1024);
    }
}
