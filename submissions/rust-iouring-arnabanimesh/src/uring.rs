//! Minimal io_uring wrapper written directly against the kernel ABI (no extra crate).
//!
//! Why not the `io-uring` crate? Fewer moving parts and no API-version drift: everything this
//! server needs is accept (multishot), recv (multishot + provided buffer ring), send, read.
//! Struct layouts and constants were checked against <linux/io_uring.h>.
//!
//! The ring is created with SINGLE_ISSUER | DEFER_TASKRUN when the kernel supports it (6.1+),
//! falling back to COOP_TASKRUN and then to a plain ring. One `Ring` belongs to exactly one thread.

use std::io;
use std::ptr;
use std::sync::atomic::{AtomicU16, AtomicU32, Ordering};

const SYS_SETUP: libc::c_long = 425;
const SYS_ENTER: libc::c_long = 426;
const SYS_REGISTER: libc::c_long = 427;

const OP_ACCEPT: u8 = 13;
const OP_READ: u8 = 22;
const OP_SEND: u8 = 26;
const OP_RECV: u8 = 27;

const IOSQE_BUFFER_SELECT: u8 = 32;

const SETUP_CQSIZE: u32 = 1 << 3;
const SETUP_COOP_TASKRUN: u32 = 1 << 8;
const SETUP_SINGLE_ISSUER: u32 = 1 << 12;
const SETUP_DEFER_TASKRUN: u32 = 1 << 13;

const OFF_SQ_RING: u64 = 0;
const OFF_CQ_RING: u64 = 0x800_0000;
const OFF_SQES: u64 = 0x1000_0000;

const ENTER_GETEVENTS: u32 = 1;
const FEAT_SINGLE_MMAP: u32 = 1;
const REGISTER_PBUF_RING: u32 = 22;
const ACCEPT_MULTISHOT: u16 = 1;
const RECV_MULTISHOT: u16 = 2;

pub const CQE_F_BUFFER: u32 = 1;
pub const CQE_F_MORE: u32 = 2;
pub const ENOBUFS: i32 = 105;

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct SqOff {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    flags: u32,
    dropped: u32,
    array: u32,
    resv1: u32,
    user_addr: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct CqOff {
    head: u32,
    tail: u32,
    ring_mask: u32,
    ring_entries: u32,
    overflow: u32,
    cqes: u32,
    flags: u32,
    resv1: u32,
    user_addr: u64,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
struct Params {
    sq_entries: u32,
    cq_entries: u32,
    flags: u32,
    sq_thread_cpu: u32,
    sq_thread_idle: u32,
    features: u32,
    wq_fd: u32,
    resv: [u32; 3],
    sq_off: SqOff,
    cq_off: CqOff,
}

/// 64-byte submission queue entry.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Sqe {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    op_flags: u32,
    user_data: u64,
    buf_group: u16,
    personality: u16,
    splice_fd_in: i32,
    addr3: u64,
    pad: u64,
}

/// 16-byte completion queue entry.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Cqe {
    pub user_data: u64,
    pub res: i32,
    pub flags: u32,
}

#[repr(C)]
struct BufReg {
    ring_addr: u64,
    ring_entries: u32,
    bgid: u16,
    flags: u16,
    resv: [u64; 3],
}

#[repr(C)]
struct BufEntry {
    addr: u64,
    len: u32,
    bid: u16,
    resv: u16,
}

pub struct Ring {
    fd: i32,
    sq_head: *const AtomicU32,
    sq_tail: *const AtomicU32,
    sq_mask: u32,
    sq_entries: u32,
    sqes: *mut Sqe,
    cq_head: *const AtomicU32,
    cq_tail: *const AtomicU32,
    cq_mask: u32,
    cqes: *const Cqe,
    sq_tail_local: u32,
    sq_unsubmitted: u32,
    cq_head_local: u32,
    // provided buffer ring (single group)
    bufring: *mut u8,
    buf_base: *mut u8,
    buf_count: u32,
    buf_size: u32,
    buf_tail: u16,
    buf_dirty: bool,
}

impl Ring {
    pub fn new(sq_entries: u32, cq_entries: u32) -> io::Result<Ring> {
        let flag_sets: [u32; 3] = [
            SETUP_CQSIZE | SETUP_SINGLE_ISSUER | SETUP_DEFER_TASKRUN,
            SETUP_CQSIZE | SETUP_COOP_TASKRUN,
            SETUP_CQSIZE,
        ];
        let mut last = io::Error::from_raw_os_error(libc::ENOSYS);
        for fl in flag_sets.iter() {
            let mut p = Params::default();
            p.flags = *fl;
            p.cq_entries = cq_entries;
            let fd = unsafe {
                libc::syscall(SYS_SETUP, sq_entries as libc::c_long, &mut p as *mut Params)
            };
            if fd < 0 {
                last = io::Error::last_os_error();
                continue;
            }
            return Ring::map(fd as i32, &p);
        }
        Err(last)
    }

    fn map(fd: i32, p: &Params) -> io::Result<Ring> {
        unsafe {
            let single = p.features & FEAT_SINGLE_MMAP != 0;
            let mut sq_len = p.sq_off.array as usize + p.sq_entries as usize * 4;
            let mut cq_len =
                p.cq_off.cqes as usize + p.cq_entries as usize * std::mem::size_of::<Cqe>();
            if single {
                let m = if sq_len > cq_len { sq_len } else { cq_len };
                sq_len = m;
                cq_len = m;
            }
            let prot = libc::PROT_READ | libc::PROT_WRITE;
            let fl = libc::MAP_SHARED | libc::MAP_POPULATE;
            let sq_ptr = libc::mmap(ptr::null_mut(), sq_len, prot, fl, fd, OFF_SQ_RING as libc::off_t);
            if sq_ptr == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            let cq_ptr = if single {
                sq_ptr
            } else {
                let q = libc::mmap(ptr::null_mut(), cq_len, prot, fl, fd, OFF_CQ_RING as libc::off_t);
                if q == libc::MAP_FAILED {
                    return Err(io::Error::last_os_error());
                }
                q
            };
            let sqes_len = p.sq_entries as usize * std::mem::size_of::<Sqe>();
            let sqes = libc::mmap(ptr::null_mut(), sqes_len, prot, fl, fd, OFF_SQES as libc::off_t);
            if sqes == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            let sq = sq_ptr as *mut u8;
            let cq = cq_ptr as *mut u8;

            // Identity-map the SQ index array once: slot i always points at SQE i.
            let sq_array = sq.add(p.sq_off.array as usize) as *mut u32;
            for i in 0..p.sq_entries {
                *sq_array.add(i as usize) = i;
            }

            Ok(Ring {
                fd,
                sq_head: sq.add(p.sq_off.head as usize) as *const AtomicU32,
                sq_tail: sq.add(p.sq_off.tail as usize) as *const AtomicU32,
                sq_mask: *(sq.add(p.sq_off.ring_mask as usize) as *const u32),
                sq_entries: p.sq_entries,
                sqes: sqes as *mut Sqe,
                cq_head: cq.add(p.cq_off.head as usize) as *const AtomicU32,
                cq_tail: cq.add(p.cq_off.tail as usize) as *const AtomicU32,
                cq_mask: *(cq.add(p.cq_off.ring_mask as usize) as *const u32),
                cqes: cq.add(p.cq_off.cqes as usize) as *const Cqe,
                sq_tail_local: 0,
                sq_unsubmitted: 0,
                cq_head_local: 0,
                bufring: ptr::null_mut(),
                buf_base: ptr::null_mut(),
                buf_count: 0,
                buf_size: 0,
                buf_tail: 0,
                buf_dirty: false,
            })
        }
    }

    // ---------------------------------------------------------------- provided buffer ring

    /// Registers one provided-buffer ring (`count` must be a power of two) and fills it.
    pub fn setup_buf_ring(&mut self, bgid: u16, count: u32, size: u32) -> io::Result<()> {
        unsafe {
            let ring_bytes = ((count as usize * 16) + 4095) & !4095usize;
            let ring_mem = libc::mmap(
                ptr::null_mut(),
                ring_bytes,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_ANONYMOUS | libc::MAP_PRIVATE | libc::MAP_POPULATE,
                -1,
                0,
            );
            if ring_mem == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            let buf_bytes = count as usize * size as usize;
            let buf_mem = libc::mmap(
                ptr::null_mut(),
                buf_bytes,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_ANONYMOUS | libc::MAP_PRIVATE,
                -1,
                0,
            );
            if buf_mem == libc::MAP_FAILED {
                return Err(io::Error::last_os_error());
            }
            let reg = BufReg {
                ring_addr: ring_mem as u64,
                ring_entries: count,
                bgid,
                flags: 0,
                resv: [0; 3],
            };
            let r = libc::syscall(
                SYS_REGISTER,
                self.fd as libc::c_long,
                REGISTER_PBUF_RING as libc::c_long,
                &reg as *const BufReg,
                1 as libc::c_long,
            );
            if r < 0 {
                return Err(io::Error::last_os_error());
            }
            self.bufring = ring_mem as *mut u8;
            self.buf_base = buf_mem as *mut u8;
            self.buf_count = count;
            self.buf_size = size;
            self.buf_tail = 0;
            for i in 0..count {
                self.buf_add(i as u16);
            }
            self.buf_dirty = true;
            self.buf_publish();
        }
        Ok(())
    }

    fn buf_add(&mut self, bid: u16) {
        unsafe {
            let idx = (self.buf_tail as u32 & (self.buf_count - 1)) as usize;
            let e = (self.bufring as *mut BufEntry).add(idx);
            // Do not touch `resv`: for entry 0 it overlays the ring tail.
            ptr::write(ptr::addr_of_mut!((*e).addr), self.buf_base as u64 + bid as u64 * self.buf_size as u64);
            ptr::write(ptr::addr_of_mut!((*e).len), self.buf_size);
            ptr::write(ptr::addr_of_mut!((*e).bid), bid);
        }
        self.buf_tail = self.buf_tail.wrapping_add(1);
    }

    /// Hands a buffer back to the kernel (published on the next `buf_publish`).
    #[inline]
    pub fn buf_recycle(&mut self, bid: u16) {
        self.buf_add(bid);
        self.buf_dirty = true;
    }

    #[inline]
    pub fn buf_publish(&mut self) {
        if self.buf_dirty {
            unsafe {
                let tail = self.bufring.add(14) as *const AtomicU16;
                (*tail).store(self.buf_tail, Ordering::Release);
            }
            self.buf_dirty = false;
        }
    }

    /// Bytes the kernel wrote into provided buffer `bid`. Valid until the buffer is recycled.
    #[inline]
    pub fn buf_slice(&self, bid: u16, len: usize) -> &'static [u8] {
        unsafe {
            let p = self.buf_base.add(bid as usize * self.buf_size as usize);
            std::slice::from_raw_parts(p as *const u8, len)
        }
    }

    // ---------------------------------------------------------------- submission

    fn get_sqe(&mut self) -> &mut Sqe {
        loop {
            let head = unsafe { (*self.sq_head).load(Ordering::Acquire) };
            if self.sq_tail_local.wrapping_sub(head) < self.sq_entries {
                break;
            }
            // SQ full: let the kernel consume what we have.
            let _ = self.enter(0);
        }
        let idx = (self.sq_tail_local & self.sq_mask) as usize;
        self.sq_tail_local = self.sq_tail_local.wrapping_add(1);
        self.sq_unsubmitted += 1;
        unsafe {
            let p = self.sqes.add(idx);
            ptr::write_bytes(p, 0, 1);
            &mut *p
        }
    }

    fn enter(&mut self, min_complete: u32) -> io::Result<()> {
        unsafe {
            (*self.sq_tail).store(self.sq_tail_local, Ordering::Release);
        }
        loop {
            let ret = unsafe {
                libc::syscall(
                    SYS_ENTER,
                    self.fd as libc::c_long,
                    self.sq_unsubmitted as libc::c_long,
                    min_complete as libc::c_long,
                    ENTER_GETEVENTS as libc::c_long,
                    ptr::null::<libc::c_void>(),
                    0 as libc::c_long,
                )
            };
            if ret >= 0 {
                let n = ret as u32;
                self.sq_unsubmitted = self.sq_unsubmitted.saturating_sub(n);
                return Ok(());
            }
            let e = io::Error::last_os_error();
            match e.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::EBUSY) | Some(libc::EAGAIN) => return Ok(()),
                _ => return Err(e),
            }
        }
    }

    /// Submits queued SQEs and waits until at least `want` completions are available.
    pub fn submit_and_wait(&mut self, want: u32) -> io::Result<()> {
        self.enter(want)
    }

    pub fn push_accept_multi(&mut self, fd: i32, user_data: u64) {
        let s = self.get_sqe();
        s.opcode = OP_ACCEPT;
        s.fd = fd;
        s.ioprio = ACCEPT_MULTISHOT;
        s.op_flags = (libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC) as u32;
        s.user_data = user_data;
    }

    /// Multishot recv that picks buffers from the provided ring `bgid`.
    pub fn push_recv_multishot(&mut self, fd: i32, bgid: u16, user_data: u64) {
        let s = self.get_sqe();
        s.opcode = OP_RECV;
        s.fd = fd;
        s.ioprio = RECV_MULTISHOT;
        s.flags = IOSQE_BUFFER_SELECT;
        s.buf_group = bgid;
        s.user_data = user_data;
    }

    pub fn push_recv(&mut self, fd: i32, buf: *mut u8, len: u32, user_data: u64) {
        let s = self.get_sqe();
        s.opcode = OP_RECV;
        s.fd = fd;
        s.addr = buf as u64;
        s.len = len;
        s.user_data = user_data;
    }

    pub fn push_send(&mut self, fd: i32, buf: *const u8, len: u32, user_data: u64) {
        let s = self.get_sqe();
        s.opcode = OP_SEND;
        s.fd = fd;
        s.addr = buf as u64;
        s.len = len;
        s.op_flags = libc::MSG_NOSIGNAL as u32;
        s.user_data = user_data;
    }

    pub fn push_read(&mut self, fd: i32, buf: *mut u8, len: u32, user_data: u64) {
        let s = self.get_sqe();
        s.opcode = OP_READ;
        s.fd = fd;
        s.addr = buf as u64;
        s.len = len;
        s.off = 0;
        s.user_data = user_data;
    }

    // ---------------------------------------------------------------- completion

    #[inline]
    pub fn next_cqe(&mut self) -> Option<Cqe> {
        let tail = unsafe { (*self.cq_tail).load(Ordering::Acquire) };
        if self.cq_head_local == tail {
            return None;
        }
        let cqe = unsafe { *self.cqes.add((self.cq_head_local & self.cq_mask) as usize) };
        self.cq_head_local = self.cq_head_local.wrapping_add(1);
        Some(cqe)
    }

    /// Tells the kernel how many CQEs we have consumed.
    #[inline]
    pub fn cq_commit(&mut self) {
        unsafe {
            (*self.cq_head).store(self.cq_head_local, Ordering::Release);
        }
    }
}
