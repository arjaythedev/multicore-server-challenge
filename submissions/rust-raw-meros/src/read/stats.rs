//! Counters for tuning the read lanes (batch size, how busy the lanes are). Off unless `STATS_SECONDS` is set; the
//! counters are always updated (three relaxed atomic adds per batch, nothing per request).

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Duration;

#[derive(Default)]
pub struct ReadStats {
    batches: AtomicU64,
    jobs: AtomicU64,
    max_jobs: AtomicU64,
    /// Time lanes spent waiting for a batch (gathering) and working on one, summed over lanes.
    wait_ns: AtomicU64,
    busy_ns: AtomicU64,
}

/// The process-wide read statistics.
pub static READ_STATS: ReadStats = ReadStats {
    batches: AtomicU64::new(0),
    jobs: AtomicU64::new(0),
    max_jobs: AtomicU64::new(0),
    wait_ns: AtomicU64::new(0),
    busy_ns: AtomicU64::new(0),
};

impl ReadStats {
    /// One batch of `jobs` requests: the lane waited `wait` for it and needed `busy` to answer it.
    pub fn record(&self, jobs: usize, wait: Duration, busy: Duration) {
        self.batches.fetch_add(1, Relaxed);
        self.jobs.fetch_add(jobs as u64, Relaxed);
        self.max_jobs.fetch_max(jobs as u64, Relaxed);
        self.wait_ns.fetch_add(wait.as_nanos() as u64, Relaxed);
        self.busy_ns.fetch_add(busy.as_nanos() as u64, Relaxed);
    }

    /// Takes the counters and formats them for an interval of `seconds` with `lanes` lanes.
    fn report(&self, seconds: u64, lanes: usize) -> String {
        let batches = self.batches.swap(0, Relaxed);
        let jobs = self.jobs.swap(0, Relaxed);
        let max_jobs = self.max_jobs.swap(0, Relaxed);
        let wait = self.wait_ns.swap(0, Relaxed) as f64;
        let busy = self.busy_ns.swap(0, Relaxed) as f64;
        let lane_ns = (seconds as f64) * 1e9 * lanes as f64;
        format!(
            "read: {:.1} batches/s, {:.0} jobs/s, avg batch {:.0}, max {}, lanes busy {:.0}% waiting {:.0}%",
            batches as f64 / seconds as f64,
            jobs as f64 / seconds as f64,
            if batches == 0 {
                0.0
            } else {
                jobs as f64 / batches as f64
            },
            max_jobs,
            100.0 * busy / lane_ns,
            100.0 * wait / lane_ns,
        )
    }
}

/// Prints a line every `seconds` to stderr (the service journal).
pub fn spawn_reporter(seconds: u64, lanes: usize) {
    if seconds == 0 {
        return;
    }
    let spawned = std::thread::Builder::new()
        .name("stats".into())
        .spawn(move || {
            loop {
                std::thread::sleep(Duration::from_secs(seconds));
                eprintln!("{}", READ_STATS.report(seconds, lanes));
            }
        });
    if let Err(err) = spawned {
        eprintln!("stats thread not started: {err}");
    }
}
