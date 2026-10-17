//! bcrypt runs on its own threads so a 50-70 ms hash never stalls an event loop. Results go back to the
//! submitting loop through its inbox and wake it with a `mio::Waker`.
//!
//! Jobs are hashed up to four at a time by the interleaved `bcrypt2` core: one primary worker holds the first queued
//! job for up to `pair_wait()` so neighbours can join it; further workers only run when a full batch (or a very old
//! job) is waiting. Every hash is still a full cost-10 bcrypt and every verify recomputes it; nothing is cached.

use std::collections::VecDeque;
use std::net::TcpStream as StdTcpStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use ring::rand::{SecureRandom, SystemRandom};

use crate::bcrypt2;

pub const BCRYPT_COST: u32 = 10;

pub enum Job {
    Hash(String),
    Verify { password: String, hash: String },
}

pub enum JobResult {
    Hashed(Option<String>),
    Verified(bool),
}

/// Where a finished job goes: the loop's inbox plus the connection (slab index, generation) that asked for it.
pub struct Task {
    pub job: Job,
    pub inbox: Arc<Inbox>,
    pub conn: (usize, u32),
    /// Set by the loop when the client connection closes, so a queued hash for a departed client is skipped.
    pub cancelled: Arc<AtomicBool>,
}

/// Everything other threads hand to an event loop.
pub struct Inbox {
    pub bcrypt: Mutex<Vec<((usize, u32), JobResult)>>,
    /// Postgres connections re-established after a failure: (connection index, stream).
    pub reconnected: Mutex<Vec<(usize, StdTcpStream)>>,
    pub waker: mio::Waker,
}

const MAX_LANES: usize = 4;
/// A non-primary worker starts a short batch only for a job this old; keep it well above `pair_wait()`.
const OVERFLOW_AGE: Duration = Duration::from_millis(500);

/// How long the primary worker lets the oldest job wait for company. Login latency is nowhere near the client
/// timeout and logins are ~0.1% of requests, so trading ~200 ms for ~3x fewer CPU-seconds per hash is cheap.
fn pair_wait() -> Duration {
    static W: OnceLock<Duration> = OnceLock::new();
    *W.get_or_init(|| {
        let ms = std::env::var("BCRYPT_PAIR_WAIT_MS").ok().and_then(|v| v.parse().ok()).unwrap_or(200u64);
        Duration::from_millis(ms.min(400))
    })
}

struct Queued {
    at: Instant,
    task: Task,
}

pub struct BcryptPool {
    queue: Mutex<VecDeque<Queued>>,
    ready: Condvar,
    cap: usize,
}

impl BcryptPool {
    /// `threads` >= 1; worker 0 is the batching primary, the rest are overflow workers (2 is plenty).
    pub fn start(threads: usize, cap: usize) -> Arc<BcryptPool> {
        let pool = Arc::new(BcryptPool { queue: Mutex::new(VecDeque::new()), ready: Condvar::new(), cap });
        for i in 0..threads.max(1) {
            let p = pool.clone();
            std::thread::Builder::new()
                .name(format!("bcrypt-{i}"))
                .spawn(move || {
                    lower_priority();
                    p.work(i == 0)
                })
                .expect("spawn bcrypt thread");
        }
        pool
    }

    pub fn queue_len(&self) -> usize {
        self.queue.lock().unwrap().len()
    }

    /// Queues a job; gives it back when the queue is full (the caller answers 503).
    pub fn submit(&self, task: Task) -> Result<(), Task> {
        let mut q = self.queue.lock().unwrap();
        if q.len() >= self.cap {
            return Err(task);
        }
        q.push_back(Queued { at: Instant::now(), task });
        drop(q);
        self.ready.notify_all();
        Ok(())
    }

    /// Blocks until a batch is due: a full batch right away, otherwise once the oldest live job has waited out the
    /// worker's hold time (primary: `pair_wait()`, others: `OVERFLOW_AGE`).
    fn take_batch(&self, primary: bool) -> Vec<Task> {
        let hold = if primary { pair_wait() } else { OVERFLOW_AGE };
        let mut q = self.queue.lock().unwrap();
        loop {
            q.retain(|e| !e.task.cancelled.load(Ordering::Relaxed));
            let Some(first) = q.front() else {
                q = self.ready.wait(q).unwrap();
                continue;
            };
            let age = first.at.elapsed();
            if q.len() >= MAX_LANES || age >= hold {
                let n = q.len().min(MAX_LANES);
                return q.drain(..n).map(|e| e.task).collect();
            }
            q = self.ready.wait_timeout(q, hold - age).unwrap().0;
        }
    }

    fn work(&self, primary: bool) {
        let rng = SystemRandom::new();
        loop {
            let batch = self.take_batch(primary);
            let results = run_batch(&rng, &batch);
            for (task, result) in batch.into_iter().zip(results) {
                task.inbox.bcrypt.lock().unwrap().push((task.conn, result));
                let _ = task.inbox.waker.wake();
            }
        }
    }
}

/// Computes every job in `batch` (1..=4) with one interleaved pass. Jobs that cannot ride a cost-10 lane (malformed
/// or other-cost stored hash) are answered individually, with the same outcomes as `bcrypt::verify`.
fn run_batch(rng: &SystemRandom, batch: &[Task]) -> Vec<JobResult> {
    let mut results: Vec<Option<JobResult>> = batch.iter().map(|_| None).collect();
    let mut lane_of: Vec<usize> = Vec::new();
    let mut salts: Vec<[u8; 16]> = Vec::new();
    let mut pws: Vec<&[u8]> = Vec::new();
    let mut expect: Vec<Option<bcrypt2::Parsed>> = Vec::new();
    for (i, t) in batch.iter().enumerate() {
        match &t.job {
            Job::Hash(pw) => {
                let mut salt = [0u8; 16];
                if rng.fill(&mut salt).is_err() {
                    results[i] = Some(JobResult::Hashed(None));
                    continue;
                }
                lane_of.push(i);
                salts.push(salt);
                pws.push(pw.as_bytes());
                expect.push(None);
            }
            Job::Verify { password, hash } => match bcrypt2::parse(hash) {
                None => results[i] = Some(JobResult::Verified(false)),
                Some(p) if p.cost != BCRYPT_COST => {
                    results[i] = Some(JobResult::Verified(bcrypt::verify(password, hash).unwrap_or(false)));
                }
                Some(p) => {
                    lane_of.push(i);
                    salts.push(p.salt);
                    pws.push(password.as_bytes());
                    expect.push(Some(p));
                }
            },
        }
    }
    let out = bcrypt2::bcrypt_batch(BCRYPT_COST, &salts, &pws);
    for (lane, &i) in lane_of.iter().enumerate() {
        results[i] = Some(match &expect[lane] {
            None => JobResult::Hashed(Some(bcrypt2::format_2b(BCRYPT_COST, &salts[lane], &out[lane]))),
            Some(p) => JobResult::Verified(bcrypt2::matches(p, &out[lane])),
        });
    }
    results.into_iter().map(|r| r.expect("every job answered")).collect()
}

/// SCHED_BATCH + nice `BCRYPT_NICE` (default 10): hashing yields to the event loops and Postgres, but keeps a real
/// share of the CPU when the box is saturated (nice 19 / SCHED_IDLE would starve logins into timeouts). Best effort;
/// failures are ignored.
fn lower_priority() {
    #[cfg(target_os = "linux")]
    unsafe {
        let nice = std::env::var("BCRYPT_NICE").ok().and_then(|v| v.parse::<i32>().ok()).unwrap_or(10).clamp(0, 19);
        let param = libc::sched_param { sched_priority: 0 };
        libc::sched_setscheduler(0, libc::SCHED_BATCH, &param);
        libc::setpriority(libc::PRIO_PROCESS, libc::syscall(libc::SYS_gettid) as libc::id_t, nice);
    }
}
