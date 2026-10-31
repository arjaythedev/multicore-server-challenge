//! A job queue that hands work out in batches: one taker gathers at a time while the others are busy executing.

use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

pub struct Queue<T> {
    q: Mutex<Vec<T>>,
    cv: Condvar,
    gather: Mutex<()>,
    /// Wake every taker on every push (takers wait for `min` items), not one taker when the queue becomes non-empty.
    notify_all: bool,
}

impl<T> Queue<T> {
    pub const fn new(notify_all: bool) -> Queue<T> {
        Queue { q: Mutex::new(Vec::new()), cv: Condvar::new(), gather: Mutex::new(()), notify_all }
    }

    pub fn push(&self, t: T) {
        let was_empty = {
            let mut q = self.q.lock().unwrap();
            q.push(t);
            q.len() == 1
        };
        if self.notify_all {
            self.cv.notify_all();
        } else if was_empty {
            self.cv.notify_one();
        }
    }

    /// Waits for a first item, then up to `window` for `min` items, and takes up to `max` (oldest first).
    pub fn take(&self, min: usize, max: usize, window: Duration, out: &mut Vec<T>) {
        let _turn = self.gather.lock().unwrap();
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
    }

    /// Waits for exactly `n` items, without taking a gather turn (a backlog helper beside a gathering taker).
    pub fn take_full(&self, n: usize, out: &mut Vec<T>) {
        let mut q = self.q.lock().unwrap();
        while q.len() < n {
            q = self.cv.wait(q).unwrap();
        }
        out.extend(q.drain(..n));
    }
}
