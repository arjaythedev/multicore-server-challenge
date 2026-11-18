//! A plain mutex + condvar work queue. Consumers take everything that is waiting (up to a cap) in one go, which is
//! what turns concurrent requests into batches.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

struct Inner<T> {
    q: VecDeque<T>,
    /// When the oldest queued item arrived (after a partial take: when the oldest taken one did, an upper bound).
    since: Option<Instant>,
    /// A `take_aged` waiter's threshold: pushes below it don't wake anyone (the waiter's timer covers the age).
    hold: usize,
    /// Threads blocked on the condvar.
    waiting: usize,
}

pub struct Queue<T> {
    m: Mutex<Inner<T>>,
    cv: Condvar,
}

impl<T> Queue<T> {
    pub const fn new() -> Queue<T> {
        Queue { m: Mutex::new(Inner { q: VecDeque::new(), since: None, hold: 0, waiting: 0 }), cv: Condvar::new() }
    }

    /// Pushes; returns whether a waiter needs waking.
    fn push_inner(&self, item: T) -> bool {
        let mut g = self.m.lock().unwrap();
        if g.q.is_empty() {
            g.since = Some(Instant::now());
        }
        g.q.push_back(item);
        let n = g.q.len();
        g.waiting > 0 && (n == 1 || n >= g.hold)
    }

    fn wait<'a>(&self, mut g: std::sync::MutexGuard<'a, Inner<T>>) -> std::sync::MutexGuard<'a, Inner<T>> {
        g.waiting += 1;
        let mut g = self.cv.wait(g).unwrap();
        g.waiting -= 1;
        g
    }

    fn wait_timeout<'a>(&self, mut g: std::sync::MutexGuard<'a, Inner<T>>, d: Duration) -> std::sync::MutexGuard<'a, Inner<T>> {
        g.waiting += 1;
        let mut g = self.cv.wait_timeout(g, d).unwrap().0;
        g.waiting -= 1;
        g
    }

    pub fn push(&self, item: T) {
        if self.push_inner(item) {
            self.cv.notify_one();
        }
    }

    /// Push and wake every waiter (for queues whose consumers wait on different conditions).
    pub fn push_all(&self, item: T) {
        if self.push_inner(item) {
            self.cv.notify_all();
        }
    }

    fn drain(g: &mut Inner<T>, n: usize, out: &mut Vec<T>) {
        out.extend(g.q.drain(..n));
        // Items left behind (a backlog past one batch) keep the old timestamp: they are at least that old already,
        // so the next take doesn't make them wait another window.
        if g.q.is_empty() {
            g.since = None;
        }
    }

    /// Blocks until at least `want` items are queued, then takes `want`.
    pub fn take_full(&self, want: usize, out: &mut Vec<T>) {
        let mut g = self.m.lock().unwrap();
        while g.q.len() < want {
            g = self.wait(g);
        }
        Self::drain(&mut g, want, out);
        if !g.q.is_empty() && g.waiting > 0 {
            self.cv.notify_all();
        }
    }

    /// Blocks until one item is queued, then waits up to `window` (from that moment) for `want` items before taking
    /// up to `want`.
    pub fn take_gather(&self, want: usize, window: Duration, out: &mut Vec<T>) {
        let mut g = self.m.lock().unwrap();
        while g.q.is_empty() {
            g = self.wait(g);
        }
        let deadline = Instant::now() + window;
        while g.q.len() < want {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            g = self.wait_timeout(g, deadline - now);
        }
        let n = g.q.len().min(want);
        Self::drain(&mut g, n, out);
        if !g.q.is_empty() && g.waiting > 0 {
            self.cv.notify_one();
        }
    }

    /// Blocks until at least `want` items are queued or the oldest has waited `max_age`, then takes up to `max`.
    pub fn take_aged(&self, want: usize, max_age: Duration, max: usize, out: &mut Vec<T>) {
        let mut g = self.m.lock().unwrap();
        g.hold = want;
        loop {
            if g.q.len() >= want {
                break;
            }
            match g.since {
                None => g = self.wait(g),
                Some(t) => {
                    let deadline = t + max_age;
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    g = self.wait_timeout(g, deadline - now);
                }
            }
        }
        g.hold = 0;
        let n = g.q.len().min(max);
        Self::drain(&mut g, n, out);
        if !g.q.is_empty() && g.waiting > 0 {
            self.cv.notify_one();
        }
    }

    /// Takes up to `max` without blocking if the oldest item has waited at least `age`; returns whether it did.
    pub fn take_if_older(&self, age: Duration, max: usize, out: &mut Vec<T>) -> bool {
        let mut g = self.m.lock().unwrap();
        match g.since {
            Some(t) if t.elapsed() >= age => {
                let n = g.q.len().min(max);
                Self::drain(&mut g, n, out);
                true
            }
            _ => false,
        }
    }
}
