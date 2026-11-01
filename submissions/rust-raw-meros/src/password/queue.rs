//! The password queue and its gather rule.
//!
//! A worker takes a batch when the queue holds [`MAX_LANES`] jobs or the oldest job has waited `window`. A lone
//! login therefore waits one window for company (default 100 ms, far below the latency budget); under load the
//! lanes fill and nobody waits. Window zero means "take what is there now".

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::app::jobs::PasswordJob;
use crate::bcrypt::MAX_LANES;

struct State {
    jobs: VecDeque<PasswordJob>,
    closed: bool,
}

/// Queue of password jobs shared by the app (register, change password), the read lanes (login) and the workers.
pub struct PasswordQueue {
    state: Mutex<State>,
    wake: Condvar,
    window: Duration,
}

impl PasswordQueue {
    pub fn new(window: Duration) -> std::sync::Arc<PasswordQueue> {
        std::sync::Arc::new(PasswordQueue {
            state: Mutex::new(State {
                jobs: VecDeque::with_capacity(4 * MAX_LANES),
                closed: false,
            }),
            wake: Condvar::new(),
            window,
        })
    }

    /// Queues a job. Wakes the workers only when it matters: the queue was empty, or a batch is now full.
    pub fn push(&self, job: PasswordJob) {
        let len = {
            let mut state = self.lock();
            state.jobs.push_back(job);
            state.jobs.len()
        };
        if len == 1 || len >= MAX_LANES {
            self.wake.notify_all();
        }
    }

    /// Makes `take_batch` return `false` once the queue is empty.
    pub fn close(&self) {
        self.lock().closed = true;
        self.wake.notify_all();
    }

    /// Blocks until a batch is ready, then moves the oldest jobs (at most [`MAX_LANES`]) into `out`, which is
    /// cleared first. Returns `false` when the queue is closed and empty.
    pub fn take_batch(&self, out: &mut Vec<PasswordJob>) -> bool {
        out.clear();
        let mut state = self.lock();
        loop {
            let Some(oldest) = state.jobs.front() else {
                if state.closed {
                    return false;
                }
                state = self.wait(state);
                continue;
            };
            let deadline = oldest.queued_at + self.window;
            let now = Instant::now();
            if state.jobs.len() >= MAX_LANES || state.closed || now >= deadline {
                break;
            }
            state = self.wait_for(state, deadline - now);
        }
        let take = state.jobs.len().min(MAX_LANES);
        out.extend(state.jobs.drain(..take));
        let more = !state.jobs.is_empty();
        drop(state);
        if more {
            self.wake.notify_all(); // another worker may take the rest
        }
        true
    }

    /// Jobs waiting now.
    pub fn len(&self) -> usize {
        self.lock().jobs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn wait<'a>(&self, guard: MutexGuard<'a, State>) -> MutexGuard<'a, State> {
        self.wake.wait(guard).unwrap_or_else(|e| e.into_inner())
    }

    fn wait_for<'a>(
        &self,
        guard: MutexGuard<'a, State>,
        timeout: Duration,
    ) -> MutexGuard<'a, State> {
        self.wake
            .wait_timeout(guard, timeout)
            .unwrap_or_else(|e| e.into_inner())
            .0
    }
}
