use std::io;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

use crate::auth::TokenSigner;
use crate::codec;
use crate::router::{self, Dispatch, HttpReq};

#[allow(non_camel_case_types)]
pub mod sys {
    pub type c_int = i32;
    pub type c_void = std::ffi::c_void;

    pub const PR_SET_THP_DISABLE: c_int = 41;
    pub const M_ARENA_MAX: c_int = -8;
    pub const SCHED_BATCH: c_int = 3;
    pub const CLONE_FILES: c_int = 0x0000_0400;
    pub const RLIMIT_NOFILE: c_int = 7;
    pub const EFD_NONBLOCK: c_int = 0o4000;
    pub const EFD_CLOEXEC: c_int = 0o2000000;
    pub const AF_INET: c_int = 2;
    pub const AF_INET6: c_int = 10;
    pub const SOCK_STREAM: c_int = 1;
    pub const SOCK_NONBLOCK: c_int = 0o4000;
    pub const SOCK_CLOEXEC: c_int = 0o2000000;
    pub const SOL_SOCKET: c_int = 1;
    pub const SO_REUSEADDR: c_int = 2;
    pub const SO_REUSEPORT: c_int = 15;
    pub const IPPROTO_TCP: c_int = 6;
    pub const TCP_NODELAY: c_int = 1;
    pub const IPPROTO_IPV6: c_int = 41;
    pub const IPV6_V6ONLY: c_int = 26;
    pub const EPOLL_CLOEXEC: c_int = 0o2000000;
    pub const EPOLL_CTL_ADD: c_int = 1;
    pub const EPOLL_CTL_MOD: c_int = 3;
    pub const EPOLLIN: u32 = 0x001;
    pub const EPOLLOUT: u32 = 0x004;
    pub const EPOLLERR: u32 = 0x008;
    pub const EPOLLHUP: u32 = 0x010;
    pub const EPOLLRDHUP: u32 = 0x2000;
    pub const EINTR: c_int = 4;
    pub const EAGAIN: c_int = 11;
    pub const ENFILE: c_int = 23;
    pub const EMFILE: c_int = 24;
    pub const ECONNABORTED: c_int = 103;

    #[repr(C)]
    pub struct sched_param {
        pub sched_priority: c_int,
    }

    #[repr(C)]
    pub struct rlimit {
        pub rlim_cur: u64,
        pub rlim_max: u64,
    }

    #[repr(C)]
    pub struct sockaddr {
        pub sa_family: u16,
        pub sa_data: [u8; 14],
    }

    #[repr(C)]
    pub struct in_addr {
        pub s_addr: u32,
    }

    #[repr(C)]
    pub struct sockaddr_in {
        pub sin_family: u16,
        pub sin_port: u16,
        pub sin_addr: in_addr,
        pub sin_zero: [u8; 8],
    }

    #[repr(C)]
    pub struct in6_addr {
        pub s6_addr: [u8; 16],
    }

    #[repr(C)]
    pub struct sockaddr_in6 {
        pub sin6_family: u16,
        pub sin6_port: u16,
        pub sin6_flowinfo: u32,
        pub sin6_addr: in6_addr,
        pub sin6_scope_id: u32,
    }

    #[repr(C)]
    pub struct iovec {
        pub iov_base: *mut c_void,
        pub iov_len: usize,
    }

    #[cfg_attr(target_arch = "x86_64", repr(C, packed))]
    #[cfg_attr(not(target_arch = "x86_64"), repr(C))]
    #[derive(Clone, Copy)]
    pub struct epoll_event {
        pub events: u32,
        pub u64: u64,
    }

    unsafe extern "C" {
        pub fn prctl(option: c_int, arg2: usize, arg3: usize, arg4: usize, arg5: usize) -> c_int;
        pub fn mallopt(param: c_int, value: c_int) -> c_int;
        pub fn sched_setscheduler(pid: c_int, policy: c_int, param: *const sched_param) -> c_int;
        pub fn unshare(flags: c_int) -> c_int;
        pub fn getrlimit(resource: c_int, rlim: *mut rlimit) -> c_int;
        pub fn setrlimit(resource: c_int, rlim: *const rlimit) -> c_int;
        pub fn eventfd(initval: u32, flags: c_int) -> c_int;
        pub fn socket(domain: c_int, ty: c_int, protocol: c_int) -> c_int;
        pub fn setsockopt(
            socket: c_int,
            level: c_int,
            name: c_int,
            value: *const c_void,
            option_len: u32,
        ) -> c_int;
        pub fn bind(socket: c_int, address: *const sockaddr, address_len: u32) -> c_int;
        pub fn listen(socket: c_int, backlog: c_int) -> c_int;
        pub fn accept4(fd: c_int, addr: *mut sockaddr, len: *mut u32, flg: c_int) -> c_int;
        pub fn epoll_create1(flags: c_int) -> c_int;
        pub fn epoll_ctl(epfd: c_int, op: c_int, fd: c_int, event: *mut epoll_event) -> c_int;
        pub fn epoll_wait(
            epfd: c_int,
            events: *mut epoll_event,
            maxevents: c_int,
            timeout: c_int,
        ) -> c_int;
        pub fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
        pub fn write(fd: c_int, buf: *const c_void, count: usize) -> isize;
        pub fn writev(fd: c_int, iov: *const iovec, iovcnt: c_int) -> isize;
        pub fn close(fd: c_int) -> c_int;
        pub fn getrandom(buf: *mut c_void, buflen: usize, flags: u32) -> isize;
    }
}

const TOKEN_LISTENER: u64 = u64::MAX;
const TOKEN_OUTBOX: u64 = u64::MAX - 1;
const IDLE_NONE: u32 = u32::MAX;
const EPOCH_CLOSED: u32 = u32::MAX;
const LIMIT_HEAD: usize = 64 * 1024;
const LIMIT_BODY: usize = 1024 * 1024;

pub fn unshare_files() {
    unsafe {
        let _ = sys::unshare(sys::CLONE_FILES);
    }
}

pub fn probe_nofile_limit() -> usize {
    unsafe {
        let mut rl = sys::rlimit {
            rlim_cur: 0,
            rlim_max: 0,
        };
        if sys::getrlimit(sys::RLIMIT_NOFILE, &mut rl) == 0 {
            let target = rl.rlim_max.min(262_144);
            if rl.rlim_cur < target {
                let raised = sys::rlimit {
                    rlim_cur: target,
                    rlim_max: rl.rlim_max,
                };
                if sys::setrlimit(sys::RLIMIT_NOFILE, &raised) == 0 {
                    rl.rlim_cur = target;
                }
            }
            return (rl.rlim_cur as usize).saturating_sub(256).max(256);
        }
    }
    65536
}

#[derive(Clone, Copy, Debug)]
pub struct ReplyAddr {
    pub worker: u16,
    pub slot: u32,
    pub epoch: u32,
}

pub enum ReplyBody {
    Owned(Vec<u8>),
    Shared(Arc<[u8]>),
    Empty,
}

impl ReplyBody {
    #[inline]
    pub fn as_slice(&self) -> &[u8] {
        match self {
            ReplyBody::Owned(v) => v.as_slice(),
            ReplyBody::Shared(a) => a.as_ref(),
            ReplyBody::Empty => &[],
        }
    }
}

pub struct OutgoingReply {
    pub addr: ReplyAddr,
    pub status: u16,
    pub body: ReplyBody,
}

pub struct WorkerOutbox {
    pub pending: Mutex<Vec<OutgoingReply>>,
    pub event_fd: RawFd,
    pub epochs: Box<[AtomicU32]>,
}

static OUTBOX_RING: OnceLock<Vec<WorkerOutbox>> = OnceLock::new();

pub fn init_outboxes(worker_count: usize, slot_cap: usize) {
    let cap = slot_cap.max(65536) + 512;
    let boxes = (0..worker_count)
        .map(|_| {
            let efd = unsafe { sys::eventfd(0, sys::EFD_NONBLOCK | sys::EFD_CLOEXEC) };
            assert!(efd >= 0, "eventfd creation failed");
            let epochs: Vec<AtomicU32> = (0..cap).map(|_| AtomicU32::new(EPOCH_CLOSED)).collect();
            WorkerOutbox {
                pending: Mutex::new(Vec::with_capacity(1024)),
                event_fd: efd,
                epochs: epochs.into_boxed_slice(),
            }
        })
        .collect();
    OUTBOX_RING.set(boxes).ok().expect("init_outboxes called twice");
}

#[inline]
pub fn worker_outbox(worker: usize) -> &'static WorkerOutbox {
    &OUTBOX_RING.get().expect("outboxes not initialized")[worker]
}

#[inline]
pub fn is_addr_alive(addr: ReplyAddr) -> bool {
    let ob = worker_outbox(addr.worker as usize);
    ob.epochs
        .get(addr.slot as usize)
        .is_none_or(|e| e.load(Ordering::Relaxed) == addr.epoch)
}

#[inline]
fn signal_eventfd(efd: RawFd) {
    let one: u64 = 1;
    unsafe {
        sys::write(efd, &one as *const u64 as *const sys::c_void, 8);
    }
}

pub fn complete_one(addr: ReplyAddr, status: u16, body: Vec<u8>) {
    complete_reply(OutgoingReply {
        addr,
        status,
        body: ReplyBody::Owned(body),
    });
}

#[inline]
fn complete_reply(reply: OutgoingReply) {
    let ob = worker_outbox(reply.addr.worker as usize);
    let notify = {
        let mut q = ob.pending.lock().unwrap();
        let was_empty = q.is_empty();
        q.push(reply);
        was_empty
    };
    if notify {
        signal_eventfd(ob.event_fd);
    }
}

pub fn complete_batch(mut replies: Vec<OutgoingReply>) {
    if replies.is_empty() {
        return;
    }
    if replies.len() == 1 {
        let r = replies.pop().unwrap();
        complete_reply(r);
        return;
    }
    replies.sort_unstable_by_key(|r| r.addr.worker);
    let mut end = replies.len();
    while end > 0 {
        let w = replies[end - 1].addr.worker;
        let mut start = end - 1;
        while start > 0 && replies[start - 1].addr.worker == w {
            start -= 1;
        }
        let ob = worker_outbox(w as usize);
        let notify = {
            let mut q = ob.pending.lock().unwrap();
            let was_empty = q.is_empty();
            q.extend(replies.drain(start..end));
            was_empty
        };
        if notify {
            signal_eventfd(ob.event_fd);
        }
        end = start;
    }
}

pub fn make_error_json(msg: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(40 + msg.len());
    out.extend_from_slice(b"{\"errors\":{\"body\":[");
    codec::write_str(&mut out, msg.as_bytes());
    out.extend_from_slice(b"]}}");
    out
}

pub fn error_reply(addr: ReplyAddr, status: u16, msg: &str) -> OutgoingReply {
    OutgoingReply {
        addr,
        status,
        body: ReplyBody::Owned(make_error_json(msg)),
    }
}

struct ClientSlot {
    fd: RawFd,
    epoch: u32,
    rx: Vec<u8>,
    tx: Vec<u8>,
    tx_off: usize,
    in_flight: bool,
    close_on_done: bool,
    eof_seen: bool,
    polling_out: bool,
    continue_sent: bool,
    reused: bool,
    in_idle_lru: bool,
    idle_prev: u32,
    idle_next: u32,
}

pub struct Reactor {
    worker_id: u16,
    ep_fd: RawFd,
    listen_fd: RawFd,
    outbox_fd: RawFd,
    slots: Vec<ClientSlot>,
    free_slots: Vec<u32>,
    scratch: Vec<u8>,
    outbox_buf: Vec<OutgoingReply>,
    pipelined_slots: Vec<u32>,
    signer: &'static TokenSigner,
    epochs: &'static [AtomicU32],
    active_conns: usize,
    fd_budget: usize,
    idle_head: u32,
    idle_tail: u32,
}

#[inline]
fn sys_cvt(rc: i32) -> io::Result<i32> {
    if rc < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(rc)
    }
}

pub fn bind_listener(host: &str, port: u16) -> io::Result<RawFd> {
    let ip: std::net::IpAddr = host
        .parse()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "invalid HOST address"))?;
    unsafe {
        let domain = if ip.is_ipv4() { sys::AF_INET } else { sys::AF_INET6 };
        let fd = sys_cvt(sys::socket(
            domain,
            sys::SOCK_STREAM | sys::SOCK_NONBLOCK | sys::SOCK_CLOEXEC,
            0,
        ))?;
        let yes: sys::c_int = 1;
        let no: sys::c_int = 0;
        for opt in [sys::SO_REUSEADDR, sys::SO_REUSEPORT] {
            sys_cvt(sys::setsockopt(
                fd,
                sys::SOL_SOCKET,
                opt,
                &yes as *const _ as *const sys::c_void,
                4,
            ))?;
        }
        match ip {
            std::net::IpAddr::V4(v4) => {
                let sa = sys::sockaddr_in {
                    sin_family: sys::AF_INET as u16,
                    sin_port: port.to_be(),
                    sin_addr: sys::in_addr {
                        s_addr: u32::from_ne_bytes(v4.octets()),
                    },
                    sin_zero: [0; 8],
                };
                sys_cvt(sys::bind(
                    fd,
                    &sa as *const _ as *const sys::sockaddr,
                    std::mem::size_of::<sys::sockaddr_in>() as u32,
                ))?;
            }
            std::net::IpAddr::V6(v6) => {
                sys_cvt(sys::setsockopt(
                    fd,
                    sys::IPPROTO_IPV6,
                    sys::IPV6_V6ONLY,
                    &no as *const _ as *const sys::c_void,
                    4,
                ))?;
                let sa = sys::sockaddr_in6 {
                    sin6_family: sys::AF_INET6 as u16,
                    sin6_port: port.to_be(),
                    sin6_flowinfo: 0,
                    sin6_addr: sys::in6_addr { s6_addr: v6.octets() },
                    sin6_scope_id: 0,
                };
                sys_cvt(sys::bind(
                    fd,
                    &sa as *const _ as *const sys::sockaddr,
                    std::mem::size_of::<sys::sockaddr_in6>() as u32,
                ))?;
            }
        }
        sys_cvt(sys::listen(fd, 65535))?;
        Ok(fd)
    }
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        100 => "100 Continue",
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        413 => "413 Payload Too Large",
        422 => "422 Unprocessable Entity",
        431 => "431 Request Header Fields Too Large",
        _ => "500 Internal Server Error",
    }
}

enum ParseOutcome {
    Complete {
        consumed: usize,
        close_after: bool,
        dispatch: Dispatch,
    },
    Incomplete {
        send_continue: bool,
    },
    Reject(u16),
}

impl Reactor {
    pub fn new(
        worker_id: u16,
        listen_fd: RawFd,
        signer: &'static TokenSigner,
        fd_budget: usize,
    ) -> io::Result<Self> {
        let ep_fd = sys_cvt(unsafe { sys::epoll_create1(sys::EPOLL_CLOEXEC) })?;
        let ob = worker_outbox(worker_id as usize);
        let outbox_fd = ob.event_fd;
        let reactor = Reactor {
            worker_id,
            ep_fd,
            listen_fd,
            outbox_fd,
            slots: Vec::with_capacity(16384),
            free_slots: Vec::with_capacity(4096),
            scratch: vec![0; 256 * 1024],
            outbox_buf: Vec::with_capacity(1024),
            pipelined_slots: Vec::with_capacity(256),
            signer,
            epochs: &ob.epochs,
            active_conns: 0,
            fd_budget: fd_budget.max(256),
            idle_head: IDLE_NONE,
            idle_tail: IDLE_NONE,
        };
        reactor.ep_ctl(sys::EPOLL_CTL_ADD, listen_fd, sys::EPOLLIN, TOKEN_LISTENER)?;
        reactor.ep_ctl(sys::EPOLL_CTL_ADD, outbox_fd, sys::EPOLLIN, TOKEN_OUTBOX)?;
        Ok(reactor)
    }

    #[inline]
    fn ep_ctl(&self, op: i32, fd: RawFd, events: u32, token: u64) -> io::Result<()> {
        let mut ev = sys::epoll_event { events, u64: token };
        sys_cvt(unsafe { sys::epoll_ctl(self.ep_fd, op, fd, &mut ev) })?;
        Ok(())
    }

    #[inline]
    fn link_idle(&mut self, slot: u32) {
        let c = &mut self.slots[slot as usize];
        if c.in_idle_lru || c.fd < 0 {
            return;
        }
        c.in_idle_lru = true;
        c.idle_prev = self.idle_tail;
        c.idle_next = IDLE_NONE;
        if self.idle_tail != IDLE_NONE {
            self.slots[self.idle_tail as usize].idle_next = slot;
        } else {
            self.idle_head = slot;
        }
        self.idle_tail = slot;
    }

    #[inline]
    fn unlink_idle(&mut self, slot: u32) {
        let (in_lru, prev, next) = {
            let c = &mut self.slots[slot as usize];
            if !c.in_idle_lru {
                return;
            }
            c.in_idle_lru = false;
            let p = c.idle_prev;
            let n = c.idle_next;
            c.idle_prev = IDLE_NONE;
            c.idle_next = IDLE_NONE;
            (true, p, n)
        };
        if !in_lru {
            return;
        }
        if prev != IDLE_NONE {
            self.slots[prev as usize].idle_next = next;
        } else {
            self.idle_head = next;
        }
        if next != IDLE_NONE {
            self.slots[next as usize].idle_prev = prev;
        } else {
            self.idle_tail = prev;
        }
    }

    pub fn run_loop(mut self) {
        let mut events: Vec<sys::epoll_event> = vec![sys::epoll_event { events: 0, u64: 0 }; 1024];
        loop {
            let n = unsafe { sys::epoll_wait(self.ep_fd, events.as_mut_ptr(), events.len() as i32, -1) };
            if n < 0 {
                let err = io::Error::last_os_error();
                if err.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                panic!("epoll_wait failed: {err}");
            }
            for i in 0..n as usize {
                let ev = events[i];
                match ev.u64 {
                    TOKEN_LISTENER => self.accept_ready(),
                    TOKEN_OUTBOX => self.flush_outbox(),
                    raw_slot => {
                        let slot = raw_slot as u32;
                        if ev.events & sys::EPOLLOUT != 0 {
                            self.flush_tx(slot);
                        }
                        if ev.events & (sys::EPOLLIN | sys::EPOLLHUP | sys::EPOLLERR | sys::EPOLLRDHUP) != 0 {
                            self.read_ready(slot, ev.events);
                        }
                    }
                }
            }
        }
    }

    fn accept_ready(&mut self) {
        loop {
            while self.active_conns >= self.fd_budget && self.idle_head != IDLE_NONE {
                let victim = self.idle_head;
                self.drop_conn(victim);
            }
            let fd = unsafe {
                sys::accept4(
                    self.listen_fd,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    sys::SOCK_NONBLOCK | sys::SOCK_CLOEXEC,
                )
            };
            if fd < 0 {
                let err = io::Error::last_os_error();
                match err.raw_os_error() {
                    Some(sys::EAGAIN) => return,
                    Some(sys::EINTR) | Some(sys::ECONNABORTED) => continue,
                    Some(sys::EMFILE) | Some(sys::ENFILE) => {
                        if self.idle_head != IDLE_NONE {
                            let victim = self.idle_head;
                            self.drop_conn(victim);
                            continue;
                        }
                        return;
                    }
                    _ => return,
                }
            }
            let yes: sys::c_int = 1;
            unsafe {
                sys::setsockopt(
                    fd,
                    sys::IPPROTO_TCP,
                    sys::TCP_NODELAY,
                    &yes as *const _ as *const sys::c_void,
                    4,
                );
            }
            let (slot, epoch) = match self.free_slots.pop() {
                Some(idx) => {
                    let c = &mut self.slots[idx as usize];
                    c.fd = fd;
                    c.in_flight = false;
                    c.close_on_done = false;
                    c.eof_seen = false;
                    c.polling_out = false;
                    c.continue_sent = false;
                    c.reused = false;
                    c.in_idle_lru = false;
                    c.idle_prev = IDLE_NONE;
                    c.idle_next = IDLE_NONE;
                    c.tx_off = 0;
                    (idx, c.epoch)
                }
                None => {
                    self.slots.push(ClientSlot {
                        fd,
                        epoch: 0,
                        rx: Vec::new(),
                        tx: Vec::new(),
                        tx_off: 0,
                        in_flight: false,
                        close_on_done: false,
                        eof_seen: false,
                        polling_out: false,
                        continue_sent: false,
                        reused: false,
                        in_idle_lru: false,
                        idle_prev: IDLE_NONE,
                        idle_next: IDLE_NONE,
                    });
                    ((self.slots.len() - 1) as u32, 0)
                }
            };
            self.active_conns += 1;
            if let Some(e) = self.epochs.get(slot as usize) {
                e.store(epoch, Ordering::Relaxed);
            }
            if self
                .ep_ctl(
                    sys::EPOLL_CTL_ADD,
                    fd,
                    sys::EPOLLIN | sys::EPOLLRDHUP,
                    slot as u64,
                )
                .is_err()
            {
                self.drop_conn(slot);
            }
        }
    }

    fn drop_conn(&mut self, slot: u32) {
        if self.slots[slot as usize].fd < 0 {
            return;
        }
        self.unlink_idle(slot);
        let c = &mut self.slots[slot as usize];
        unsafe {
            sys::close(c.fd);
        }
        c.fd = -1;
        let next_epoch = c.epoch.wrapping_add(1);
        c.epoch = if next_epoch == EPOCH_CLOSED { 0 } else { next_epoch };
        if let Some(e) = self.epochs.get(slot as usize) {
            e.store(EPOCH_CLOSED, Ordering::Relaxed);
        }
        c.rx = Vec::new();
        c.tx = Vec::new();
        c.tx_off = 0;
        c.in_flight = false;
        c.reused = false;
        self.active_conns = self.active_conns.saturating_sub(1);
        self.free_slots.push(slot);
    }

    fn read_ready(&mut self, slot: u32, ev_flags: u32) {
        if self.slots[slot as usize].fd < 0 {
            return;
        }
        if (ev_flags & (sys::EPOLLHUP | sys::EPOLLERR)) != 0 && (ev_flags & sys::EPOLLIN) == 0 {
            self.drop_conn(slot);
            return;
        }
        self.unlink_idle(slot);
        let mut first_read = true;
        loop {
            let (fd, can_direct_parse) = {
                let c = &self.slots[slot as usize];
                if c.fd < 0 {
                    return;
                }
                (c.fd, first_read && !c.in_flight && c.rx.is_empty())
            };
            first_read = false;

            let n = unsafe {
                sys::read(
                    fd,
                    self.scratch.as_mut_ptr() as *mut sys::c_void,
                    self.scratch.len(),
                )
            };
            if n < 0 {
                let err = io::Error::last_os_error();
                match err.raw_os_error() {
                    Some(sys::EAGAIN) => {
                        if (ev_flags & (sys::EPOLLHUP | sys::EPOLLERR | sys::EPOLLRDHUP)) != 0 {
                            self.drop_conn(slot);
                            return;
                        }
                        break;
                    }
                    Some(sys::EINTR) => continue,
                    _ => {
                        self.drop_conn(slot);
                        return;
                    }
                }
            }
            if n == 0 {
                self.drop_conn(slot);
                return;
            }
            let n = n as usize;

            // Parse directly from self.scratch when the connection has no leftover bytes.
            if can_direct_parse && n < self.scratch.len() {
                let addr = ReplyAddr {
                    worker: self.worker_id,
                    slot,
                    epoch: self.slots[slot as usize].epoch,
                };
                match parse_one_http(self.signer, &self.scratch[..n], addr) {
                    ParseOutcome::Complete {
                        consumed,
                        close_after,
                        dispatch,
                    } => {
                        let c = &mut self.slots[slot as usize];
                        c.continue_sent = false;
                        c.close_on_done = close_after;
                        c.in_flight = true;
                        if consumed < n {
                            c.rx.extend_from_slice(&self.scratch[consumed..n]);
                        }
                        match dispatch {
                            Dispatch::Immediate(status, body) => {
                                self.write_response(slot, status, &body);
                                if !self.slots[slot as usize].rx.is_empty() {
                                    self.drain_rx_buf(slot);
                                }
                            }
                            Dispatch::Enqueued => {}
                        }
                        return;
                    }
                    ParseOutcome::Incomplete { send_continue } => {
                        let c = &mut self.slots[slot as usize];
                        c.rx.extend_from_slice(&self.scratch[..n]);
                        if send_continue && !c.continue_sent {
                            c.continue_sent = true;
                            self.write_raw_bytes(slot, b"HTTP/1.1 100 Continue\r\n\r\n");
                        }
                        return;
                    }
                    ParseOutcome::Reject(status) => {
                        self.reject_conn(slot, status);
                        return;
                    }
                }
            }

            let c = &mut self.slots[slot as usize];
            c.rx.extend_from_slice(&self.scratch[..n]);
            if n < self.scratch.len() {
                break;
            }
        }
        self.drain_rx_buf(slot);
    }

    fn drain_rx_buf(&mut self, slot: u32) {
        loop {
            let c = &mut self.slots[slot as usize];
            if c.fd < 0 || c.in_flight || c.rx.is_empty() {
                if c.fd >= 0 && c.rx.is_empty() {
                    if c.rx.capacity() > 4096 {
                        c.rx = Vec::new();
                    } else {
                        c.rx.clear();
                    }
                    if !c.in_flight && c.tx_off >= c.tx.len() && c.reused {
                        self.link_idle(slot);
                    }
                }
                return;
            }
            let addr = ReplyAddr {
                worker: self.worker_id,
                slot,
                epoch: c.epoch,
            };
            match parse_one_http(self.signer, &c.rx, addr) {
                ParseOutcome::Complete {
                    consumed,
                    close_after,
                    dispatch,
                } => {
                    c.continue_sent = false;
                    c.close_on_done = close_after;
                    c.in_flight = true;
                    if consumed == c.rx.len() {
                        c.rx = Vec::new();
                    } else {
                        c.rx.drain(..consumed);
                    }
                    match dispatch {
                        Dispatch::Immediate(status, body) => self.write_response(slot, status, &body),
                        Dispatch::Enqueued => return,
                    }
                }
                ParseOutcome::Incomplete { send_continue } => {
                    if send_continue && !c.continue_sent {
                        c.continue_sent = true;
                        self.write_raw_bytes(slot, b"HTTP/1.1 100 Continue\r\n\r\n");
                    }
                    return;
                }
                ParseOutcome::Reject(status) => {
                    self.reject_conn(slot, status);
                    return;
                }
            }
        }
    }

    fn reject_conn(&mut self, slot: u32, status: u16) {
        let c = &mut self.slots[slot as usize];
        c.close_on_done = true;
        c.in_flight = true;
        c.rx = Vec::new();
        let body = make_error_json(reason_phrase(status));
        self.write_response(slot, status, &body);
    }

    fn flush_outbox(&mut self) {
        let mut val: u64 = 0;
        unsafe {
            sys::read(self.outbox_fd, &mut val as *mut u64 as *mut sys::c_void, 8);
        }
        let mut replies = std::mem::take(&mut self.outbox_buf);
        replies.clear();
        {
            let mut pending = worker_outbox(self.worker_id as usize).pending.lock().unwrap();
            std::mem::swap(&mut replies, &mut *pending);
        }
        let mut check_pipelined = std::mem::take(&mut self.pipelined_slots);
        check_pipelined.clear();
        for rep in &replies {
            let c = &self.slots[rep.addr.slot as usize];
            if c.fd < 0 || c.epoch != rep.addr.epoch || !c.in_flight {
                continue;
            }
            let has_buffered_rx = !c.rx.is_empty();
            self.write_response(rep.addr.slot, rep.status, rep.body.as_slice());
            if has_buffered_rx {
                check_pipelined.push(rep.addr.slot);
            }
        }
        replies.clear();
        self.outbox_buf = replies;
        for &slot in &check_pipelined {
            self.drain_rx_buf(slot);
        }
        check_pipelined.clear();
        self.pipelined_slots = check_pipelined;
    }

    fn write_response(&mut self, slot: u32, status: u16, body: &[u8]) {
        let c = &mut self.slots[slot as usize];
        c.in_flight = false;
        c.reused = true;
        let mut hdr = [0u8; 160];
        let mut hlen = 0usize;
        let mut append = |bytes: &[u8]| {
            hdr[hlen..hlen + bytes.len()].copy_from_slice(bytes);
            hlen += bytes.len();
        };

        if status == 200 && !c.close_on_done {
            const PFX_200: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
            hdr[..PFX_200.len()].copy_from_slice(PFX_200);
            hlen = PFX_200.len();
            let mut num = [0u8; 20];
            let digits = codec::format_u64_into(body.len() as u64, &mut num);
            hdr[hlen..hlen + digits.len()].copy_from_slice(digits);
            hlen += digits.len();
            hdr[hlen..hlen + 4].copy_from_slice(b"\r\n\r\n");
            hlen += 4;
        } else if status == 204 {
            append(if c.close_on_done {
                b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
            } else {
                b"HTTP/1.1 204 No Content\r\n\r\n"
            });
        } else {
            append(b"HTTP/1.1 ");
            append(reason_phrase(status).as_bytes());
            append(b"\r\nContent-Type: application/json\r\nContent-Length: ");
            let mut num = [0u8; 20];
            append(codec::format_u64_into(body.len() as u64, &mut num));
            append(if c.close_on_done {
                b"\r\nConnection: close\r\n\r\n"
            } else {
                b"\r\n\r\n"
            });
        }

        let fd = c.fd;
        if c.tx.len() > c.tx_off {
            c.tx.extend_from_slice(&hdr[..hlen]);
            c.tx.extend_from_slice(body);
        } else {
            let iov = [
                sys::iovec {
                    iov_base: hdr.as_ptr() as *mut sys::c_void,
                    iov_len: hlen,
                },
                sys::iovec {
                    iov_base: body.as_ptr() as *mut sys::c_void,
                    iov_len: body.len(),
                },
            ];
            let total = hlen + body.len();
            let rc = unsafe { sys::writev(fd, iov.as_ptr(), if body.is_empty() { 1 } else { 2 }) };
            let written = if rc < 0 {
                let err = io::Error::last_os_error();
                if matches!(err.raw_os_error(), Some(sys::EAGAIN) | Some(sys::EINTR)) {
                    0
                } else {
                    self.drop_conn(slot);
                    return;
                }
            } else {
                rc as usize
            };
            if written < total {
                c.tx.clear();
                c.tx_off = 0;
                if written < hlen {
                    c.tx.extend_from_slice(&hdr[written..hlen]);
                    c.tx.extend_from_slice(body);
                } else {
                    c.tx.extend_from_slice(&body[written - hlen..]);
                }
            }
        }
        self.update_write_state(slot);
    }

    fn write_raw_bytes(&mut self, slot: u32, raw: &[u8]) {
        let c = &mut self.slots[slot as usize];
        if c.tx.len() > c.tx_off {
            c.tx.extend_from_slice(raw);
        } else {
            let rc = unsafe { sys::write(c.fd, raw.as_ptr() as *const sys::c_void, raw.len()) };
            let written = if rc < 0 {
                let err = io::Error::last_os_error();
                if matches!(err.raw_os_error(), Some(sys::EAGAIN) | Some(sys::EINTR)) {
                    0
                } else {
                    self.drop_conn(slot);
                    return;
                }
            } else {
                rc as usize
            };
            if written < raw.len() {
                c.tx.clear();
                c.tx_off = 0;
                c.tx.extend_from_slice(&raw[written..]);
            }
        }
        self.update_write_state(slot);
    }

    fn flush_tx(&mut self, slot: u32) {
        let c = &mut self.slots[slot as usize];
        if c.fd < 0 {
            return;
        }
        while c.tx_off < c.tx.len() {
            let rem = &c.tx[c.tx_off..];
            let rc = unsafe { sys::write(c.fd, rem.as_ptr() as *const sys::c_void, rem.len()) };
            if rc < 0 {
                let err = io::Error::last_os_error();
                match err.raw_os_error() {
                    Some(sys::EAGAIN) => break,
                    Some(sys::EINTR) => continue,
                    _ => {
                        self.drop_conn(slot);
                        return;
                    }
                }
            }
            c.tx_off += rc as usize;
        }
        self.update_write_state(slot);
    }

    fn update_write_state(&mut self, slot: u32) {
        let (has_unsent, should_drop, should_link_idle, mask_change) = {
            let c = &mut self.slots[slot as usize];
            if c.fd < 0 {
                return;
            }
            let has_unsent = c.tx_off < c.tx.len();
            if !has_unsent {
                if c.tx.capacity() > 4096 {
                    c.tx = Vec::new();
                } else {
                    c.tx.clear();
                }
                c.tx_off = 0;
            }
            let should_drop = !has_unsent && !c.in_flight && (c.close_on_done || c.eof_seen);
            let should_link_idle = !should_drop && !has_unsent && !c.in_flight && c.rx.is_empty() && c.reused;
            let mask_change = if !should_drop && has_unsent != c.polling_out {
                c.polling_out = has_unsent;
                let mask = if has_unsent {
                    sys::EPOLLIN | sys::EPOLLOUT | sys::EPOLLRDHUP
                } else {
                    sys::EPOLLIN | sys::EPOLLRDHUP
                };
                Some((c.fd, mask))
            } else {
                None
            };
            (has_unsent, should_drop, should_link_idle, mask_change)
        };
        if should_drop {
            self.drop_conn(slot);
            return;
        }
        if should_link_idle {
            self.link_idle(slot);
        } else if has_unsent {
            self.unlink_idle(slot);
        }
        if let Some((fd, mask)) = mask_change {
            let _ = self.ep_ctl(sys::EPOLL_CTL_MOD, fd, mask, slot as u64);
        }
    }
}

#[inline(always)]
fn trim_http_ows(mut s: &[u8]) -> &[u8] {
    while let [b' ' | b'\t', rest @ ..] = s {
        s = rest;
    }
    while let [rest @ .., b' ' | b'\t'] = s {
        s = rest;
    }
    s
}

#[inline(always)]
fn parse_usize_ascii(s: &[u8]) -> Option<usize> {
    if s.is_empty() {
        return None;
    }
    let mut val = 0usize;
    for &b in s {
        if !b.is_ascii_digit() {
            return None;
        }
        val = val.checked_mul(10)?.checked_add((b - b'0') as usize)?;
    }
    Some(val)
}

#[inline(always)]
fn is_valid_token_name(s: &[u8]) -> bool {
    !s.is_empty()
        && s.iter()
            .all(|&b| b > 0x20 && b < 0x7f && !matches!(b, b'(' | b')' | b'<' | b'>' | b'@' | b',' | b';' | b':' | b'\\' | b'"' | b'/' | b'[' | b']' | b'?' | b'=' | b'{' | b'}'))
}

#[inline]
fn parse_one_http(signer: &TokenSigner, buf: &[u8], addr: ReplyAddr) -> ParseOutcome {
    let Some(req_line_end) = codec::find_crlf(buf) else {
        if buf.len() > LIMIT_HEAD {
            return ParseOutcome::Reject(431);
        }
        return ParseOutcome::Incomplete {
            send_continue: false,
        };
    };
    let req_line = &buf[..req_line_end];
    let Some(sp1) = codec::find_byte(req_line, b' ') else {
        return ParseOutcome::Reject(400);
    };
    let method = &req_line[..sp1];
    if !is_valid_token_name(method) {
        return ParseOutcome::Reject(400);
    }
    let after_m = &req_line[sp1 + 1..];
    let Some(sp2) = codec::find_byte(after_m, b' ') else {
        return ParseOutcome::Reject(400);
    };
    let raw_target = &after_m[..sp2];
    if raw_target.is_empty() || raw_target.iter().any(|&b| b <= 0x20 || b == 0x7f) {
        return ParseOutcome::Reject(400);
    }
    let version = &after_m[sp2 + 1..];
    let is_http10 = match version {
        b"HTTP/1.1" => false,
        b"HTTP/1.0" => true,
        _ => return ParseOutcome::Reject(400),
    };

    let mut content_len: Option<usize> = None;
    let mut is_chunked = false;
    let mut auth_hdr: Option<&[u8]> = None;
    let mut keep_alive = !is_http10;
    let mut expect_100 = false;

    let mut pos = req_line_end + 2;
    let head_end = loop {
        let Some(line_len) = codec::find_crlf(&buf[pos..]) else {
            if buf.len() > LIMIT_HEAD {
                return ParseOutcome::Reject(431);
            }
            return ParseOutcome::Incomplete {
                send_continue: false,
            };
        };
        if pos + line_len + 2 > LIMIT_HEAD {
            return ParseOutcome::Reject(431);
        }
        if line_len == 0 {
            break pos + 2;
        }
        let line = &buf[pos..pos + line_len];
        pos += line_len + 2;

        let Some(colon) = codec::find_byte(line, b':') else {
            return ParseOutcome::Reject(400);
        };
        let name = &line[..colon];
        if !is_valid_token_name(name) {
            return ParseOutcome::Reject(400);
        }
        let val = trim_http_ows(&line[colon + 1..]);

        match name.len() {
            13 if name.eq_ignore_ascii_case(b"authorization") => {
                auth_hdr = Some(val);
            }
            14 if name.eq_ignore_ascii_case(b"content-length") => {
                let Some(n) = parse_usize_ascii(val) else {
                    return ParseOutcome::Reject(400);
                };
                if let Some(prev) = content_len {
                    if prev != n {
                        return ParseOutcome::Reject(400);
                    }
                }
                content_len = Some(n);
            }
            10 if name.eq_ignore_ascii_case(b"connection") => {
                if val.eq_ignore_ascii_case(b"close") {
                    keep_alive = false;
                } else if val.eq_ignore_ascii_case(b"keep-alive") {
                    keep_alive = true;
                }
            }
            17 if name.eq_ignore_ascii_case(b"transfer-encoding") => {
                is_chunked = val.eq_ignore_ascii_case(b"chunked");
                if !is_chunked {
                    return ParseOutcome::Reject(400);
                }
            }
            6 if name.eq_ignore_ascii_case(b"expect") => {
                expect_100 = val.eq_ignore_ascii_case(b"100-continue");
            }
            _ => {}
        }
    };

    if is_chunked && content_len.is_some() {
        return ParseOutcome::Reject(400);
    }

    let (path, query) = match codec::find_byte(raw_target, b'?') {
        Some(qpos) => (&raw_target[..qpos], &raw_target[qpos + 1..]),
        None => (raw_target, &b""[..]),
    };

    let unchunked: Vec<u8>;
    let (body_slice, total_consumed): (&[u8], usize) = if is_chunked {
        match decode_chunked_body(&buf[head_end..]) {
            ChunkResult::Complete(decoded, used) => {
                if decoded.len() > LIMIT_BODY {
                    return ParseOutcome::Reject(413);
                }
                unchunked = decoded;
                (&unchunked, head_end + used)
            }
            ChunkResult::Incomplete => {
                if buf.len() - head_end > LIMIT_BODY + 64 * 1024 {
                    return ParseOutcome::Reject(413);
                }
                return ParseOutcome::Incomplete {
                    send_continue: expect_100,
                };
            }
            ChunkResult::Malformed => return ParseOutcome::Reject(400),
        }
    } else {
        let cl = content_len.unwrap_or(0);
        if cl > LIMIT_BODY {
            return ParseOutcome::Reject(413);
        }
        if buf.len() < head_end + cl {
            return ParseOutcome::Incomplete {
                send_continue: expect_100,
            };
        }
        (&buf[head_end..head_end + cl], head_end + cl)
    };

    let http_req = HttpReq {
        method,
        path,
        query,
        auth: auth_hdr,
        body: body_slice,
    };
    let dispatch = router::route_request(signer, &http_req, addr);
    ParseOutcome::Complete {
        consumed: total_consumed,
        close_after: !keep_alive,
        dispatch,
    }
}

enum ChunkResult {
    Complete(Vec<u8>, usize),
    Incomplete,
    Malformed,
}

fn decode_chunked_body(src: &[u8]) -> ChunkResult {
    let mut out = Vec::new();
    let mut pos = 0;
    loop {
        let Some(crlf) = codec::find_crlf(&src[pos..]) else {
            return ChunkResult::Incomplete;
        };
        let line = &src[pos..pos + crlf];
        let hex_part = line.split(|&b| b == b';').next().unwrap_or(b"");
        let Ok(hex_str) = std::str::from_utf8(hex_part) else {
            return ChunkResult::Malformed;
        };
        let Ok(chunk_len) = usize::from_str_radix(hex_str.trim(), 16) else {
            return ChunkResult::Malformed;
        };
        pos += crlf + 2;
        if chunk_len == 0 {
            loop {
                let Some(end_line) = codec::find_crlf(&src[pos..]) else {
                    return ChunkResult::Incomplete;
                };
                pos += end_line + 2;
                if end_line == 0 {
                    return ChunkResult::Complete(out, pos);
                }
            }
        }
        if chunk_len > LIMIT_BODY || out.len() + chunk_len > LIMIT_BODY {
            return ChunkResult::Complete(vec![0; LIMIT_BODY + 1], pos);
        }
        if src.len() < pos + chunk_len + 2 {
            return ChunkResult::Incomplete;
        }
        out.extend_from_slice(&src[pos..pos + chunk_len]);
        if &src[pos + chunk_len..pos + chunk_len + 2] != b"\r\n" {
            return ChunkResult::Malformed;
        }
        pos += chunk_len + 2;
    }
}
