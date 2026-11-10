//! [`ReadQueue`]: the queues of read jobs and the rule that turns them into batches.
//!
//! There is one FIFO per request *class* (a class is one SQL statement: the global list, the tag list, the feed, an
//! article, ...). A batch holds jobs of one class only, so its statement carries as many requests as have
//! accumulated for that statement and identical pages, articles and counts inside it are computed once. Batches of
//! mixed kinds would split the same stream into statements of 40 to 100 requests each.
//!
//! One lane at a time is the *gatherer*. It holds the `gatherer` mutex and sleeps on a condition variable until some
//! class is *ready*: its queue holds `batch_max` jobs, or its oldest job has waited the collection window. Among the
//! ready classes it serves the one whose oldest job is oldest, takes up to `batch_max` jobs of it, and lets go of the
//! role *before* the lane executes them, so another lane gathers the next batch meanwhile. Under load the lanes are
//! busy and queues grow beyond the window's worth of requests, so batches grow by themselves up to `batch_max`.
//!
//! Wake-ups: `push` signals only when a class goes from empty to non-empty and when it reaches `batch_max`. Every
//! other push finds the gatherer awake or sleeping towards a deadline that is still right.
//!
//! Not handled on purpose: shutdown (lanes live as long as the process), priorities between classes beyond "oldest
//! first".

use std::collections::VecDeque;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use crate::app::jobs::{ReadJob, ReadKind};

pub struct ReadQueue {
    classes: Mutex<Vec<VecDeque<ReadJob>>>,
    /// Signalled when the gatherer may have something to decide (see the module comment).
    arrived: Condvar,
    /// Held by the lane that is currently gathering; serialises gatherers.
    gatherer: Mutex<()>,
    window: Duration,
    batch_max: usize,
}

fn locked<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    // A panicking lane must not wedge the others: the queues are plain deques and stay consistent.
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// What the gatherer should do next.
enum Verdict {
    /// Serve this class now.
    Serve(usize),
    /// Nothing is ready; the nearest deadline is after this long.
    Wait(Duration),
    /// All queues are empty.
    Idle,
}

impl ReadQueue {
    /// `window` is how long the oldest job of a class waits for company; `batch_max` (at least 1) caps a batch.
    pub fn new(window: Duration, batch_max: usize) -> Arc<ReadQueue> {
        Arc::new(ReadQueue {
            classes: Mutex::new((0..ReadKind::CLASSES).map(|_| VecDeque::new()).collect()),
            arrived: Condvar::new(),
            gatherer: Mutex::new(()),
            window,
            batch_max: batch_max.max(1),
        })
    }

    /// Queues a job (called from io threads). Never blocks beyond the short queue lock.
    pub fn push(&self, job: ReadJob) {
        let class = job.kind.class();
        let len = {
            let mut classes = locked(&self.classes);
            classes[class].push_back(job);
            classes[class].len()
        };
        if len == 1 || len == self.batch_max {
            self.arrived.notify_one();
        }
    }

    /// Jobs waiting right now, all classes together.
    pub fn len(&self) -> usize {
        locked(&self.classes).iter().map(VecDeque::len).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    fn verdict(&self, classes: &[VecDeque<ReadJob>], now: Instant) -> Verdict {
        let mut best: Option<(usize, Instant)> = None;
        let mut nearest: Option<Duration> = None;
        for (class, queue) in classes.iter().enumerate() {
            let Some(head) = queue.front() else { continue };
            let waited = now.saturating_duration_since(head.queued_at);
            let remaining = self.window.checked_sub(waited).filter(|r| !r.is_zero());
            let ready = queue.len() >= self.batch_max || remaining.is_none();
            if ready {
                if best.is_none_or(|(_, oldest)| head.queued_at < oldest) {
                    best = Some((class, head.queued_at));
                }
            } else if let Some(left) = remaining {
                nearest = Some(nearest.map_or(left, |n| n.min(left)));
            }
        }
        match (best, nearest) {
            (Some((class, _)), _) => Verdict::Serve(class),
            (None, Some(wait)) => Verdict::Wait(wait),
            (None, None) => Verdict::Idle,
        }
    }

    /// Blocks until a batch is ready and appends it to `out` (which should be empty). Returns with the gatherer
    /// role released, so the caller can execute the batch while another lane gathers.
    pub fn take_batch(&self, out: &mut Vec<ReadJob>) {
        let _role = locked(&self.gatherer);
        let mut classes = locked(&self.classes);
        loop {
            match self.verdict(&classes, Instant::now()) {
                Verdict::Serve(class) => {
                    let n = classes[class].len().min(self.batch_max);
                    out.extend(classes[class].drain(..n));
                    return;
                }
                Verdict::Wait(wait) => {
                    classes = self
                        .arrived
                        .wait_timeout(classes, wait)
                        .unwrap_or_else(|e| e.into_inner())
                        .0;
                }
                Verdict::Idle => {
                    classes = self
                        .arrived
                        .wait(classes)
                        .unwrap_or_else(|e| e.into_inner());
                }
            }
        }
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::app::jobs::{Field, Origin, ReadKind};
    use crate::net::ConnId;

    pub fn job(viewer: i64, queued_at: Instant) -> ReadJob {
        job_of(ReadKind::Tags, viewer, queued_at)
    }

    pub fn job_of(kind: ReadKind, viewer: i64, queued_at: Instant) -> ReadJob {
        ReadJob {
            origin: Origin {
                conn: ConnId {
                    io: 0,
                    slot: 0,
                    generation: 0,
                },
                keep_alive: true,
            },
            kind,
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
    fn a_batch_holds_one_class_and_the_class_with_the_oldest_job_goes_first() {
        let q = ReadQueue::new(Duration::from_millis(1), 100);
        let old = Instant::now() - Duration::from_secs(1);
        q.push(job_of(ReadKind::Tags, 1, old));
        q.push(job_of(ReadKind::Article, 2, old + Duration::from_millis(1)));
        q.push(job_of(ReadKind::Tags, 3, old + Duration::from_millis(2)));
        q.push(job_of(ReadKind::Article, 4, old + Duration::from_millis(3)));
        let (mut first, mut second) = (Vec::new(), Vec::new());
        q.take_batch(&mut first);
        q.take_batch(&mut second);
        assert_eq!(
            (viewers(&first), viewers(&second)),
            (vec![1, 3], vec![2, 4])
        );
        assert!(q.is_empty());
    }

    #[test]
    fn a_class_that_is_full_goes_before_a_class_that_is_still_waiting() {
        let q = ReadQueue::new(Duration::from_secs(30), 2);
        q.push(job_of(ReadKind::Comments, 1, Instant::now()));
        q.push(job_of(ReadKind::Article, 2, Instant::now()));
        q.push(job_of(ReadKind::Article, 3, Instant::now()));
        let started = Instant::now();
        let mut batch = Vec::new();
        q.take_batch(&mut batch);
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(viewers(&batch), [2, 3]);
        assert_eq!(q.len(), 1);
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
