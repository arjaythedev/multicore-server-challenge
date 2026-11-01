//! The write queue: where the io threads leave [`WriteJob`]s and the write lanes pick them up in batches.
//!
//! # Batching rule
//!
//! A lane sleeps until the queue holds a job. It then waits up to `window` (measured from the moment it saw the
//! first job) for company, or until `batch_max` jobs are queued, and takes up to `batch_max` jobs at once. All
//! jobs of one batch share one transaction, so a longer window trades latency for fewer commits.
//!
//! Only one lane gathers at a time: `push` wakes an idle lane only when the queue goes from empty to non-empty,
//! and a lane that leaves jobs behind (more than `batch_max` were queued) wakes the next one.
//!
//! Not handled on purpose: priorities, per-kind batches, back-pressure (the app bounds the number of in-flight
//! requests by the number of connections), fairness between lanes.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::app::jobs::WriteJob;

/// State behind the lock.
struct Inner {
    jobs: VecDeque<WriteJob>,
    closed: bool,
}

/// Shared queue of write jobs. Create with [`WriteQueue::new`], share the `Arc` with the app and the lanes.
pub struct WriteQueue {
    inner: Mutex<Inner>,
    /// Signalled when the queue becomes non-empty (wakes one idle lane) and on close.
    ready: Condvar,
    /// Signalled when the queue reaches `batch_max` (ends the gathering lane's wait early) and on close.
    full: Condvar,
    window: Duration,
    batch_max: usize,
}

impl WriteQueue {
    /// `window`: how long the first job of a batch waits for company. `batch_max`: most jobs in one transaction
    /// (a value of 0 is treated as 1).
    pub fn new(window: Duration, batch_max: usize) -> Arc<WriteQueue> {
        Arc::new(WriteQueue {
            inner: Mutex::new(Inner {
                jobs: VecDeque::new(),
                closed: false,
            }),
            ready: Condvar::new(),
            full: Condvar::new(),
            window,
            batch_max: batch_max.max(1),
        })
    }

    /// Queues a job. Never blocks beyond the lock.
    pub fn push(&self, job: WriteJob) {
        let mut inner = self.lock();
        let was_empty = inner.jobs.is_empty();
        inner.jobs.push_back(job);
        let len = inner.jobs.len();
        drop(inner);
        if was_empty {
            self.ready.notify_one();
        }
        if len >= self.batch_max {
            self.full.notify_all();
        }
    }

    /// Stops the lanes once the queue is drained: [`take_batch`](Self::take_batch) returns `false` when nothing is
    /// left. Used by tests and by an orderly shutdown; jobs pushed after `close` are still taken until drained.
    pub fn close(&self) {
        self.lock().closed = true;
        self.ready.notify_all();
        self.full.notify_all();
    }

    /// Jobs waiting right now.
    pub fn len(&self) -> usize {
        self.lock().jobs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Blocks until there is a batch, appends it to `out` (which keeps its allocation between calls) and returns
    /// `true`. Returns `false` when the queue is closed and empty. See the module docs for the rule.
    pub fn take_batch(&self, out: &mut Vec<WriteJob>) -> bool {
        let mut inner = self.lock();
        while inner.jobs.is_empty() {
            if inner.closed {
                return false;
            }
            inner = self.ready.wait(inner).unwrap_or_else(|e| e.into_inner());
        }
        let deadline = Instant::now() + self.window;
        while inner.jobs.len() < self.batch_max && !inner.closed {
            let Some(left) = deadline
                .checked_duration_since(Instant::now())
                .filter(|d| !d.is_zero())
            else {
                break;
            };
            inner = self
                .full
                .wait_timeout(inner, left)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
        let take = inner.jobs.len().min(self.batch_max);
        out.extend(inner.jobs.drain(..take));
        let more_left = !inner.jobs.is_empty();
        drop(inner);
        if more_left {
            self.ready.notify_one();
        }
        true
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::jobs::{Field, Origin, WriteKind};
    use crate::net::ConnId;

    fn job(tag: u32) -> WriteJob {
        let conn = ConnId {
            io: 0,
            slot: tag,
            generation: 0,
        };
        WriteJob {
            origin: Origin {
                conn,
                keep_alive: true,
            },
            viewer: 1,
            buf: Vec::new(),
            kind: WriteKind::DeleteArticle {
                slug: Field::default(),
            },
        }
    }

    fn slots(batch: &[WriteJob]) -> Vec<u32> {
        batch.iter().map(|j| j.origin.conn.slot).collect()
    }

    #[test]
    fn a_lone_job_waits_for_the_window_then_goes_alone() {
        let queue = WriteQueue::new(Duration::from_millis(40), 8);
        queue.push(job(1));
        let started = Instant::now();
        let mut batch = Vec::new();
        assert!(queue.take_batch(&mut batch));
        assert_eq!(slots(&batch), [1]);
        assert!(started.elapsed() >= Duration::from_millis(40));
    }

    #[test]
    fn a_full_queue_does_not_wait() {
        let queue = WriteQueue::new(Duration::from_secs(10), 3);
        (0..3).for_each(|i| queue.push(job(i)));
        let started = Instant::now();
        let mut batch = Vec::new();
        assert!(queue.take_batch(&mut batch));
        assert_eq!(slots(&batch), [0, 1, 2]);
        assert!(started.elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn at_most_batch_max_are_taken_and_the_rest_stays_in_order() {
        let queue = WriteQueue::new(Duration::ZERO, 2);
        (0..5).for_each(|i| queue.push(job(i)));
        let mut batch = Vec::new();
        assert!(queue.take_batch(&mut batch));
        assert_eq!(slots(&batch), [0, 1]);
        batch.clear();
        assert!(queue.take_batch(&mut batch));
        assert_eq!(slots(&batch), [2, 3]);
        assert_eq!(queue.len(), 1);
    }

    #[test]
    fn jobs_arriving_inside_the_window_join_the_batch() {
        let queue = WriteQueue::new(Duration::from_millis(500), 100);
        queue.push(job(0));
        let producer = {
            let queue = Arc::clone(&queue);
            std::thread::spawn(move || (1..4).for_each(|i| queue.push(job(i))))
        };
        let mut batch = Vec::new();
        assert!(queue.take_batch(&mut batch));
        producer.join().unwrap();
        assert_eq!(slots(&batch), [0, 1, 2, 3]);
    }

    #[test]
    fn close_drains_then_reports_the_end() {
        let queue = WriteQueue::new(Duration::from_secs(10), 8);
        queue.push(job(7));
        queue.close();
        let mut batch = Vec::new();
        assert!(
            queue.take_batch(&mut batch),
            "queued jobs are still delivered, without waiting the window"
        );
        assert_eq!(slots(&batch), [7]);
        batch.clear();
        assert!(!queue.take_batch(&mut batch));
    }

    #[test]
    fn a_sleeping_lane_wakes_on_close() {
        let queue = WriteQueue::new(Duration::from_millis(5), 8);
        let lane = {
            let queue = Arc::clone(&queue);
            std::thread::spawn(move || queue.take_batch(&mut Vec::new()))
        };
        std::thread::sleep(Duration::from_millis(30));
        queue.close();
        assert!(!lane.join().unwrap());
    }

    #[test]
    fn zero_batch_max_means_one() {
        let queue = WriteQueue::new(Duration::ZERO, 0);
        queue.push(job(1));
        queue.push(job(2));
        let mut batch = Vec::new();
        assert!(queue.take_batch(&mut batch));
        assert_eq!(batch.len(), 1);
    }
}
