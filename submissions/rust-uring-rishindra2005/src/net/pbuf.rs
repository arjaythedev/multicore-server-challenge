//! Kernel provided buffer ring (IORING_REGISTER_PBUF_RING) manager.
//! Zero per-connection read buffer overhead; user-space atomic buffer return.

use std::os::unix::io::RawFd;
use std::sync::atomic::{fence, Ordering};
use crate::net::uring::*;

#[repr(C)]
pub struct io_uring_buf {
    pub addr: u64,
    pub len: u32,
    pub bid: u16,
    pub resv: u16,
}

#[repr(C)]
pub struct io_uring_buf_ring {
    pub buf: io_uring_buf,
}

#[repr(C)]
pub struct io_uring_buf_reg {
    pub ring_addr: u64,
    pub ring_entries: u32,
    pub bgid: u16,
    pub pad: u16,
    pub resv: [u64; 3],
}

pub struct ProvidedBufferRing {
    pub ring_mem: *mut u8,
    pub buffers: *mut u8,
    pub entries: u32,
    pub buf_size: usize,
    pub mask: u32,
    pub bgid: u16,
    pub ring_tail: *mut u16,
    pub local_tail: u16,
}

unsafe impl Send for ProvidedBufferRing {}
unsafe impl Sync for ProvidedBufferRing {}

impl ProvidedBufferRing {
    pub fn new(ring_fd: RawFd, bgid: u16, entries: u32, buf_size: usize) -> Result<Self, i32> {
        assert!(entries > 0 && (entries & (entries - 1)) == 0, "entries must be power of two");

        // 1. Allocate page-aligned ring memory
        let ring_sz = (entries as usize) * std::mem::size_of::<io_uring_buf>();
        let mut ring_ptr: *mut libc::c_void = std::ptr::null_mut();
        let rc = unsafe { libc::posix_memalign(&mut ring_ptr, 4096, ring_sz) };
        if rc != 0 || ring_ptr.is_null() {
            return Err(-libc::ENOMEM);
        }
        unsafe { std::ptr::write_bytes(ring_ptr, 0, ring_sz) };

        // 2. Allocate buffer backing storage
        let total_buf_sz = (entries as usize) * buf_size;
        let mut buf_ptr: *mut libc::c_void = std::ptr::null_mut();
        let rc2 = unsafe { libc::posix_memalign(&mut buf_ptr, 4096, total_buf_sz) };
        if rc2 != 0 || buf_ptr.is_null() {
            unsafe { libc::free(ring_ptr) };
            return Err(-libc::ENOMEM);
        }

        // 3. Register with io_uring
        let reg = io_uring_buf_reg {
            ring_addr: ring_ptr as u64,
            ring_entries: entries,
            bgid,
            pad: 0,
            resv: [1, 0, 0], // Kernel 6.8 pbuf validation workaround: resv non-zero required by memchr_inv
        };

        let reg_rc = unsafe {
            libc::syscall(
                libc::SYS_io_uring_register,
                ring_fd,
                IORING_REGISTER_PBUF_RING as libc::c_uint,
                &reg as *const _ as *const libc::c_void,
                1 as libc::c_uint,
            )
        };
        if reg_rc < 0 {
            unsafe {
                libc::free(buf_ptr);
                libc::free(ring_ptr);
            };
            return Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(-1));
        }

        // 4. Populate buffer ring entries
        let buf_ring = ring_ptr as *mut io_uring_buf;
        let buf_base = buf_ptr as *mut u8;

        for i in 0..entries {
            unsafe {
                let entry = &mut *buf_ring.add(i as usize);
                entry.addr = buf_base.add(i as usize * buf_size) as u64;
                entry.len = buf_size as u32;
                entry.bid = i as u16;
                entry.resv = 0;
            }
        }

        // Kernel reads tail from the last 2 bytes of the ring header or entry (entries - 1)
        // In io_uring 6.8, tail is at offset: ring_addr + (entries * 16) - 2 or struct tail offset
        let ring_tail = unsafe {
            // In io_uring_buf_ring union: entries[0].tail is at offset 14 of the first 16-byte block
            (ring_ptr as *mut u16).add(7)
        };

        unsafe {
            fence(Ordering::Release);
            std::ptr::write_volatile(ring_tail, entries as u16);
        }

        Ok(Self {
            ring_mem: ring_ptr as *mut u8,
            buffers: buf_ptr as *mut u8,
            entries,
            buf_size,
            mask: entries - 1,
            bgid,
            ring_tail,
            local_tail: entries as u16,
        })
    }

    #[inline(always)]
    pub fn get_buffer(&self, bid: u16, len: usize) -> &[u8] {
        let offset = (bid as usize) * self.buf_size;
        let actual_len = len.min(self.buf_size);
        unsafe { std::slice::from_raw_parts(self.buffers.add(offset), actual_len) }
    }

    #[inline(always)]
    pub fn return_buf(&mut self, bid: u16) {
        let idx = (self.local_tail & (self.mask as u16)) as usize;
        let buf_ring = self.ring_mem as *mut io_uring_buf;
        let buf_base = self.buffers;

        unsafe {
            let entry = &mut *buf_ring.add(idx);
            entry.addr = buf_base.add((bid as usize) * self.buf_size) as u64;
            entry.len = self.buf_size as u32;
            entry.bid = bid;
            entry.resv = 0;

            self.local_tail = self.local_tail.wrapping_add(1);
            fence(Ordering::Release);
            std::ptr::write_volatile(self.ring_tail, self.local_tail);
        }
    }
}

impl Drop for ProvidedBufferRing {
    fn drop(&mut self) {
        unsafe {
            libc::free(self.buffers as *mut libc::c_void);
            libc::free(self.ring_mem as *mut libc::c_void);
        }
    }
}
