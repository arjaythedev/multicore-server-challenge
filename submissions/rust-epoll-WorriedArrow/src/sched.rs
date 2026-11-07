//! Read scheduling by class. Reads queue by kind: feeds, comment threads, and everything else ("fast": tags, users,
//! logins, profiles, articles, lists, write read-backs). A free read lane takes the whole queue of one class, so a
//! batch holds one kind of work: a fast batch never waits for a feed statement, and a class's batch shares its
//! lookups across every request of that class that waited the gap.
//!
//! - Each class starts a batch at most every `gap` (since its last batch started), and a request is taken at the
//!   latest `gap + min_age` after it arrived. At low load a request waits only `min_age`.
//! - At most `max_active` batches run at once, and each class at most its cap, plus one when its oldest request is
//!   the oldest of all, plus one for feeds and comments when their oldest has waited `borrow_age` and the fast class
//!   has a lane to spare, plus one for any class whose oldest has waited `starve_age`. A class whose work outgrows
//!   its cap (feeds near saturation) gets lanes before its queue runs away, without starving the others.
//! - Among the classes that are due, the one whose oldest request has waited longest goes first; heads within 2 ms
//!   of each other go in class order, fast reads first.

use crate::db::{Read, ReadJob};
use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::{Duration, Instant};

pub const FAST: usize = 0;
pub const CMTS: usize = 1;
pub const FEED: usize = 2;
const CLASSES: usize = 3;
const TIE: Duration = Duration::from_millis(2);

/// Feeds in the fast class (FEED_CLASS=0): one batch then enriches the articles of lists, article pages and feeds
/// together, each counted once, and the feed statement runs on the lane's second connection beside the rest.
pub static FEED_OWN: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

pub fn class_of(r: &Read) -> usize {
    match r {
        Read::Feed { .. } if FEED_OWN.load(std::sync::atomic::Ordering::Relaxed) => FEED,
        Read::Feed { .. } => FAST,
        Read::Comments { .. } => CMTS,
        _ => FAST,
    }
}

pub struct Config {
    pub gap: [Duration; CLASSES],
    pub min_age: Duration,
    pub caps: [usize; CLASSES],
    pub max_active: usize,
    pub max_batch: usize,
    pub borrow_age: Duration,
    pub starve_age: Duration,
}

struct State {
    q: [VecDeque<(Instant, ReadJob)>; CLASSES],
    inflight: [usize; CLASSES],
    last_start: [Option<Instant>; CLASSES],
    active: usize,
}

pub struct Sched {
    m: Mutex<State>,
    cv: Condvar,
}

pub static READS: Sched = Sched::new();

impl Sched {
    const fn new() -> Sched {
        Sched {
            m: Mutex::new(State {
                q: [VecDeque::new(), VecDeque::new(), VecDeque::new()],
                inflight: [0; CLASSES],
                last_start: [None; CLASSES],
                active: 0,
            }),
            cv: Condvar::new(),
        }
    }

    pub fn push(&self, job: ReadJob) {
        let c = class_of(&job.kind);
        let mut g = self.m.lock().unwrap();
        let was_empty = g.q[c].is_empty();
        g.q[c].push_back((Instant::now(), job));
        drop(g);
        // A waiting lane sleeps until the next due time it knew of; a class that was empty had none.
        if was_empty {
            self.cv.notify_one();
        }
    }

    /// Queues every job of `jobs` (emptying it) under one lock: an IO thread hands over a whole event-loop pass at once.
    pub fn push_many(&self, jobs: &mut Vec<ReadJob>) {
        if jobs.is_empty() {
            return;
        }
        let now = Instant::now();
        let mut g = self.m.lock().unwrap();
        let mut woke = false;
        for job in jobs.drain(..) {
            let c = class_of(&job.kind);
            woke |= g.q[c].is_empty();
            g.q[c].push_back((now, job));
        }
        drop(g);
        if woke {
            self.cv.notify_one();
        }
    }

    /// Blocks until a class is due and has room, then moves its queue (up to `max_batch`) into `out`. Returns the
    /// class; the caller hands it back to `done` when the batch is answered.
    pub fn take(&self, cfg: &Config, out: &mut Vec<ReadJob>) -> usize {
        let mut g = self.m.lock().unwrap();
        loop {
            let now = Instant::now();
            let oldest = (0..CLASSES).filter_map(|c| g.q[c].front().map(|f| (f.0, c))).min().map(|(_, c)| c);
            let mut pick: Option<(Instant, usize)> = None;
            let mut wake: Option<Instant> = None;
            if g.active < cfg.max_active {
                for c in 0..CLASSES {
                    let Some(&(head, _)) = g.q[c].front() else { continue };
                    let age = now.saturating_duration_since(head);
                    let cap = cfg.caps[c]
                        + usize::from(oldest == Some(c))
                        + usize::from(c != FAST && age >= cfg.borrow_age && g.inflight[FAST] < cfg.caps[FAST])
                        + usize::from(age >= cfg.starve_age);
                    if g.inflight[c] >= cap {
                        // The cap grows once the head has waited borrow_age or starve_age: wake then to look again.
                        let grow = [cfg.borrow_age, cfg.starve_age].into_iter().map(|a| head + a).filter(|&t| t > now).min();
                        if let Some(t) = grow {
                            if wake.is_none_or(|w| t < w) {
                                wake = Some(t);
                            }
                        }
                        continue;
                    }
                    // Due once the head has waited min_age and the class's gap has passed, or in any case once the
                    // head has waited gap + min_age.
                    let gap_at = g.last_start[c].map_or(now, |t| t + cfg.gap[c]);
                    let due = (head + cfg.min_age).max(gap_at).min(head + cfg.gap[c] + cfg.min_age);
                    if due <= now {
                        // Classes are visited in order, so a later one must be older by more than 2 ms.
                        if pick.is_none_or(|(h, _)| head + TIE < h) {
                            pick = Some((head, c));
                        }
                    } else if wake.is_none_or(|w| due < w) {
                        wake = Some(due);
                    }
                }
            }
            if let Some((head, c)) = pick {
                let k = &crate::stats::CLASS[c];
                crate::stats::max(&k.max_queue, g.q[c].len() as u64);
                crate::stats::max(&k.max_active, g.active as u64 + 1);
                k.head_wait_ns.fetch_add(now.saturating_duration_since(head).as_nanos() as u64, std::sync::atomic::Ordering::Relaxed);
                let n = g.q[c].len().min(cfg.max_batch);
                k.batches.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                k.jobs.fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
                out.extend(g.q[c].drain(..n).map(|(_, j)| j));
                g.inflight[c] += 1;
                g.active += 1;
                g.last_start[c] = Some(now);
                // Another class may be due too, for another lane.
                if (0..CLASSES).any(|k| !g.q[k].is_empty()) {
                    self.cv.notify_one();
                }
                return c;
            }
            g = match wake {
                Some(w) => self.cv.wait_timeout(g, w.saturating_duration_since(now)).unwrap().0,
                None => self.cv.wait(g).unwrap(),
            };
        }
    }

    /// A batch of class `c` is answered: its lane is free for another.
    pub fn done(&self, c: usize) {
        let mut g = self.m.lock().unwrap();
        g.inflight[c] -= 1;
        g.active -= 1;
        let pending = (0..CLASSES).any(|k| !g.q[k].is_empty());
        drop(g);
        if pending {
            self.cv.notify_one();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn classes() {
        assert_eq!(class_of(&Read::Feed { lim: 10, off: 0 }), FEED);
        assert_eq!(class_of(&Read::Comments { slug: "a".into() }), CMTS);
        assert_eq!(class_of(&Read::Tags), FAST);
    }
}
