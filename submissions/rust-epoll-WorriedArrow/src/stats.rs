//! Load counters for the service log: every 10 s (STATS=1, the default) one line on the box and the process, one on
//! the IO threads, one per read class and one on writes and hashing. Each counter is a relaxed atomic added once per
//! event-loop pass, batch, write group or hash run, so they cost nothing next to the work they count.

use std::sync::atomic::{AtomicU64, Ordering::Relaxed};
use std::time::Duration;

const MAX_IO: usize = 64;

pub struct Io {
    pub busy_ns: AtomicU64,
    pub wait_ns: AtomicU64,
    pub events: AtomicU64,
}

#[allow(clippy::declare_interior_mutable_const)]
const IO0: Io = Io { busy_ns: AtomicU64::new(0), wait_ns: AtomicU64::new(0), events: AtomicU64::new(0) };
pub static IO: [Io; MAX_IO] = [IO0; MAX_IO];

/// Per read class: batches taken, requests, summed wait of each batch's oldest request (ns), largest queue seen.
pub struct Class {
    pub batches: AtomicU64,
    pub jobs: AtomicU64,
    pub head_wait_ns: AtomicU64,
    pub max_queue: AtomicU64,
    pub max_active: AtomicU64,
}

#[allow(clippy::declare_interior_mutable_const)]
const C0: Class = Class {
    batches: AtomicU64::new(0),
    jobs: AtomicU64::new(0),
    head_wait_ns: AtomicU64::new(0),
    max_queue: AtomicU64::new(0),
    max_active: AtomicU64::new(0),
};
pub static CLASS: [Class; 3] = [C0; 3];

pub static WRITE_GROUPS: AtomicU64 = AtomicU64::new(0);
pub static WRITES: AtomicU64 = AtomicU64::new(0);
pub static WRITE_NS: AtomicU64 = AtomicU64::new(0);
pub static HASHES: AtomicU64 = AtomicU64::new(0);

pub fn max(a: &AtomicU64, v: u64) {
    a.fetch_max(v, Relaxed);
}

fn take(a: &AtomicU64) -> u64 {
    a.swap(0, Relaxed)
}

/// The box's CPU time by kind (/proc/stat "cpu" line), in ticks.
fn box_cpu() -> Option<[u64; 8]> {
    let s = std::fs::read_to_string("/proc/stat").ok()?;
    let line = s.lines().next()?;
    let mut v = [0u64; 8];
    for (i, f) in line.split_whitespace().skip(1).take(8).enumerate() {
        v[i] = f.parse().ok()?;
    }
    Some(v)
}

fn self_cpu_ns() -> u64 {
    let mut ru: libc::rusage = unsafe { std::mem::zeroed() };
    unsafe { libc::getrusage(libc::RUSAGE_SELF, &mut ru) };
    let t = |tv: libc::timeval| tv.tv_sec as u64 * 1_000_000_000 + tv.tv_usec as u64 * 1000;
    t(ru.ru_utime) + t(ru.ru_stime)
}

pub fn run(io_threads: usize) {
    let mut prev_box = box_cpu();
    let mut prev_self = self_cpu_ns();
    let period = Duration::from_secs(10);
    loop {
        std::thread::sleep(period);
        let now_box = box_cpu();
        let now_self = self_cpu_ns();
        let cores = |ns: u64| ns as f64 / period.as_nanos() as f64;
        if let (Some(a), Some(b)) = (prev_box, now_box) {
            // user nice system idle iowait irq softirq steal
            let d: Vec<u64> = (0..8).map(|i| b[i].saturating_sub(a[i])).collect();
            let total: u64 = d.iter().sum::<u64>().max(1);
            let pct = |x: u64| 100.0 * x as f64 / total as f64;
            eprintln!(
                "stats box: busy {:.0}% (user {:.0} sys {:.0} softirq {:.0}) idle {:.0}% iowait {:.0}% steal {:.0}%; server {:.2} cores",
                100.0 - pct(d[3] + d[4]),
                pct(d[0] + d[1]),
                pct(d[2]),
                pct(d[5] + d[6]),
                pct(d[3]),
                pct(d[4]),
                pct(d[7]),
                cores(now_self.saturating_sub(prev_self)),
            );
        }
        prev_box = now_box;
        prev_self = now_self;
        let mut io = String::new();
        for (i, t) in IO.iter().take(io_threads).enumerate() {
            let busy = take(&t.busy_ns);
            let wait = take(&t.wait_ns);
            let ev = take(&t.events);
            io.push_str(&format!(" t{i} {:.0}% busy {}k ev", 100.0 * busy as f64 / (busy + wait).max(1) as f64, ev / 1000));
        }
        eprintln!("stats io:{io}");
        for (c, name) in ["fast", "comments", "feeds"].iter().enumerate() {
            let k = &CLASS[c];
            let n = take(&k.batches);
            let jobs = take(&k.jobs);
            let wait = take(&k.head_wait_ns);
            let mq = take(&k.max_queue);
            let ma = take(&k.max_active);
            if n > 0 {
                eprintln!(
                    "stats {name}: {n} batches, {} per batch, oldest waited {:.1} ms, max queue {mq}, max in flight {ma}",
                    jobs / n,
                    wait as f64 / n as f64 / 1e6
                );
            }
        }
        let g = take(&WRITE_GROUPS);
        let w = take(&WRITES);
        let wn = take(&WRITE_NS);
        let h = take(&HASHES);
        eprintln!(
            "stats writes: {g} groups, {} per group, {:.1} ms per group; {h} hashes",
            if g > 0 { w / g } else { 0 },
            if g > 0 { wn as f64 / g as f64 / 1e6 } else { 0.0 },
        );
    }
}
