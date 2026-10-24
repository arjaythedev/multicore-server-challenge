//! A plain mutex + condvar work queue. Consumers take everything that is waiting (up to a cap) in one go, which is
//! what turns concurrent requests into batches.

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

    pub fn push(&self, item: T) {
        self.q.lock().unwrap().push_back(item);
        self.cv.notify_one();
    }

    /// Push and wake every waiter (for queues whose consumers wait on different conditions).
    pub fn push_all(&self, item: T) {
        self.q.lock().unwrap().push_back(item);
        self.cv.notify_all();
    }

    /// Blocks until at least one item is queued, then takes up to `max`.
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

    /// Blocks until one item is queued, then waits up to `window` for `want` items before taking up to `want`.
    pub fn take_gather(&self, want: usize, window: Duration, out: &mut Vec<T>) {
        self.take_window(want, window, want, out)
    }

    /// Blocks until one item is queued, then waits up to `window` (from that moment) until at least `min` are
    /// queued, then takes up to `max`.
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
            q = self.cv.wait_timeout(q, deadline - now).unwrap().0;
        }
        let n = q.len().min(max);
        out.extend(q.drain(..n));
        if !q.is_empty() {
            self.cv.notify_one();
        }
    }
}
