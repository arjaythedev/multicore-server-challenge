//! A shared pool of byte buffers, so that the steady state allocates nothing: a request buffer is taken from the pool
//! by an io thread, moves into a job, and goes back after the lane answered; a response buffer is taken by a lane,
//! moves to an io thread through the mailbox, and goes back after it was written.
//!
//! One mutex guards the free list. A buffer changes hands twice per request, so at 30,000 requests per second the
//! lock is taken about 60,000 times per second for a few nanoseconds each: not worth anything cleverer.

use std::sync::Mutex;

/// Capacity of a fresh buffer. Most requests are well under 1 KiB and most responses under 8 KiB; a buffer that
/// needs more grows and keeps its capacity when it returns (up to [`MAX_KEPT_CAPACITY`]).
pub const DEFAULT_CAPACITY: usize = 4096;
/// Buffers larger than this are dropped instead of kept, so one huge response does not pin memory.
pub const MAX_KEPT_CAPACITY: usize = 256 * 1024;
/// Most buffers kept on the free list.
pub const MAX_KEPT_BUFFERS: usize = 4096;

pub struct BufPool {
    free: Mutex<Vec<Vec<u8>>>,
}

impl BufPool {
    pub const fn new() -> BufPool {
        BufPool {
            free: Mutex::new(Vec::new()),
        }
    }

    /// An empty buffer with at least [`DEFAULT_CAPACITY`] bytes of capacity.
    pub fn get(&self) -> Vec<u8> {
        let recycled = self.free.lock().unwrap_or_else(|e| e.into_inner()).pop();
        recycled.unwrap_or_else(|| Vec::with_capacity(DEFAULT_CAPACITY))
    }

    /// Takes a buffer back. Its contents are discarded.
    pub fn put(&self, buf: Vec<u8>) {
        if let Some(buf) = Self::keep(buf) {
            let mut free = self.free.lock().unwrap_or_else(|e| e.into_inner());
            if free.len() < MAX_KEPT_BUFFERS {
                free.push(buf);
            }
        }
    }

    /// Takes many buffers back with one lock acquisition.
    pub fn put_all(&self, bufs: &mut Vec<Vec<u8>>) {
        let mut free = self.free.lock().unwrap_or_else(|e| e.into_inner());
        for buf in bufs.drain(..) {
            if free.len() >= MAX_KEPT_BUFFERS {
                break;
            }
            if let Some(buf) = Self::keep(buf) {
                free.push(buf);
            }
        }
    }

    fn keep(mut buf: Vec<u8>) -> Option<Vec<u8>> {
        if buf.capacity() < DEFAULT_CAPACITY || buf.capacity() > MAX_KEPT_CAPACITY {
            return None;
        }
        buf.clear();
        Some(buf)
    }
}

impl Default for BufPool {
    fn default() -> Self {
        Self::new()
    }
}

/// The process-wide pool.
pub static POOL: BufPool = BufPool::new();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn buffers_are_recycled_empty() {
        let pool = BufPool::new();
        let mut buf = pool.get();
        assert!(buf.capacity() >= DEFAULT_CAPACITY);
        buf.extend_from_slice(b"data");
        let pointer = buf.as_ptr();
        pool.put(buf);
        let again = pool.get();
        assert!(again.is_empty());
        assert_eq!(again.as_ptr(), pointer);
    }

    #[test]
    fn oversized_and_tiny_buffers_are_dropped() {
        let pool = BufPool::new();
        pool.put(Vec::with_capacity(MAX_KEPT_CAPACITY + 1));
        pool.put(Vec::with_capacity(8));
        assert_eq!(pool.free.lock().unwrap().len(), 0);
    }
}
