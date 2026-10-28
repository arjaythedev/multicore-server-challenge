//! [`ReadQueue`]: the FIFO of read jobs and the rule that turns it into batches.
//!
//! One lane at a time is the *gatherer*. It holds the `gatherer` mutex, sleeps on a condition variable until the
//! batch is full or the oldest queued job has waited the collection window, takes up to `batch_max` jobs (all kinds
//! mixed, oldest first) and lets go of the role *before* it executes them, so another lane gathers the next batch
//! while this one is at the database. The window therefore bounds the wait of the oldest job, not of every job:
//! a job that arrives late rides with the batch for free.
//!
//! Wake-ups: `push` signals only when the queue goes from empty to non-empty (a gatherer may be waiting for the
//! first job) and when it reaches `batch_max` (the gatherer may be waiting out its window). Every other push finds
//! the gatherer either awake or sleeping towards a deadline that is still right, so it costs no futex call.
//!
//! Not handled on purpose: shutdown (lanes live as long as the process), priorities between kinds, fairness
//! beyond FIFO.

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::app::jobs::ReadJob;

pub struct ReadQueue {
    jobs: Mutex<VecDeque<ReadJob>>,
    /// Signalled when the gatherer may have something to decide (see the module comment).
    arrived: Condvar,
    /// Held by the lane that is currently gathering; serialises gatherers.
    gatherer: Mutex<()>,
    window: Duration,
    batch_max: usize,
}

fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panicking lane must not wedge the others: the queue's data is a plain deque and stays consistent.
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl ReadQueue {
    /// `window` is how long the oldest job waits for company; `batch_max` (at least 1) caps a batch.
    pub fn new(window: Duration, batch_max: usize) -> Arc<ReadQueue> {
        Arc::new(ReadQueue {
            jobs: Mutex::new(VecDeque::new()),
            arrived: Condvar::new(),
            gatherer: Mutex::new(()),
            window,
            batch_max: batch_max.max(1),
        })
    }

    /// Queues a job (called from io threads). Never blocks beyond the short queue lock.
    pub fn push(&self, job: ReadJob) {
        let len = {
            let mut jobs = locked(&self.jobs);
            jobs.push_back(job);
            jobs.len()
        };
        if len == 1 || len == self.batch_max {
            self.arrived.notify_one();
        }
    }

    /// Jobs waiting right now.
    pub fn len(&self) -> usize {
        locked(&self.jobs).len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Blocks until a batch is ready and appends it to `out` (which should be empty). Returns with the gatherer
    /// role released, so the caller can execute the batch while another lane gathers.
    pub fn take_batch(&self, out: &mut Vec<ReadJob>) {
        let _role = locked(&self.gatherer);
        let mut jobs = locked(&self.jobs);
        loop {
            let Some(oldest) = jobs.front() else {
                jobs = self.arrived.wait(jobs).unwrap_or_else(|e| e.into_inner());
                continue;
            };
            if jobs.len() >= self.batch_max {
                break;
            }
            let waited = Instant::now().saturating_duration_since(oldest.queued_at);
            let Some(remaining) = self.window.checked_sub(waited).filter(|r| !r.is_zero()) else {
                break;
            };
            jobs = self
                .arrived
                .wait_timeout(jobs, remaining)
                .unwrap_or_else(|e| e.into_inner())
                .0;
        }
        let n = jobs.len().min(self.batch_max);
        out.extend(jobs.drain(..n));
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::app::jobs::{Field, Origin, ReadKind};
    use crate::net::ConnId;

    pub fn job(viewer: i64, queued_at: Instant) -> ReadJob {
        ReadJob {
            origin: Origin {
                conn: ConnId {
                    io: 0,
                    slot: 0,
                    generation: 0,
                },
                keep_alive: true,
            },
            kind: ReadKind::Tags,
            buf: Vec::new(),
            viewer,
            key: Field::default(),
            token: Field::default(),
            password: Field::default(),
            limit: 0,
            offset: 0,
            queued_at,
        }
    }

    fn viewers(batch: &[ReadJob]) -> Vec<i64> {
        batch.iter().map(|j| j.viewer).collect()
    }

    #[test]
    fn full_batch_does_not_wait_for_the_window() {
        let q = ReadQueue::new(Duration::from_secs(30), 3);
        for v in 1..=5 {
            q.push(job(v, Instant::now()));
        }
        let started = Instant::now();
        let mut batch = Vec::new();
        q.take_batch(&mut batch);
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(viewers(&batch), [1, 2, 3]);
        assert_eq!(q.len(), 2);
    }

    #[test]
    fn partial_batch_leaves_after_the_oldest_job_waited_the_window() {
        let window = Duration::from_millis(60);
        let q = ReadQueue::new(window, 100);
        let queued = Instant::now();
        q.push(job(1, queued));
        q.push(job(2, queued));
        let mut batch = Vec::new();
        q.take_batch(&mut batch);
        assert!(queued.elapsed() >= window);
        assert!(queued.elapsed() < window * 20);
        assert_eq!(viewers(&batch), [1, 2]);
    }

    #[test]
    fn a_job_that_is_already_old_goes_at_once() {
        let q = ReadQueue::new(Duration::from_millis(50), 100);
        q.push(job(9, Instant::now() - Duration::from_secs(1)));
        let started = Instant::now();
        let mut batch = Vec::new();
        q.take_batch(&mut batch);
        assert!(started.elapsed() < Duration::from_millis(40));
        assert_eq!(viewers(&batch), [9]);
    }

    #[test]
    fn late_arrivals_ride_with_the_batch_and_an_empty_queue_blocks() {
        let q = ReadQueue::new(Duration::from_millis(150), 100);
        let producer = {
            let q = Arc::clone(&q);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(30));
                q.push(job(1, Instant::now()));
                std::thread::sleep(Duration::from_millis(30));
                q.push(job(2, Instant::now()));
            })
        };
        let mut batch = Vec::new();
        q.take_batch(&mut batch);
        producer.join().unwrap();
        assert_eq!(viewers(&batch), [1, 2]);
    }

    #[test]
    fn the_gatherer_role_is_released_before_the_caller_executes() {
        let q = ReadQueue::new(Duration::from_millis(5), 1);
        q.push(job(1, Instant::now()));
        q.push(job(2, Instant::now()));
        let (mut first, mut second) = (Vec::new(), Vec::new());
        q.take_batch(&mut first);
        // `first` is still "executing": a second gather must not be blocked by it.
        q.take_batch(&mut second);
        assert_eq!((viewers(&first), viewers(&second)), (vec![1], vec![2]));
    }

    #[test]
    fn two_lanes_split_a_stream_without_losing_or_duplicating_jobs() {
        let q = ReadQueue::new(Duration::from_millis(2), 7);
        let lanes: Vec<_> = (0..2)
            .map(|_| {
                let q = Arc::clone(&q);
                std::thread::spawn(move || {
                    let mut seen = Vec::new();
                    let mut batch = Vec::new();
                    loop {
                        q.take_batch(&mut batch);
                        let stop = batch.iter().any(|j| j.viewer < 0);
                        seen.extend(batch.drain(..).map(|j| j.viewer).filter(|v| *v >= 0));
                        if stop {
                            return seen;
                        }
                    }
                })
            })
            .collect();
        for v in 0..200 {
            q.push(job(v, Instant::now()));
        }
        // One poison job per lane; each lane stops when its batch carries one.
        std::thread::sleep(Duration::from_millis(100));
        q.push(job(-1, Instant::now()));
        std::thread::sleep(Duration::from_millis(30));
        q.push(job(-1, Instant::now()));
        let mut all: Vec<i64> = lanes.into_iter().flat_map(|l| l.join().unwrap()).collect();
        all.sort_unstable();
        assert_eq!(all, (0..200).collect::<Vec<_>>());
    }
}
