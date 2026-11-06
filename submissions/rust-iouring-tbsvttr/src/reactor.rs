use std::io;
use std::os::fd::RawFd;
use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

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
    pub const PRIO_PROCESS: c_int = 0;
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
    pub const TCP_QUICKACK: c_int = 12;
    pub const MADV_HUGEPAGE: c_int = 14;
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
        pub fn setpriority(which: c_int, who: u32, prio: c_int) -> c_int;
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
        pub fn madvise(addr: *mut c_void, length: usize, advice: c_int) -> c_int;
        pub fn mmap(
            addr: *mut c_void,
            length: usize,
            prot: c_int,
            flags: c_int,
            fd: c_int,
            offset: i64,
        ) -> *mut c_void;
        pub fn syscall(num: isize, ...) -> isize;
    }

    #[cfg(target_arch = "x86_64")]
    pub const SYS_IO_URING_SETUP: isize = 425;
    #[cfg(target_arch = "x86_64")]
    pub const SYS_IO_URING_ENTER: isize = 426;
    #[cfg(target_arch = "aarch64")]
    pub const SYS_IO_URING_SETUP: isize = 425;
    #[cfg(target_arch = "aarch64")]
    pub const SYS_IO_URING_ENTER: isize = 426;

    pub const PROT_READ: c_int = 1;
    pub const PROT_WRITE: c_int = 2;
    pub const MAP_SHARED: c_int = 1;
    pub const MAP_POPULATE: c_int = 0x8000;
    pub const IORING_OFF_SQ_RING: i64 = 0;
    pub const IORING_OFF_CQ_RING: i64 = 0x8000000;
    pub const IORING_OFF_SQES: i64 = 0x10000000;
    pub const IORING_FEAT_SINGLE_MMAP: u32 = 1 << 0;
    pub const IORING_SETUP_SINGLE_ISSUER: u32 = 1 << 12;
    pub const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13;
    pub const IORING_ENTER_GETEVENTS: u32 = 1 << 0;
    pub const IORING_OP_POLL_ADD: u8 = 6;
    pub const IORING_POLL_ADD_MULTI: u32 = 1 << 0;
    pub const IORING_CQE_F_MORE: u32 = 1 << 1;

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct io_sqring_offsets {
        pub head: u32,
        pub tail: u32,
        pub ring_mask: u32,
        pub ring_entries: u32,
        pub flags: u32,
        pub dropped: u32,
        pub array: u32,
        pub resv1: u32,
        pub user_addr: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct io_cqring_offsets {
        pub head: u32,
        pub tail: u32,
        pub ring_mask: u32,
        pub ring_entries: u32,
        pub overflow: u32,
        pub cqes: u32,
        pub flags: u32,
        pub resv1: u32,
        pub user_addr: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct io_uring_params {
        pub sq_entries: u32,
        pub cq_entries: u32,
        pub flags: u32,
        pub sq_thread_cpu: u32,
        pub sq_thread_idle: u32,
        pub features: u32,
        pub wq_fd: u32,
        pub resv: [u32; 3],
        pub sq_off: io_sqring_offsets,
        pub cq_off: io_cqring_offsets,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct io_uring_sqe {
        pub opcode: u8,
        pub flags: u8,
        pub ioprio: u16,
        pub fd: i32,
        pub off: u64,
        pub addr: u64,
        pub len: u32,
        pub op_flags: u32,
        pub user_data: u64,
        pub buf_group: u16,
        pub personality: u16,
        pub splice_fd_in: i32,
        pub addr3: u64,
        pub pad2: u64,
    }

    #[repr(C)]
    #[derive(Clone, Copy, Default)]
    pub struct io_uring_cqe {
        pub user_data: u64,
        pub res: i32,
        pub flags: u32,
    }
}

struct UringWaiter {
    ring_fd: RawFd,
    sq_ktail: *const AtomicU32,
    sq_mask: u32,
    sqes: *mut sys::io_uring_sqe,
    sq_tail_local: u32,
    cq_khead: *const AtomicU32,
    cq_ktail: *const AtomicU32,
    cq_mask: u32,
    cqes: *const sys::io_uring_cqe,
    ep_fd: RawFd,
    armed: bool,
}

impl UringWaiter {
    fn try_new(ep_fd: RawFd) -> Option<Self> {
        unsafe {
            let mut params = sys::io_uring_params {
                flags: sys::IORING_SETUP_SINGLE_ISSUER | sys::IORING_SETUP_DEFER_TASKRUN,
                ..sys::io_uring_params::default()
            };
            let mut fd = sys::syscall(
                sys::SYS_IO_URING_SETUP,
                64usize,
                &mut params as *mut sys::io_uring_params,
            );
            if fd < 0 {
                params = sys::io_uring_params::default();
                fd = sys::syscall(
                    sys::SYS_IO_URING_SETUP,
                    64usize,
                    &mut params as *mut sys::io_uring_params,
                );
            }
            if fd < 0 {
                return None;
            }
            let ring_fd = fd as RawFd;
            let sq_sz = (params.sq_off.array as usize) + (params.sq_entries as usize) * 4;
            let cq_sz = (params.cq_off.cqes as usize)
                + (params.cq_entries as usize) * std::mem::size_of::<sys::io_uring_cqe>();
            let sqes_sz = (params.sq_entries as usize) * std::mem::size_of::<sys::io_uring_sqe>();
            let map_sz = if (params.features & sys::IORING_FEAT_SINGLE_MMAP) != 0 {
                sq_sz.max(cq_sz)
            } else {
                sq_sz
            };
            let sq_ptr = sys::mmap(
                std::ptr::null_mut(),
                map_sz,
                sys::PROT_READ | sys::PROT_WRITE,
                sys::MAP_SHARED | sys::MAP_POPULATE,
                ring_fd,
                sys::IORING_OFF_SQ_RING,
            );
            if sq_ptr as isize == -1 {
                sys::close(ring_fd);
                return None;
            }
            let cq_ptr = if (params.features & sys::IORING_FEAT_SINGLE_MMAP) != 0 {
                sq_ptr
            } else {
                let p = sys::mmap(
                    std::ptr::null_mut(),
                    cq_sz,
                    sys::PROT_READ | sys::PROT_WRITE,
                    sys::MAP_SHARED | sys::MAP_POPULATE,
                    ring_fd,
                    sys::IORING_OFF_CQ_RING,
                );
                if p as isize == -1 {
                    sys::close(ring_fd);
                    return None;
                }
                p
            };
            let sqes_ptr = sys::mmap(
                std::ptr::null_mut(),
                sqes_sz,
                sys::PROT_READ | sys::PROT_WRITE,
                sys::MAP_SHARED | sys::MAP_POPULATE,
                ring_fd,
                sys::IORING_OFF_SQES,
            );
            if sqes_ptr as isize == -1 {
                sys::close(ring_fd);
                return None;
            }
            let sq_base = sq_ptr as *mut u8;
            let cq_base = cq_ptr as *mut u8;
            let sq_arr = sq_base.add(params.sq_off.array as usize) as *mut u32;
            for i in 0..params.sq_entries {
                *sq_arr.add(i as usize) = i;
            }
            let mut w = UringWaiter {
                ring_fd,
                sq_ktail: sq_base.add(params.sq_off.tail as usize) as *const AtomicU32,
                sq_mask: *(sq_base.add(params.sq_off.ring_mask as usize) as *const u32),
                sqes: sqes_ptr as *mut sys::io_uring_sqe,
                sq_tail_local: 0,
                cq_khead: cq_base.add(params.cq_off.head as usize) as *const AtomicU32,
                cq_ktail: cq_base.add(params.cq_off.tail as usize) as *const AtomicU32,
                cq_mask: *(cq_base.add(params.cq_off.ring_mask as usize) as *const u32),
                cqes: cq_base.add(params.cq_off.cqes as usize) as *const sys::io_uring_cqe,
                ep_fd,
                armed: false,
            };
            w.arm_poll();
            Some(w)
        }
    }

    #[inline]
    fn arm_poll(&mut self) {
        let idx = (self.sq_tail_local & self.sq_mask) as usize;
        unsafe {
            *self.sqes.add(idx) = sys::io_uring_sqe {
                opcode: sys::IORING_OP_POLL_ADD,
                fd: self.ep_fd,
                len: sys::IORING_POLL_ADD_MULTI,
                op_flags: sys::EPOLLIN,
                user_data: 1,
                ..sys::io_uring_sqe::default()
            };
        }
        self.sq_tail_local = self.sq_tail_local.wrapping_add(1);
        self.armed = true;
    }

    #[inline]
    fn wait_ep(&mut self) {
        if !self.armed {
            self.arm_poll();
        }
        unsafe {
            let ktail = (*self.sq_ktail).load(Ordering::Relaxed);
            let to_submit = self.sq_tail_local.wrapping_sub(ktail);
            if to_submit > 0 {
                (*self.sq_ktail).store(self.sq_tail_local, Ordering::Release);
            }
            let _ = sys::syscall(
                sys::SYS_IO_URING_ENTER,
                self.ring_fd as isize,
                to_submit as usize,
                1usize,
                sys::IORING_ENTER_GETEVENTS as usize,
                std::ptr::null::<sys::c_void>(),
                0usize,
            );
            let mut head = (*self.cq_khead).load(Ordering::Relaxed);
            let tail = (*self.cq_ktail).load(Ordering::Acquire);
            while head != tail {
                let cqe = *self.cqes.add((head & self.cq_mask) as usize);
                if (cqe.flags & sys::IORING_CQE_F_MORE) == 0 {
                    self.armed = false;
                }
                head = head.wrapping_add(1);
            }
            (*self.cq_khead).store(head, Ordering::Release);
        }
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

pub fn set_thread_nice(nice_val: i32) {
    unsafe {
        let _ = sys::setpriority(sys::PRIO_PROCESS, 0, nice_val);
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

#[derive(Clone)]
pub enum ReplyBody {
    Owned(Vec<u8>),
    Shared(Arc<[u8]>),
    Empty,
}

impl ReplyBody {
    #[inline(always)]
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

static OUTBOX_RING: AtomicPtr<WorkerOutbox> = AtomicPtr::new(std::ptr::null_mut());

pub fn init_outboxes(worker_count: usize, slot_cap: usize) {
    let cap = slot_cap.max(65536) + 512;
    let boxes: Vec<WorkerOutbox> = (0..worker_count)
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
    let ptr = Box::into_raw(boxes.into_boxed_slice()) as *mut WorkerOutbox;
    OUTBOX_RING.store(ptr, Ordering::Release);
}

#[inline(always)]
pub fn worker_outbox(worker: usize) -> &'static WorkerOutbox {
    unsafe { &*OUTBOX_RING.load(Ordering::Relaxed).add(worker) }
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

#[inline]
pub fn complete_reply(reply: OutgoingReply) {
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

pub fn complete_batch(replies: &mut Vec<OutgoingReply>) {
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

#[inline]
pub fn make_error_body(msg: &str) -> ReplyBody {
    ReplyBody::Owned(make_error_json(msg))
}

#[inline]
pub fn error_reply(addr: ReplyAddr, status: u16, msg: &str) -> OutgoingReply {
    OutgoingReply {
        addr,
        status,
        body: make_error_body(msg),
    }
}

const FLAG_IN_FLIGHT: u8 = 1 << 0;
const FLAG_CLOSE_ON_DONE: u8 = 1 << 1;
const FLAG_EOF_SEEN: u8 = 1 << 3;
const FLAG_POLLING_OUT: u8 = 1 << 4;
const FLAG_CONTINUE_SENT: u8 = 1 << 5;
const FLAG_REUSED: u8 = 1 << 6;
const FLAG_IN_IDLE_LRU: u8 = 1 << 7;

struct ClientSlot {
    rx: Vec<u8>,
    tx: Vec<u8>,
    fd: RawFd,
    epoch: u32,
    tx_off: u32,
    idle_prev: u32,
    idle_next: u32,
    flags: u8,
}

impl ClientSlot {
    #[inline(always)]
    fn flag(&self, mask: u8) -> bool {
        (self.flags & mask) != 0
    }
    #[inline(always)]
    fn set_flag(&mut self, mask: u8, val: bool) {
        if val {
            self.flags |= mask;
        } else {
            self.flags &= !mask;
        }
    }
}

pub struct Reactor {
    worker_id: u16,
    ep_fd: RawFd,
    uring: Option<UringWaiter>,
    listen_fd: RawFd,
    outbox_fd: RawFd,
    slots: Vec<ClientSlot>,
    free_slots: Vec<u32>,
    scratch: Vec<u8>,
    outbox_buf: Vec<OutgoingReply>,
    pipelined_slots: Vec<u32>,
    pending_reads: [Vec<crate::engine::ReadTask>; 3],
    batch_now: std::time::Instant,
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
    if host == "0.0.0.0" {
        if let Ok(fd) = bind_listener_inner("::", port) {
            return Ok(fd);
        }
    }
    bind_listener_inner(host, port)
}

fn bind_listener_inner(host: &str, port: u16) -> io::Result<RawFd> {
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
            if let Err(e) = sys_cvt(sys::setsockopt(
                fd,
                sys::SOL_SOCKET,
                opt,
                &yes as *const _ as *const sys::c_void,
                4,
            )) {
                sys::close(fd);
                return Err(e);
            }
        }
        let _ = sys::setsockopt(
            fd,
            sys::IPPROTO_TCP,
            sys::TCP_NODELAY,
            &yes as *const _ as *const sys::c_void,
            4,
        );
        let bind_res = match ip {
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
                ))
            }
            std::net::IpAddr::V6(v6) => {
                let _ = sys::setsockopt(
                    fd,
                    sys::IPPROTO_IPV6,
                    sys::IPV6_V6ONLY,
                    &no as *const _ as *const sys::c_void,
                    4,
                );
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
                ))
            }
        };
        if let Err(e) = bind_res {
            sys::close(fd);
            return Err(e);
        }
        if let Err(e) = sys_cvt(sys::listen(fd, 65535)) {
            sys::close(fd);
            return Err(e);
        }
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
        let mut slots = Vec::with_capacity(16384);
        let mut scratch = vec![0; 256 * 1024];
        unsafe {
            let _ = sys::madvise(
                scratch.as_mut_ptr() as *mut sys::c_void,
                scratch.capacity(),
                sys::MADV_HUGEPAGE,
            );
            let _ = sys::madvise(
                slots.as_mut_ptr() as *mut sys::c_void,
                slots.capacity() * std::mem::size_of::<ClientSlot>(),
                sys::MADV_HUGEPAGE,
            );
        }
        let reactor = Reactor {
            worker_id,
            ep_fd,
            uring: UringWaiter::try_new(ep_fd),
            listen_fd,
            outbox_fd,
            slots,
            free_slots: Vec::with_capacity(4096),
            scratch,
            outbox_buf: Vec::with_capacity(1024),
            pipelined_slots: Vec::with_capacity(256),
            pending_reads: [
                Vec::with_capacity(128),
                Vec::with_capacity(128),
                Vec::with_capacity(128),
            ],
            batch_now: std::time::Instant::now(),
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
    fn flush_pending_reads(&mut self) {
        for lane in 0..3 {
            if !self.pending_reads[lane].is_empty() {
                crate::engine::enqueue_read_batch_lane(
                    lane,
                    &mut self.pending_reads[lane],
                    self.batch_now,
                );
            }
        }
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
        if c.flag(FLAG_IN_IDLE_LRU) || c.fd < 0 {
            return;
        }
        c.set_flag(FLAG_IN_IDLE_LRU, true);
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
            if !c.flag(FLAG_IN_IDLE_LRU) {
                return;
            }
            c.set_flag(FLAG_IN_IDLE_LRU, false);
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
            let n = if let Some(u) = &mut self.uring {
                let fast = unsafe {
                    sys::epoll_wait(self.ep_fd, events.as_mut_ptr(), events.len() as i32, 0)
                };
                if fast != 0 {
                    fast
                } else {
                    u.wait_ep();
                    unsafe {
                        sys::epoll_wait(self.ep_fd, events.as_mut_ptr(), events.len() as i32, 0)
                    }
                }
            } else {
                unsafe { sys::epoll_wait(self.ep_fd, events.as_mut_ptr(), events.len() as i32, -1) }
            };
            if n <= 0 {
                if n < 0 {
                    let err = io::Error::last_os_error();
                    if err.kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    panic!("epoll_wait failed: {err}");
                }
                continue;
            }
            self.batch_now = std::time::Instant::now();
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
                if (i & 63) == 63 {
                    self.flush_pending_reads();
                }
            }
            self.flush_pending_reads();
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
            let (slot, epoch) = match self.free_slots.pop() {
                Some(idx) => {
                    let c = &mut self.slots[idx as usize];
                    c.fd = fd;
                    c.flags = 0;
                    c.idle_prev = IDLE_NONE;
                    c.idle_next = IDLE_NONE;
                    c.tx_off = 0;
                    (idx, c.epoch)
                }
                None => {
                    self.slots.push(ClientSlot {
                        rx: Vec::new(),
                        tx: Vec::new(),
                        fd,
                        epoch: 0,
                        tx_off: 0,
                        idle_prev: IDLE_NONE,
                        idle_next: IDLE_NONE,
                        flags: 0,
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
        c.flags = 0;
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
                (c.fd, first_read && !c.flag(FLAG_IN_FLIGHT) && c.rx.is_empty())
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
                match parse_one_http(
                    self.signer,
                    &self.scratch[..n],
                    addr,
                    self.batch_now,
                    &mut self.pending_reads,
                ) {
                    ParseOutcome::Complete {
                        consumed,
                        close_after,
                        dispatch,
                    } => {
                        let c = &mut self.slots[slot as usize];
                        c.set_flag(FLAG_CONTINUE_SENT, false);
                        c.set_flag(FLAG_CLOSE_ON_DONE, close_after);
                        c.set_flag(FLAG_IN_FLIGHT, true);
                        if consumed < n {
                            c.rx.extend_from_slice(&self.scratch[consumed..n]);
                        }
                        match dispatch {
                            Dispatch::Immediate(status, body) => {
                                self.write_response(slot, status, body.as_slice());
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
                        if send_continue && !c.flag(FLAG_CONTINUE_SENT) {
                            c.set_flag(FLAG_CONTINUE_SENT, true);
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
            if c.fd < 0 || c.flag(FLAG_IN_FLIGHT) || c.rx.is_empty() {
                if c.fd >= 0 && c.rx.is_empty() {
                    if c.rx.capacity() > 4096 {
                        c.rx = Vec::new();
                    } else {
                        c.rx.clear();
                    }
                    if !c.flag(FLAG_IN_FLIGHT) && (c.tx_off as usize) >= c.tx.len() && c.flag(FLAG_REUSED) {
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
            match parse_one_http(
                self.signer,
                &c.rx,
                addr,
                self.batch_now,
                &mut self.pending_reads,
            ) {
                ParseOutcome::Complete {
                    consumed,
                    close_after,
                    dispatch,
                } => {
                    c.set_flag(FLAG_CONTINUE_SENT, false);
                    c.set_flag(FLAG_CLOSE_ON_DONE, close_after);
                    c.set_flag(FLAG_IN_FLIGHT, true);
                    if consumed == c.rx.len() {
                        c.rx = Vec::new();
                    } else {
                        c.rx.drain(..consumed);
                    }
                    match dispatch {
                        Dispatch::Immediate(status, body) => {
                            self.write_response(slot, status, body.as_slice())
                        }
                        Dispatch::Enqueued => return,
                    }
                }
                ParseOutcome::Incomplete { send_continue } => {
                    if send_continue && !c.flag(FLAG_CONTINUE_SENT) {
                        c.set_flag(FLAG_CONTINUE_SENT, true);
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
        c.set_flag(FLAG_CLOSE_ON_DONE, true);
        c.set_flag(FLAG_IN_FLIGHT, true);
        c.rx = Vec::new();
        let body = make_error_body(reason_phrase(status));
        self.write_response(slot, status, body.as_slice());
    }

    fn flush_outbox(&mut self) {
        let mut val: u64 = 0;
        unsafe {
            sys::read(self.outbox_fd, &mut val as *mut u64 as *mut sys::c_void, 8);
        }
        let mut replies = std::mem::take(&mut self.outbox_buf);
        replies.clear();
        const MAX_OUTBOX_BATCH: usize = 256;
        let more_pending = {
            let mut pending = worker_outbox(self.worker_id as usize).pending.lock().unwrap();
            if pending.len() <= MAX_OUTBOX_BATCH {
                std::mem::swap(&mut replies, &mut *pending);
                false
            } else {
                replies.extend(pending.drain(..MAX_OUTBOX_BATCH));
                true
            }
        };
        if more_pending {
            signal_eventfd(self.outbox_fd);
        }
        let mut check_pipelined = std::mem::take(&mut self.pipelined_slots);
        check_pipelined.clear();
        for rep in &replies {
            let c = &self.slots[rep.addr.slot as usize];
            if c.fd < 0 || c.epoch != rep.addr.epoch || !c.flag(FLAG_IN_FLIGHT) {
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

    fn write_response(&mut self, slot: u32, status: u16, payload: &[u8]) {
        let c = &mut self.slots[slot as usize];
        c.set_flag(FLAG_IN_FLIGHT, false);
        c.set_flag(FLAG_REUSED, true);
        let close_on_done = c.flag(FLAG_CLOSE_ON_DONE);
        let mut hdr = [0u8; 160];
        let mut hlen = 0usize;
        let mut append = |bytes: &[u8]| {
            hdr[hlen..hlen + bytes.len()].copy_from_slice(bytes);
            hlen += bytes.len();
        };

        if status == 200 && !close_on_done {
            const PFX_200: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
            hdr[..PFX_200.len()].copy_from_slice(PFX_200);
            hlen = PFX_200.len();
            let mut num = [0u8; 20];
            let digits = codec::format_u64_into(payload.len() as u64, &mut num);
            hdr[hlen..hlen + digits.len()].copy_from_slice(digits);
            hlen += digits.len();
            hdr[hlen..hlen + 4].copy_from_slice(b"\r\n\r\n");
            hlen += 4;
        } else if status == 204 {
            append(if close_on_done {
                b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
            } else {
                b"HTTP/1.1 204 No Content\r\n\r\n"
            });
        } else {
            append(b"HTTP/1.1 ");
            append(reason_phrase(status).as_bytes());
            append(b"\r\nContent-Type: application/json\r\nContent-Length: ");
            let mut num = [0u8; 20];
            append(codec::format_u64_into(payload.len() as u64, &mut num));
            append(if close_on_done {
                b"\r\nConnection: close\r\n\r\n"
            } else {
                b"\r\n\r\n"
            });
        }

        let fd = c.fd;
        if c.tx.len() > c.tx_off as usize {
            c.tx.extend_from_slice(&hdr[..hlen]);
            c.tx.extend_from_slice(payload);
        } else {
            let iov = [
                sys::iovec {
                    iov_base: hdr.as_ptr() as *mut sys::c_void,
                    iov_len: hlen,
                },
                sys::iovec {
                    iov_base: payload.as_ptr() as *mut sys::c_void,
                    iov_len: payload.len(),
                },
            ];
            let total = hlen + payload.len();
            let rc = unsafe { sys::writev(fd, iov.as_ptr(), if payload.is_empty() { 1 } else { 2 }) };
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
                    c.tx.extend_from_slice(payload);
                } else {
                    c.tx.extend_from_slice(&payload[written - hlen..]);
                }
            }
        }
        self.update_write_state(slot);
    }

    fn write_raw_bytes(&mut self, slot: u32, raw: &[u8]) {
        let c = &mut self.slots[slot as usize];
        if c.tx.len() > c.tx_off as usize {
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
        while (c.tx_off as usize) < c.tx.len() {
            let rem = &c.tx[c.tx_off as usize..];
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
            c.tx_off += rc as u32;
        }
        self.update_write_state(slot);
    }

    fn update_write_state(&mut self, slot: u32) {
        let (has_unsent, should_drop, should_link_idle, mask_change) = {
            let c = &mut self.slots[slot as usize];
            if c.fd < 0 {
                return;
            }
            let has_unsent = (c.tx_off as usize) < c.tx.len();
            if !has_unsent {
                if c.tx.capacity() > 4096 {
                    c.tx = Vec::new();
                } else {
                    c.tx.clear();
                }
                c.tx_off = 0;
            }
            let in_flight = c.flag(FLAG_IN_FLIGHT);
            let should_drop = !has_unsent && !in_flight && (c.flag(FLAG_CLOSE_ON_DONE) || c.flag(FLAG_EOF_SEEN));
            let should_link_idle = !should_drop && !has_unsent && !in_flight && c.rx.is_empty() && c.flag(FLAG_REUSED);
            let mask_change = if !should_drop && has_unsent != c.flag(FLAG_POLLING_OUT) {
                c.set_flag(FLAG_POLLING_OUT, has_unsent);
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

const TCHAR_LUT: [bool; 256] = {
    let mut t = [false; 256];
    let mut b = 0x21usize;
    while b < 0x7f {
        t[b] = !matches!(
            b as u8,
            b'(' | b')'
                | b'<'
                | b'>'
                | b'@'
                | b','
                | b';'
                | b':'
                | b'\\'
                | b'"'
                | b'/'
                | b'['
                | b']'
                | b'?'
                | b'='
                | b'{'
                | b'}'
        );
        b += 1;
    }
    t
};

#[inline(always)]
fn is_valid_token_name(s: &[u8]) -> bool {
    !s.is_empty() && s.iter().all(|&b| TCHAR_LUT[b as usize])
}

#[inline(always)]
fn eq_hdr8(name: &[u8], prefix8: &[u8; 8], tail: &[u8]) -> bool {
    let w = u64::from_le_bytes(name[..8].try_into().unwrap()) | 0x2020_2020_2020_2020;
    w == u64::from_le_bytes(*prefix8) && name[8..].eq_ignore_ascii_case(tail)
}

#[inline]
fn parse_one_http(
    signer: &TokenSigner,
    buf: &[u8],
    addr: ReplyAddr,
    now: std::time::Instant,
    pending_reads: &mut [Vec<crate::engine::ReadTask>; 3],
) -> ParseOutcome {
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
            13 if eq_hdr8(name, b"authoriz", b"ation") => {
                auth_hdr = Some(val);
            }
            14 if eq_hdr8(name, b"content-", b"length") => {
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
            10 if eq_hdr8(name, b"connecti", b"on") => {
                if val.eq_ignore_ascii_case(b"close") {
                    keep_alive = false;
                } else if val.eq_ignore_ascii_case(b"keep-alive") {
                    keep_alive = true;
                }
            }
            17 if eq_hdr8(name, b"transfer", b"-encoding") => {
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
    let dispatch = router::route_request(signer, &http_req, addr, now, pending_reads);
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
