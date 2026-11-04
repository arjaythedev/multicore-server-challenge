//! Minimal io_uring wrapper backed by the `io-uring` crate.
//!
//! Preserves the single-threaded, multishot accept/recv + provided-buffer-ring
//! interface while delegating ring mmap, atomic head/tail tracking, and SQE
//! construction to `io_uring`.

use std::io;
use std::ptr;
use std::sync::atomic::{AtomicU16, Ordering};

use io_uring::{ opcode, squeue, types::Fd, IoUring };

pub const CQE_F_BUFFER: u32 = 1 << 0;
pub const CQE_F_MORE: u32 = 1 << 1;
pub const ENOBUFS: i32 = libc::ENOBUFS;

/// 16-byte completion queue entry matching the original public layout.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Cqe {
    pub user_data: u64,
    pub res: i32,
    pub flags: u32,
}

#[repr(C)]
struct BufEntry {
    addr: u64,
    len: u32,
    bid: u16,
    resv: u16,
}

pub struct Ring {
    ring: IoUring,
    // Provided buffer ring (single group)
    bufring: *mut u8,
    buf_base: *mut u8,
    buf_count: u32,
    buf_size: u32,
    buf_tail: u16,
    buf_dirty: bool,
    bgid: u16,
}

impl Ring {
    pub fn new(sq_entries: u32, cq_entries: u32) -> io::Result<Ring> {
        // Try 6.1+ SINGLE_ISSUER | DEFER_TASKRUN, then COOP_TASKRUN, then plain CQSIZE.
        let attempts: [fn(&mut io_uring::Builder); 3] = [
            |b| {
                b.setup_single_issuer().setup_defer_taskrun();
            },
            |b| {
                b.setup_coop_taskrun();
            },
            |_| {},
        ];

        let mut last_err = io::Error::from_raw_os_error(libc::ENOSYS);
        for configure in attempts {
            let mut builder = IoUring::builder();
            builder.setup_cqsize(cq_entries);
            configure(&mut builder);

            match builder.build(sq_entries) {
                Ok(ring) => {
                    return Ok(Ring {
                        ring,
                        bufring: ptr::null_mut(),
                        buf_base: ptr::null_mut(),
                        buf_count: 0,
                        buf_size: 0,
                        buf_tail: 0,
                        buf_dirty: false,
                        bgid: 0,
                    });
                }
                Err(e) => last_err = e,
            }
        }
        Err(last_err)
    }

    // ---------------------------------------------------------------- provided buffer ring

    /// Registers one provided-buffer ring (`count` must be a power of two) and fills it.
    pub fn setup_buf_ring(&mut self, bgid: u16, count: u32, size: u32) -> io::Result<()> {
        unsafe {
            let ring_bytes = ((count as usize * std::mem::size_of::<BufEntry>()) + 4095) & !4095;
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
                libc::munmap(ring_mem, ring_bytes);
                return Err(io::Error::last_os_error());
            }

            if let Err(e) = self.ring.submitter().register_buf_ring_with_flags(
                ring_mem as u64,
                count as u16,
                bgid,
                0,
            ) {
                libc::munmap(buf_mem, buf_bytes);
                libc::munmap(ring_mem, ring_bytes);
                return Err(e);
            }

            self.bufring = ring_mem as *mut u8;
            self.buf_base = buf_mem as *mut u8;
            self.buf_count = count;
            self.buf_size = size;
            self.buf_tail = 0;
            self.bgid = bgid;

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
            ptr::write(
                ptr::addr_of_mut!((*e).addr),
                self.buf_base as u64 + bid as u64 * self.buf_size as u64,
            );
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

    fn push_sqe(&mut self, entry: squeue::Entry) {
        unsafe {
            if self.ring.submission().push(&entry).is_err() {
                // SQ full: flush pending submissions to the kernel and retry.
                let _ = self.ring.submit();
                let _ = self.ring.submission().push(&entry);
            }
        }
    }

    /// Submits queued SQEs and waits until at least `want` completions are available.
    pub fn submit_and_wait(&mut self, want: u32) -> io::Result<()> {
        loop {
            match self.ring.submit_and_wait(want as usize) {
                Ok(_) => return Ok(()),
                Err(e) => match e.raw_os_error() {
                    Some(libc::EINTR) => continue,
                    Some(libc::EBUSY) | Some(libc::EAGAIN) => return Ok(()),
                    _ => return Err(e),
                },
            }
        }
    }

    pub fn push_accept_multi(&mut self, fd: i32, user_data: u64) {
        let entry = opcode::AcceptMulti::new(Fd(fd))
            .flags(libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC)
            .build()
            .user_data(user_data);
        self.push_sqe(entry);
    }

    /// Multishot recv that picks buffers from the provided ring `bgid`.
    pub fn push_recv_multishot(&mut self, fd: i32, bgid: u16, user_data: u64) {
        let entry = opcode::RecvMulti::new(Fd(fd), bgid)
            .build()
            .user_data(user_data);
        self.push_sqe(entry);
    }

    pub fn push_recv(&mut self, fd: i32, buf: *mut u8, len: u32, user_data: u64) {
        let entry = opcode::Recv::new(Fd(fd), buf, len)
            .build()
            .user_data(user_data);
        self.push_sqe(entry);
    }

    pub fn push_send(&mut self, fd: i32, buf: *const u8, len: u32, user_data: u64) {
        let entry = opcode::Send::new(Fd(fd), buf, len)
            .flags(libc::MSG_NOSIGNAL)
            .build()
            .user_data(user_data);
        self.push_sqe(entry);
    }

    pub fn push_read(&mut self, fd: i32, buf: *mut u8, len: u32, user_data: u64) {
        let entry = opcode::Read::new(Fd(fd), buf, len)
            .offset(0)
            .build()
            .user_data(user_data);
        self.push_sqe(entry);
    }

    // ---------------------------------------------------------------- completion

    #[inline]
    pub fn next_cqe(&mut self) -> Option<Cqe> {
        self.ring.completion().next().map(|cqe| Cqe {
            user_data: cqe.user_data(),
            res: cqe.result(),
            flags: cqe.flags(),
        })
    }

    /// Tells the kernel how many CQEs we have consumed.
    /// (`io_uring::CompletionQueue` also syncs automatically when dropped.)
    #[inline]
    pub fn cq_commit(&mut self) {
        self.ring.completion().sync();
    }
}

impl Drop for Ring {
    fn drop(&mut self) {
        if !self.bufring.is_null() {
            let _ = self.ring.submitter().unregister_buf_ring(self.bgid);
            unsafe {
                let ring_bytes =
                    ((self.buf_count as usize * std::mem::size_of::<BufEntry>()) + 4095) & !4095;
                libc::munmap(self.bufring as *mut libc::c_void, ring_bytes);
                libc::munmap(
                    self.buf_base as *mut libc::c_void,
                    self.buf_count as usize * self.buf_size as usize,
                );
            }
        }
    }
}