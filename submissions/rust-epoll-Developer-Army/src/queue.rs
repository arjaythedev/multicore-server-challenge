//! High-throughput concurrent queue with adaptive slack batching.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

pub struct Queue<T> {
    q: Mutex<VecDeque<T>>,
    cv: Condvar,
}

impl<T> Queue<T> {
    pub const fn new() -> Queue<T> {
        Queue { q: Mutex::new(VecDeque::new()), cv: Condvar::new() }
    }

    #[inline]
    pub fn push(&self, item: T) {
        let mut q = self.q.lock().unwrap();
        q.push_back(item);
        self.cv.notify_one();
    }

    /// Push and wake all waiters.
    #[inline]
    pub fn push_all(&self, item: T) {
        let mut q = self.q.lock().unwrap();
        q.push_back(item);
        self.cv.notify_all();
    }

    /// Plain take: blocks until at least one item is queued, then takes up to `max`.
    pub fn take(&self, max: usize, out: &mut Vec<T>) {
        let mut q = self.q.lock().unwrap();
        while q.is_empty() {
            q = self.cv.wait(q).unwrap();
        }
        let n = q.len().min(max);
        out.extend(q.drain(..n));
        if !q.is_empty() {
            self.cv.notify_one();
        }
    }

    /// Blocks until at least `want` items are queued, then takes `want`.
    #[allow(dead_code)]
    pub fn take_full(&self, want: usize, out: &mut Vec<T>) {
        let mut q = self.q.lock().unwrap();
        while q.len() < want {
            q = self.cv.wait(q).unwrap();
        }
        out.extend(q.drain(..want));
        if !q.is_empty() {
            self.cv.notify_all();
        }
    }

    /// Dynamic adaptive batching:
    /// Drains immediately if `target` items are waiting.
    /// Otherwise waits up to `window` for `target` items to gather.
    pub fn take_adaptive(&self, target: usize, window: Duration, max: usize, out: &mut Vec<T>) {
        let mut q = self.q.lock().unwrap();
        while q.is_empty() {
            q = self.cv.wait(q).unwrap();
        }
        if q.len() < target {
            let deadline = Instant::now() + window;
            while q.len() < target {
                let now = Instant::now();
                if now >= deadline {
                    break;
                }
                let (nq, _) = self.cv.wait_timeout(q, deadline - now).unwrap();
                q = nq;
            }
        }
        let n = q.len().min(max);
        out.extend(q.drain(..n));
        if !q.is_empty() {
            self.cv.notify_one();
        }
    }

    /// Bcrypt collection: takes up to `max` items, waiting up to `window` if fewer than `min` are present.
    pub fn take_window(&self, min: usize, window: Duration, max: usize, out: &mut Vec<T>) {
        let mut q = self.q.lock().unwrap();
        while q.is_empty() {
            q = self.cv.wait(q).unwrap();
        }
        let deadline = Instant::now() + window;
        while q.len() < min {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            let (nq, _) = self.cv.wait_timeout(q, deadline - now).unwrap();
            q = nq;
        }
        let n = q.len().min(max);
        out.extend(q.drain(..n));
        if !q.is_empty() {
            self.cv.notify_one();
        }
    }
}
