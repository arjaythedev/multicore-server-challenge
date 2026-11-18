//! Linux io_uring syscall interface and user-space ring management.
//! Implements SINGLE_ISSUER + DEFER_TASKRUN + COOP_TASKRUN with direct descriptor support.

use std::os::unix::io::RawFd;
use std::sync::atomic::{fence, Ordering};

pub const IORING_SETUP_SQPOLL: u32 = 1 << 1;
pub const IORING_SETUP_CQSIZE: u32 = 1 << 3;
pub const IORING_SETUP_CLAMP: u32 = 1 << 4;
pub const IORING_SETUP_ATTACH_WQ: u32 = 1 << 5;
pub const IORING_SETUP_R_DISABLED: u32 = 1 << 6;
pub const IORING_SETUP_SUBMIT_ALL: u32 = 1 << 7;
pub const IORING_SETUP_COOP_TASKRUN: u32 = 1 << 8;
pub const IORING_SETUP_TASKRUN_FLAG: u32 = 1 << 9;
pub const IORING_SETUP_SQE128: u32 = 1 << 10;
pub const IORING_SETUP_CQE32: u32 = 1 << 11;
pub const IORING_SETUP_SINGLE_ISSUER: u32 = 1 << 12;
pub const IORING_SETUP_DEFER_TASKRUN: u32 = 1 << 13;

pub const IORING_OP_NOP: u8 = 0;
pub const IORING_OP_READV: u8 = 1;
pub const IORING_OP_WRITEV: u8 = 2;
pub const IORING_OP_POLL_ADD: u8 = 6;
pub const IORING_OP_SENDMSG: u8 = 9;
pub const IORING_OP_RECVMSG: u8 = 10;
pub const IORING_OP_TIMEOUT: u8 = 11;
pub const IORING_OP_ACCEPT: u8 = 13;
pub const IORING_OP_READ: u8 = 22;
pub const IORING_OP_SEND: u8 = 26;
pub const IORING_OP_RECV: u8 = 27;
pub const IORING_OP_CLOSE: u8 = 19;
pub const IORING_OP_ASYNC_CANCEL: u8 = 14;

pub const IOSQE_FIXED_FILE: u8 = 1 << 0;
pub const IOSQE_IO_DRAIN: u8 = 1 << 1;
pub const IOSQE_IO_LINK: u8 = 1 << 2;
pub const IOSQE_IO_HARDLINK: u8 = 1 << 3;
pub const IOSQE_ASYNC: u8 = 1 << 4;
pub const IOSQE_BUFFER_SELECT: u8 = 1 << 5;
pub const IOSQE_CQE_SKIP_SUCCESS: u8 = 1 << 6;

pub const IORING_ENTER_GETEVENTS: u32 = 1 << 0;
pub const IORING_ENTER_EXT_ARG: u32 = 1 << 3;

pub const IORING_CQE_F_MORE: u32 = 1 << 1;
pub const IORING_CQE_F_BUFFER: u32 = 1 << 0;

pub const IORING_ACCEPT_MULTISHOT: u16 = 1 << 0;
pub const IORING_RECV_MULTISHOT: u16 = 1 << 1;

pub const IORING_FILE_INDEX_ALLOC: u32 = !0u32;
pub const IORING_REGISTER_FILES2: u32 = 13;
pub const IORING_RSRC_REGISTER_SPARSE: u32 = 1;
pub const IORING_REGISTER_PBUF_RING: u32 = 22;
pub const IORING_UNREGISTER_PBUF_RING: u32 = 23;

pub const IORING_OFF_SQ_RING: u64 = 0;
pub const IORING_OFF_CQ_RING: u64 = 0x8000000;
pub const IORING_OFF_SQES: u64 = 0x10000000;
pub const IORING_FEAT_SINGLE_MMAP: u32 = 1 << 3;

#[repr(C)]
pub struct io_uring_sqe {
    pub opcode: u8,
    pub flags: u8,
    pub ioprio: u16,
    pub fd: i32,
    pub off_or_addr2: u64,
    pub addr: u64,
    pub len: u32,
    pub op_flags: u32,
    pub user_data: u64,
    pub buf_index: u16,
    pub personality: u16,
    pub file_index: u32,
    pub pad2: [u64; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct io_uring_cqe {
    pub user_data: u64,
    pub res: i32,
    pub flags: u32,
}

#[repr(C)]
#[derive(Default)]
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
#[derive(Default)]
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
#[derive(Default)]
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
pub struct io_uring_rsrc_register {
    pub nr: u32,
    pub flags: u32,
    pub resv2: u64,
    pub data: u64,
    pub tags: u64,
}

#[repr(C)]
pub struct kernel_timespec {
    pub tv_sec: i64,
    pub tv_nsec: i64,
}

#[repr(C)]
pub struct io_uring_getevents_arg {
    pub sigmask: u64,
    pub sigmask_sz: u32,
    pub pad: u32,
    pub ts: u64,
}

pub struct IoUringInstance {
    pub fd: RawFd,
    pub sq_khead: *const u32,
    pub sq_ktail: *mut u32,
    pub sq_array: *mut u32,
    pub sq_mask: u32,
    pub sq_entries: u32,
    pub sq_tail: u32,

    pub cq_khead: *mut u32,
    pub cq_ktail: *const u32,
    pub cq_mask: u32,

    pub sqes: *mut io_uring_sqe,
    pub cqes: *mut io_uring_cqe,

    pub sq_mmap_ptr: *mut libc::c_void,
    pub sq_mmap_sz: usize,
    pub cq_mmap_ptr: *mut libc::c_void,
    pub cq_mmap_sz: usize,
    pub sqes_mmap_ptr: *mut libc::c_void,
    pub sqes_mmap_sz: usize,
}

impl IoUringInstance {
    pub fn new(entries: u32, cq_entries: u32) -> Result<Self, i32> {
        let mut p = io_uring_params::default();
        p.cq_entries = cq_entries;
        p.flags = IORING_SETUP_CQSIZE
            | IORING_SETUP_SINGLE_ISSUER
            | IORING_SETUP_DEFER_TASKRUN
            | IORING_SETUP_COOP_TASKRUN
            | IORING_SETUP_TASKRUN_FLAG;

        let fd = unsafe {
            libc::syscall(
                libc::SYS_io_uring_setup,
                entries as libc::c_uint,
                &mut p as *mut io_uring_params,
            ) as RawFd
        };

        if fd < 0 {
            // Fallback: try basic setup without modern defer flags
            let mut p_fallback = io_uring_params::default();
            p_fallback.cq_entries = cq_entries;
            p_fallback.flags = IORING_SETUP_CQSIZE;
            let fd_fb = unsafe {
                libc::syscall(
                    libc::SYS_io_uring_setup,
                    entries as libc::c_uint,
                    &mut p_fallback as *mut io_uring_params,
                ) as RawFd
            };
            if fd_fb < 0 {
                return Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1));
            }
            return Self::from_setup(fd_fb, p_fallback);
        }

        Self::from_setup(fd, p)
    }

    fn from_setup(fd: RawFd, p: io_uring_params) -> Result<Self, i32> {
        let sq_ring_sz = (p.sq_off.array as usize) + (p.sq_entries as usize) * std::mem::size_of::<u32>();
        let cq_ring_sz = (p.cq_off.cqes as usize) + (p.cq_entries as usize) * std::mem::size_of::<io_uring_cqe>();

        let single_mmap = (p.features & IORING_FEAT_SINGLE_MMAP) != 0;
        let sq_mmap_len = if single_mmap {
            sq_ring_sz.max(cq_ring_sz)
        } else {
            sq_ring_sz
        };

        let sq_ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                sq_mmap_len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED | libc::MAP_POPULATE,
                fd,
                IORING_OFF_SQ_RING as libc::off_t,
            )
        };
        if sq_ptr == libc::MAP_FAILED {
            unsafe { libc::close(fd) };
            return Err(-1);
        }

        let (cq_ptr, cq_mmap_sz) = if single_mmap {
            (sq_ptr, 0)
        } else {
            let ptr = unsafe {
                libc::mmap(
                    std::ptr::null_mut(),
                    cq_ring_sz,
                    libc::PROT_READ | libc::PROT_WRITE,
                    libc::MAP_SHARED | libc::MAP_POPULATE,
                    fd,
                    IORING_OFF_CQ_RING as libc::off_t,
                )
            };
            if ptr == libc::MAP_FAILED {
                unsafe {
                    libc::munmap(sq_ptr, sq_mmap_len);
                    libc::close(fd);
                };
                return Err(-1);
            }
            (ptr, cq_ring_sz)
        };

        let sqes_sz = (p.sq_entries as usize) * std::mem::size_of::<io_uring_sqe>();
        let sqes_ptr = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                sqes_sz,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED | libc::MAP_POPULATE,
                fd,
                IORING_OFF_SQES as libc::off_t,
            )
        };
        if sqes_ptr == libc::MAP_FAILED {
            unsafe {
                if cq_mmap_sz > 0 { libc::munmap(cq_ptr, cq_mmap_sz); }
                libc::munmap(sq_ptr, sq_mmap_len);
                libc::close(fd);
            };
            return Err(-1);
        }

        let sq_khead = unsafe { (sq_ptr as *const u8).add(p.sq_off.head as usize) as *const u32 };
        let sq_ktail = unsafe { (sq_ptr as *mut u8).add(p.sq_off.tail as usize) as *mut u32 };
        let sq_array = unsafe { (sq_ptr as *mut u8).add(p.sq_off.array as usize) as *mut u32 };

        let cq_khead = unsafe { (cq_ptr as *mut u8).add(p.cq_off.head as usize) as *mut u32 };
        let cq_ktail = unsafe { (cq_ptr as *const u8).add(p.cq_off.tail as usize) as *const u32 };
        let cqes = unsafe { (cq_ptr as *mut u8).add(p.cq_off.cqes as usize) as *mut io_uring_cqe };

        let sq_mask = unsafe { *((sq_ptr as *const u8).add(p.sq_off.ring_mask as usize) as *const u32) };
        let cq_mask = unsafe { *((cq_ptr as *const u8).add(p.cq_off.ring_mask as usize) as *const u32) };

        let sq_tail = unsafe { *sq_ktail };

        Ok(IoUringInstance {
            fd,
            sq_khead,
            sq_ktail,
            sq_array,
            sq_mask,
            sq_entries: p.sq_entries,
            sq_tail,
            cq_khead,
            cq_ktail,
            cq_mask,
            sqes: sqes_ptr as *mut io_uring_sqe,
            cqes,
            sq_mmap_ptr: sq_ptr,
            sq_mmap_sz: sq_mmap_len,
            cq_mmap_ptr: cq_ptr,
            cq_mmap_sz,
            sqes_mmap_ptr: sqes_ptr,
            sqes_mmap_sz: sqes_sz,
        })
    }

    pub fn register_sparse_files(&self, nr: u32) -> Result<(), i32> {
        let rsrc = io_uring_rsrc_register {
            nr,
            flags: IORING_RSRC_REGISTER_SPARSE,
            resv2: 0,
            data: 0,
            tags: 0,
        };
        let rc = unsafe {
            libc::syscall(
                libc::SYS_io_uring_register,
                self.fd,
                IORING_REGISTER_FILES2 as libc::c_uint,
                &rsrc as *const _ as *const libc::c_void,
                std::mem::size_of::<io_uring_rsrc_register>() as libc::c_uint,
            )
        };
        if rc < 0 {
            Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1))
        } else {
            Ok(())
        }
    }

    #[inline(always)]
    pub fn get_sqe(&mut self) -> Option<&mut io_uring_sqe> {
        let head = unsafe { std::ptr::read_volatile(self.sq_khead) };
        if self.sq_tail.wrapping_sub(head) >= self.sq_entries {
            return None; // SQ ring is full
        }

        let idx = self.sq_tail & self.sq_mask;
        let sqe = unsafe { &mut *self.sqes.offset(idx as isize) };
        unsafe {
            std::ptr::write_bytes(sqe as *mut io_uring_sqe, 0, 1);
            let array_slot = self.sq_array.offset(idx as isize);
            std::ptr::write_volatile(array_slot, idx);
        }
        self.sq_tail = self.sq_tail.wrapping_add(1);
        Some(sqe)
    }

    /// Free SQ entries right now.
    #[inline(always)]
    pub fn sq_space_left(&self) -> u32 {
        let head = unsafe { std::ptr::read_volatile(self.sq_khead) };
        self.sq_entries - self.sq_tail.wrapping_sub(head)
    }

    /// Like `get_sqe`, but when the SQ is full it first hands the queued SQEs to the kernel, so a request
    /// (a send, a close) is never silently dropped. Returns None only if the kernel refuses to take any.
    pub fn get_sqe_flush(&mut self) -> Option<&mut io_uring_sqe> {
        let mut tries = 0;
        while self.sq_space_left() == 0 && tries < 64 {
            let _ = self.submit_and_wait_timeout(0, 0);
            tries += 1;
        }
        self.get_sqe()
    }

    #[inline(always)]
    pub fn flush_sq(&mut self) -> u32 {
        let khead = unsafe { std::ptr::read_volatile(self.sq_khead) };
        let to_submit = self.sq_tail.wrapping_sub(khead);
        if to_submit > 0 {
            unsafe {
                fence(Ordering::Release);
                std::ptr::write_volatile(self.sq_ktail, self.sq_tail);
            }
        }
        to_submit
    }

    #[inline(always)]
    pub fn submit_and_wait_timeout(&mut self, min_complete: u32, timeout_us: u64) -> Result<u32, i32> {
        let to_submit = self.flush_sq();
        if to_submit == 0 && min_complete == 0 {
            return Ok(0);
        }

        let ts = kernel_timespec {
            tv_sec: (timeout_us / 1_000_000) as i64,
            tv_nsec: ((timeout_us % 1_000_000) * 1_000) as i64,
        };
        let arg = io_uring_getevents_arg {
            sigmask: 0,
            sigmask_sz: 0,
            pad: 0,
            ts: &ts as *const _ as u64,
        };
        let (flags, arg_ptr, arg_sz) = if min_complete > 0 {
            if timeout_us > 0 {
                (
                    IORING_ENTER_GETEVENTS | IORING_ENTER_EXT_ARG,
                    &arg as *const _ as *const libc::c_void,
                    std::mem::size_of::<io_uring_getevents_arg>(),
                )
            } else {
                (
                    IORING_ENTER_GETEVENTS,
                    std::ptr::null(),
                    0,
                )
            }
        } else {
            (0, std::ptr::null(), 0)
        };

        let ret = unsafe {
            libc::syscall(
                libc::SYS_io_uring_enter,
                self.fd,
                to_submit,
                min_complete,
                flags,
                arg_ptr,
                arg_sz,
            )
        };
        if ret < 0 {
            Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1))
        } else {
            Ok(ret as u32)
        }
    }

    #[inline(always)]
    pub fn for_each_cqe<F: FnMut(&io_uring_cqe)>(&mut self, mut f: F) -> usize {
        let mut count = 0;
        let mut head = unsafe { std::ptr::read_volatile(self.cq_khead) };
        let tail = unsafe { std::ptr::read_volatile(self.cq_ktail) };

        while head != tail {
            let index = head & self.cq_mask;
            let cqe = unsafe { &*self.cqes.offset(index as isize) };
            f(cqe);
            head = head.wrapping_add(1);
            count += 1;
        }

        if count > 0 {
            unsafe {
                fence(Ordering::Release);
                std::ptr::write_volatile(self.cq_khead, head);
            }
        }
        count
    }
}

impl Drop for IoUringInstance {
    fn drop(&mut self) {
        unsafe {
            libc::munmap(self.sqes_mmap_ptr, self.sqes_mmap_sz);
            if self.cq_mmap_sz > 0 {
                libc::munmap(self.cq_mmap_ptr, self.cq_mmap_sz);
            }
            libc::munmap(self.sq_mmap_ptr, self.sq_mmap_sz);
            libc::close(self.fd);
        }
    }
}
