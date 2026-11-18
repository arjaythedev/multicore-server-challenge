//! Cache-line padded lock-free SPSC ring with adaptive eventfd wakeups.
//! Zero-syscall fast path when consumer is awake; single eventfd write when sleeping.

use std::cell::UnsafeCell;
use std::mem::MaybeUninit;
use std::os::unix::io::RawFd;
use std::sync::atomic::{AtomicU32, Ordering};

pub const STATE_AWAKE: u32 = 0;
pub const STATE_SLEEPING: u32 = 1;

/// Bounded Single-Producer Single-Consumer queue.
/// `N` must be a power of two.
#[repr(C, align(64))]
pub struct SpscQueue<T, const N: usize> {
    // Producer cache line
    pub head: AtomicU32,
    _pad1: [u8; 60],

    // Consumer cache line
    pub tail: AtomicU32,
    _pad2: [u8; 60],

    // Signaling cache line
    pub state: AtomicU32, // STATE_AWAKE or STATE_SLEEPING
    pub event_fd: RawFd,
    _pad3: [u8; 56],

    // Storage buffer
    buffer: [UnsafeCell<MaybeUninit<T>>; N],
}

unsafe impl<T: Send, const N: usize> Send for SpscQueue<T, N> {}
unsafe impl<T: Send, const N: usize> Sync for SpscQueue<T, N> {}

impl<T, const N: usize> SpscQueue<T, N> {
    const MASK: u32 = (N as u32) - 1;

    pub fn new(event_fd: RawFd) -> Self {
        assert!(N > 0 && (N & (N - 1)) == 0, "N must be a power of two");
        // Safe uninit array creation
        let buffer: [UnsafeCell<MaybeUninit<T>>; N] = unsafe {
            MaybeUninit::uninit().assume_init()
        };

        Self {
            head: AtomicU32::new(0),
            _pad1: [0u8; 60],
            tail: AtomicU32::new(0),
            _pad2: [0u8; 60],
            state: AtomicU32::new(STATE_AWAKE),
            event_fd,
            _pad3: [0u8; 56],
            buffer,
        }
    }

    #[inline(always)]
    pub fn push(&self, item: T) -> Result<(), T> {
        let head = self.head.load(Ordering::Relaxed);
        let tail = self.tail.load(Ordering::Acquire);

        if head.wrapping_sub(tail) >= N as u32 {
            return Err(item); // Queue is full
        }

        let idx = (head & Self::MASK) as usize;
        unsafe {
            let slot = self.buffer[idx].get();
            (*slot).write(item);
        }

        self.head.store(head.wrapping_add(1), Ordering::Release);
        std::sync::atomic::fence(Ordering::SeqCst);

        // If consumer is sleeping, wake it up via eventfd
        if self.state.load(Ordering::Acquire) == STATE_SLEEPING {
            self.wake_consumer();
        }

        Ok(())
    }

    #[inline(always)]
    pub fn pop(&self) -> Option<T> {
        let tail = self.tail.load(Ordering::Relaxed);
        let head = self.head.load(Ordering::Acquire);

        if tail == head {
            return None; // Queue is empty
        }

        let idx = (tail & Self::MASK) as usize;
        let item = unsafe {
            let slot = self.buffer[idx].get();
            (*slot).assume_init_read()
        };

        self.tail.store(tail.wrapping_add(1), Ordering::Release);
        Some(item)
    }

    #[inline(always)]
    pub fn is_empty(&self) -> bool {
        self.tail.load(Ordering::Relaxed) == self.head.load(Ordering::Acquire)
    }

    #[inline(always)]
    pub fn len(&self) -> usize {
        let head = self.head.load(Ordering::Acquire);
        let tail = self.tail.load(Ordering::Acquire);
        head.wrapping_sub(tail) as usize
    }

    #[inline(always)]
    pub fn mark_sleeping(&self) {
        self.state.store(STATE_SLEEPING, Ordering::SeqCst);
    }

    #[inline(always)]
    pub fn mark_awake(&self) {
        self.state.store(STATE_AWAKE, Ordering::Release);
    }

    #[inline(always)]
    pub fn wake_consumer(&self) {
        if self.event_fd >= 0 {
            let val: u64 = 1;
            unsafe {
                libc::write(
                    self.event_fd,
                    &val as *const u64 as *const libc::c_void,
                    8,
                );
            }
        }
    }
}

impl<T, const N: usize> Drop for SpscQueue<T, N> {
    fn drop(&mut self) {
        while let Some(_item) = self.pop() {
            // Drop remaining items
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_spsc_basic() {
        let q = SpscQueue::<u64, 16>::new(-1);
        assert!(q.is_empty());
        assert_eq!(q.len(), 0);

        for i in 0..15 {
            assert!(q.push(i).is_ok());
        }
        assert_eq!(q.len(), 15);

        for i in 0..15 {
            assert_eq!(q.pop(), Some(i));
        }
        assert!(q.is_empty());
    }

    #[test]
    fn test_spsc_wrap() {
        let q = SpscQueue::<u32, 4>::new(-1);
        for _ in 0..100 {
            assert!(q.push(42).is_ok());
            assert_eq!(q.pop(), Some(42));
        }
    }

    #[test]
    fn test_spsc_wake_consumer_eventfd() {
        let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        assert!(efd >= 0);
        let q = SpscQueue::<u32, 16>::new(efd);
        assert_eq!(q.state.load(Ordering::Relaxed), STATE_AWAKE);

        // Push while awake does NOT write to eventfd
        assert!(q.push(10).is_ok());

        // Mark sleeping
        q.mark_sleeping();
        assert_eq!(q.state.load(Ordering::Relaxed), STATE_SLEEPING);

        // Push while sleeping MUST write to eventfd
        assert!(q.push(20).is_ok());

        // Verify eventfd has 8 bytes written (counter == 1)
        let mut val: u64 = 0;
        let n = unsafe {
            libc::read(efd, &mut val as *mut u64 as *mut libc::c_void, 8)
        };
        assert_eq!(n, 8);
        assert_eq!(val, 1);

        // Mark awake
        q.mark_awake();
        assert_eq!(q.state.load(Ordering::Relaxed), STATE_AWAKE);

        unsafe { libc::close(efd); }
    }
}
