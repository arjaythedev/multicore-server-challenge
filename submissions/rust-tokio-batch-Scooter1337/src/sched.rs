//! One queue for every read connection. A connection that has finished its round trip takes the oldest waiting
//! request together with the other waiting requests of the same family (up to a cap), so no connection sits idle
//! while another has a backlog, and requests that wait together share one SQL execution. Jobs hold only the
//! encoded request and its reply channel; nothing is retained once a reply is sent.
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Instant,
};

use bytes::Bytes;
use tokio::sync::{Notify, oneshot};
use tokio_postgres::Row;

use crate::writer::Error;

pub struct ReadJob {
    pub family: usize,
    pub frame: Bytes,
    pub reply: oneshot::Sender<Result<Vec<Row>, Error>>,
    seq: u64,
    /// Only with `BATCH_STATS` (the clock read is per request).
    queued: Option<Instant>,
}

struct State {
    queues: Vec<VecDeque<ReadJob>>,
    seq: u64,
    idle: Vec<Arc<Notify>>,
}

pub struct Sched {
    state: Mutex<State>,
    cap: usize,
    /// Per-family caps under `cap` (feed batches cost in proportion to their size, so a long one holds its
    /// connection while other families wait).
    caps: Vec<usize>,
    mixed: bool,
}

impl Sched {
    pub fn new(families: usize, cap: usize, mixed: bool) -> Self {
        Sched {
            state: Mutex::new(State {
                queues: (0..families).map(|_| VecDeque::new()).collect(),
                seq: 0,
                idle: Vec::new(),
            }),
            cap: cap.max(1),
            caps: vec![cap.max(1); families],
            mixed,
        }
    }

    /// Caps one family's share of a take.
    pub fn with_cap(mut self, family: usize, cap: usize) -> Self {
        self.caps[family] = cap.clamp(1, self.cap);
        self
    }

    pub fn push(
        &self,
        family: usize,
        frame: Bytes,
        reply: oneshot::Sender<Result<Vec<Row>, Error>>,
    ) {
        let wake = {
            let mut s = self.state.lock().expect("read queue");
            s.seq += 1;
            let seq = s.seq;
            s.queues[family].push_back(ReadJob {
                family,
                frame,
                reply,
                seq,
                queued: stats::on().then(Instant::now),
            });
            s.idle.pop()
        };
        if let Some(n) = wake {
            n.notify_one();
        }
    }

    /// Jobs this connection could not run (it closed before starting them) go back at their original age.
    pub fn requeue(&self, jobs: Vec<ReadJob>) {
        let wake = {
            let mut s = self.state.lock().expect("read queue");
            for job in jobs.into_iter().rev() {
                let q = &mut s.queues[job.family];
                let at = q.iter().position(|j| j.seq > job.seq).unwrap_or(q.len());
                q.insert(at, job);
            }
            s.idle.pop()
        };
        if let Some(n) = wake {
            n.notify_one();
        }
    }

    /// Waits for work. The result is non-empty and grouped by family (oldest family first).
    pub async fn take(&self, me: &Arc<Notify>) -> Vec<ReadJob> {
        loop {
            {
                let mut s = self.state.lock().expect("read queue");
                let jobs = s.take(self.cap, &self.caps, self.mixed);
                if !jobs.is_empty() {
                    stats::waited(&jobs);
                    // More work is waiting: hand it to another idle connection rather than leave it for our
                    // next round trip.
                    let more = s.queues.iter().any(|q| !q.is_empty());
                    let wake = if more { s.idle.pop() } else { None };
                    drop(s);
                    if let Some(n) = wake {
                        n.notify_one();
                    }
                    return jobs;
                }
                s.idle.push(me.clone());
            }
            me.notified().await;
        }
    }
}

impl State {
    fn oldest(&self) -> Option<usize> {
        self.queues
            .iter()
            .enumerate()
            .filter_map(|(i, q)| q.front().map(|j| (j.seq, i)))
            .min()
            .map(|(_, i)| i)
    }

    fn take(&mut self, cap: usize, caps: &[usize], mixed: bool) -> Vec<ReadJob> {
        let mut out = Vec::new();
        while out.len() < cap {
            let Some(f) = self.oldest() else { break };
            let q = &mut self.queues[f];
            let n = q.len().min(cap - out.len()).min(caps[f]);
            out.extend(q.drain(..n));
            if !mixed {
                break;
            }
        }
        out
    }
}

/// Batch-size counters for load tests (`BATCH_STATS=1` prints a line every 10 s; otherwise unused).
pub mod stats {
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};

    const F: usize = 16;
    static ON: AtomicBool = AtomicBool::new(false);
    static TAKES: AtomicU64 = AtomicU64::new(0);
    static JOBS: [AtomicU64; F] = [const { AtomicU64::new(0) }; F];
    static GROUPS: [AtomicU64; F] = [const { AtomicU64::new(0) }; F];
    static SHARED: [AtomicU64; F] = [const { AtomicU64::new(0) }; F];
    static WAIT_NS: AtomicU64 = AtomicU64::new(0);
    static WAIT_MAX_NS: AtomicU64 = AtomicU64::new(0);
    static BUSY_NS: AtomicU64 = AtomicU64::new(0);
    static IDLE_NS: AtomicU64 = AtomicU64::new(0);

    pub fn start() {
        if std::env::var_os("BATCH_STATS").is_none() {
            return;
        }
        ON.store(true, Relaxed);
        std::thread::spawn(|| {
            loop {
                std::thread::sleep(std::time::Duration::from_secs(10));
                let takes = TAKES.swap(0, Relaxed);
                let mut line = format!("[batch-stats] takes={takes}");
                let mut total = 0;
                for f in 0..F {
                    let (j, g, s) = (
                        JOBS[f].swap(0, Relaxed),
                        GROUPS[f].swap(0, Relaxed),
                        SHARED[f].swap(0, Relaxed),
                    );
                    total += j;
                    if j > 0 {
                        line += &format!(" f{f}={j}/{g}/{s}");
                    }
                }
                let (wait, wait_max) = (WAIT_NS.swap(0, Relaxed), WAIT_MAX_NS.swap(0, Relaxed));
                let (busy, idle) = (BUSY_NS.swap(0, Relaxed), IDLE_NS.swap(0, Relaxed));
                eprintln!(
                    "{line} jobs={total} per_take={:.2} wait_us={:.0} wait_max_us={} take_us={:.0} conn_idle={:.1}%",
                    total as f64 / takes.max(1) as f64,
                    wait as f64 / total.max(1) as f64 / 1e3,
                    wait_max / 1000,
                    busy as f64 / takes.max(1) as f64 / 1e3,
                    100.0 * idle as f64 / (busy + idle).max(1) as f64,
                );
            }
        });
    }

    #[inline]
    pub(super) fn on() -> bool {
        ON.load(Relaxed)
    }

    /// Queue wait of the jobs a connection just took.
    pub(super) fn waited(jobs: &[super::ReadJob]) {
        if ON.load(Relaxed) {
            for job in jobs.iter().filter_map(|j| j.queued) {
                let ns = job.elapsed().as_nanos() as u64;
                WAIT_NS.fetch_add(ns, Relaxed);
                WAIT_MAX_NS.fetch_max(ns, Relaxed);
            }
        }
    }

    /// A read connection's time waiting for work and running its take.
    #[inline]
    pub fn conn_time(idle: std::time::Duration, busy: std::time::Duration) {
        if ON.load(Relaxed) {
            IDLE_NS.fetch_add(idle.as_nanos() as u64, Relaxed);
            BUSY_NS.fetch_add(busy.as_nanos() as u64, Relaxed);
        }
    }

    #[inline]
    pub fn take() {
        if ON.load(Relaxed) {
            TAKES.fetch_add(1, Relaxed);
        }
    }

    /// One family group of `n` jobs in a take; `shared` = it used the shared-enrichment SQL.
    #[inline]
    pub fn group(family: usize, n: usize, shared: bool) {
        if ON.load(Relaxed) && family < F {
            JOBS[family].fetch_add(n as u64, Relaxed);
            GROUPS[family].fetch_add(1, Relaxed);
            if shared {
                SHARED[family].fetch_add(1, Relaxed);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn job(s: &Sched, family: usize) -> oneshot::Receiver<Result<Vec<Row>, Error>> {
        let (tx, rx) = oneshot::channel();
        s.push(family, Bytes::new(), tx);
        rx
    }

    #[tokio::test]
    async fn oldest_family_first_with_all_its_waiting_jobs() {
        let s = Sched::new(3, 64, false);
        let _r: Vec<_> = [2, 1, 2, 0, 2].iter().map(|&f| job(&s, f)).collect();
        let me = Arc::new(Notify::new());
        let a = s.take(&me).await;
        assert_eq!(a.iter().map(|j| j.family).collect::<Vec<_>>(), [2, 2, 2]);
        let b = s.take(&me).await;
        assert_eq!(b.iter().map(|j| j.family).collect::<Vec<_>>(), [1]);
        s.requeue(b);
        let c = s.take(&me).await;
        assert_eq!(c.iter().map(|j| j.family).collect::<Vec<_>>(), [1]);
    }

    #[tokio::test]
    async fn mixed_fills_the_cap_in_age_order() {
        let s = Sched::new(3, 4, true);
        let _r: Vec<_> = [2, 1, 2, 0, 2].iter().map(|&f| job(&s, f)).collect();
        let me = Arc::new(Notify::new());
        let a = s.take(&me).await;
        assert_eq!(a.iter().map(|j| j.family).collect::<Vec<_>>(), [2, 2, 2, 1]);
    }

    #[tokio::test]
    async fn a_family_cap_leaves_the_rest_queued() {
        let s = Sched::new(3, 64, false).with_cap(2, 2);
        let _r: Vec<_> = [2, 1, 2, 0, 2].iter().map(|&f| job(&s, f)).collect();
        let me = Arc::new(Notify::new());
        assert_eq!(s.take(&me).await.len(), 2);
        assert_eq!(s.take(&me).await[0].family, 1);
    }
}
