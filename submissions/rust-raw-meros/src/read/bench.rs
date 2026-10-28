//! Measurements (`#[ignore]`): how much Postgres backend CPU a request costs when it runs in a batch of 1, 16 or
//! 128 of its kind, against the SPEC.md reference SQL executed one request at a time.
//!
//! Run: `cargo test --release --lib read::bench -- --ignored --nocapture --test-threads=1`. The database is
//! `READ_BENCH_URL`, default the full seed `conduit_seed`; everything here only reads. `READ_BENCH_KINDS=tag` runs
//! only the kinds whose name contains the text.
//!
//! The backend's CPU time comes from `/proc/<pid>/schedstat` (nanoseconds of run time, not tick-sampled) of the
//! backend that serves the connection; the pid is asked from the server with `pg_backend_pid()`. Every
//! configuration is run once unmeasured first (caches, plan cache), then measured; the batched run and the
//! reference run see the very same requests. Parallel workers are off, so the backend is the whole cost.

use std::time::Instant;

use crate::app::jobs::{ListKind, ReadKind};
use crate::pg::Connection;

use super::harness::{Harness, Rng};
use super::reference::Req;
use super::session::SESSION_OPTIONS;

const DEFAULT_SEED_URL: &str = "postgres://conduit:conduit@127.0.0.1:5433/conduit_seed";
const SIZES: [usize; 3] = [1, 16, 128];
/// Repetitions of a batch of one request (more, because one request is a small sample).
const REPS_SINGLE: usize = 600;
const REPS: usize = 200;
const MIXED_BATCH: usize = 64;
const TOKEN: &str = "header.payload.signature";

fn bench_url() -> String {
    std::env::var("READ_BENCH_URL").unwrap_or_else(|_| DEFAULT_SEED_URL.to_owned())
}

/// CPU nanoseconds the process `pid` (or this thread) has run, from schedstat.
fn schedstat_ns(path: &str) -> u64 {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| text.split_whitespace().next().and_then(|n| n.parse().ok()))
        .unwrap_or(0)
}

fn backend_ns(pid: i32) -> u64 {
    schedstat_ns(&format!("/proc/{pid}/schedstat"))
}

fn thread_ns() -> u64 {
    schedstat_ns("/proc/thread-self/schedstat")
}

fn backend_pid(conn: &mut Connection, h: &mut crate::pg::Results) -> i32 {
    let stmt = conn
        .prepare("bench_pid", "select pg_backend_pid()", &[])
        .unwrap();
    conn.push(&stmt, &[]).unwrap();
    conn.flush_and_collect(h).unwrap();
    h.statement(0).row(0).unwrap().i32(0).unwrap()
}

/// Request sources shaped like WORKLOAD.md: popular tags and prolific authors are Zipf-like, article links skew to
/// recent articles, page 1 is 70% of the views.
struct Source {
    tags: Vec<String>,
    authors: Vec<String>,
    favoriters: Vec<String>,
    slugs: Vec<String>,
    users: Vec<i64>,
    rng: Rng,
}

impl Source {
    fn sample(h: &mut Harness) -> Source {
        let tags = h.strings("select t.name from tags t join (select tag_id, count(*) c from article_tags group by tag_id) x on x.tag_id = t.id order by x.c desc");
        let authors = h.strings("select u.username from users u join (select author_id, count(*) c from articles group by author_id order by c desc limit 3000) a on a.author_id = u.id order by a.c desc");
        let favoriters = h.strings("select u.username from users u join (select user_id, count(*) c from favorites group by user_id order by c desc limit 3000) f on f.user_id = u.id order by f.c desc");
        let slugs = h.strings("select slug from articles order by id desc limit 5000");
        let users = h
            .strings("select id::text from users order by random() limit 5000")
            .iter()
            .map(|s| s.parse().unwrap())
            .collect();
        Source {
            tags,
            authors,
            favoriters,
            slugs,
            users,
            rng: Rng(0xbe9c_0001),
        }
    }

    fn unit(&mut self) -> f64 {
        (self.rng.next() >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Index with a power-law skew towards 0: `exponent` 1 is uniform, larger is more skewed.
    fn skewed(&mut self, n: usize, exponent: i32) -> usize {
        ((n as f64) * self.unit().powi(exponent)) as usize % n.max(1)
    }

    /// An element of the list `of` selects, skewed towards its front.
    fn skewed_pick(&mut self, of: impl Fn(&Source) -> &Vec<String>, exponent: i32) -> String {
        let len = of(self).len();
        let at = self.skewed(len, exponent);
        of(self)[at].clone()
    }

    fn viewer(&mut self) -> i64 {
        if self.rng.below(10) == 0 {
            0
        } else {
            self.users[self.rng.below(self.users.len())]
        }
    }

    fn page(&mut self, limit: i64) -> i64 {
        if self.rng.below(10) < 7 {
            0
        } else {
            limit * (1 + self.rng.below(4) as i64)
        }
    }

    fn request(&mut self, kind: ReadKind) -> Req {
        let viewer = self.viewer();
        match kind {
            ReadKind::List(ListKind::All) => {
                Req::list(ListKind::All, viewer, "", 10, self.page(10))
            }
            ReadKind::List(ListKind::Tag) => {
                let tag = self.skewed_pick(|s| &s.tags, 2);
                Req::list(ListKind::Tag, viewer, &tag, 10, self.page(10))
            }
            ReadKind::List(ListKind::Author) => {
                let author = self.skewed_pick(|s| &s.authors, 5);
                Req::list(ListKind::Author, viewer, &author, 5, 0)
            }
            ReadKind::List(ListKind::Favorited) => {
                let user = self.skewed_pick(|s| &s.favoriters, 2);
                Req::list(ListKind::Favorited, viewer, &user, 5, 0)
            }
            ReadKind::List(ListKind::Feed) => {
                let viewer = self.users[self.rng.below(self.users.len())];
                Req::list(ListKind::Feed, viewer, "", 10, self.page(10))
            }
            ReadKind::Article | ReadKind::Comments => {
                let slug = self.skewed_pick(|s| &s.slugs, 10);
                Req::keyed(kind, viewer, &slug)
            }
            ReadKind::Profile => {
                let author = self.skewed_pick(|s| &s.authors, 5);
                Req::keyed(ReadKind::Profile, viewer, &author)
            }
            ReadKind::CurrentUser => Req::keyed(
                ReadKind::CurrentUser,
                self.users[self.rng.below(self.users.len())],
                TOKEN,
            ),
            ReadKind::Tags | ReadKind::LoginLookup => Req::keyed(kind, 0, ""),
        }
    }

    /// One mixed batch, kinds in the proportions of the page-view table of WORKLOAD.md (per 100 API calls).
    fn mixed(&mut self, n: usize) -> Vec<Req> {
        const MIX: [(ReadKind, u32); 10] = [
            (ReadKind::Tags, 17),
            (ReadKind::List(ListKind::All), 10),
            (ReadKind::List(ListKind::Feed), 7),
            (ReadKind::List(ListKind::Tag), 4),
            (ReadKind::Article, 17),
            (ReadKind::Comments, 17),
            (ReadKind::Profile, 5),
            (ReadKind::List(ListKind::Author), 4),
            (ReadKind::List(ListKind::Favorited), 1),
            (ReadKind::CurrentUser, 4),
        ];
        let total: u32 = MIX.iter().map(|(_, w)| w).sum();
        (0..n)
            .map(|_| {
                let mut pick = self.rng.below(total as usize) as u32;
                let kind = MIX
                    .iter()
                    .find(|(_, w)| {
                        let hit = pick < *w;
                        pick = pick.saturating_sub(*w);
                        hit
                    })
                    .map_or(ReadKind::Tags, |(k, _)| *k);
                self.request(kind)
            })
            .collect()
    }
}

/// Microseconds of CPU per request: Postgres backend, and the lane thread (decode + render + protocol).
#[derive(Clone, Copy, Debug)]
struct Cost {
    backend_us: f64,
    lane_us: f64,
}

fn measure_batched(h: &mut Harness, pid: i32, sets: &[Vec<Req>]) -> Cost {
    for set in sets.iter().take(10) {
        h.run_batch(set);
    }
    let (b0, t0) = (backend_ns(pid), thread_ns());
    for set in sets {
        h.run_batch(set);
    }
    let (b1, t1) = (backend_ns(pid), thread_ns());
    let requests: usize = sets.iter().map(Vec::len).sum();
    Cost {
        backend_us: (b1 - b0) as f64 / 1e3 / requests as f64,
        lane_us: (t1 - t0) as f64 / 1e3 / requests as f64,
    }
}

fn measure_reference(h: &mut Harness, pid: i32, sets: &[Vec<Req>]) -> Cost {
    let run = |h: &mut Harness, set: &[Req]| {
        for req in set {
            h.reference_answer(req);
        }
    };
    for set in sets.iter().take(10) {
        run(h, set);
    }
    let (b0, t0) = (backend_ns(pid), thread_ns());
    for set in sets {
        run(h, set);
    }
    let (b1, t1) = (backend_ns(pid), thread_ns());
    let requests: usize = sets.iter().map(Vec::len).sum();
    Cost {
        backend_us: (b1 - b0) as f64 / 1e3 / requests as f64,
        lane_us: (t1 - t0) as f64 / 1e3 / requests as f64,
    }
}

fn pids(h: &mut Harness) -> (i32, i32) {
    let mut scratch = crate::pg::Results::new();
    (
        backend_pid(&mut h.db.conn, &mut scratch),
        backend_pid(&mut h.reference_conn, &mut scratch),
    )
}

const KINDS: [(&str, ReadKind); 10] = [
    ("list all", ReadKind::List(ListKind::All)),
    ("list tag", ReadKind::List(ListKind::Tag)),
    ("list author", ReadKind::List(ListKind::Author)),
    ("list favorited", ReadKind::List(ListKind::Favorited)),
    ("feed", ReadKind::List(ListKind::Feed)),
    ("article", ReadKind::Article),
    ("comments", ReadKind::Comments),
    ("profile", ReadKind::Profile),
    ("current user", ReadKind::CurrentUser),
    ("tags", ReadKind::Tags),
];

fn sets_for(source: &mut Source, kind: ReadKind, size: usize) -> Vec<Vec<Req>> {
    let reps = if size == 1 { REPS_SINGLE } else { REPS };
    (0..reps)
        .map(|_| (0..size).map(|_| source.request(kind)).collect())
        .collect()
}

#[test]
#[ignore]
fn backend_cpu_per_request_by_kind_and_batch_size() {
    let mut h = Harness::open(&bench_url());
    let (lane_pid, reference_pid) = pids(&mut h);
    let mut source = Source::sample(&mut h);
    println!(
        "backend CPU in microseconds per request (lane = CPU of the lane thread for decode + render + I/O)"
    );
    println!(
        "{:<15} {:>5} {:>12} {:>10} {:>14} {:>10}",
        "kind", "batch", "backend us", "lane us", "reference us", "ratio"
    );
    let only = std::env::var("READ_BENCH_KINDS").unwrap_or_default();
    for (name, kind) in KINDS
        .into_iter()
        .filter(|(name, _)| name.contains(only.as_str()))
    {
        for size in SIZES {
            let sets = sets_for(&mut source, kind, size);
            let batched = measure_batched(&mut h, lane_pid, &sets);
            let reference = measure_reference(&mut h, reference_pid, &sets);
            println!(
                "{name:<15} {size:>5} {:>12.1} {:>10.1} {:>14.1} {:>9.2}x",
                batched.backend_us,
                batched.lane_us,
                reference.backend_us,
                reference.backend_us / batched.backend_us
            );
        }
    }
}

#[test]
#[ignore]
fn backend_cpu_per_request_in_a_mixed_batch_of_64() {
    let mut h = Harness::open(&bench_url());
    let (lane_pid, reference_pid) = pids(&mut h);
    let mut source = Source::sample(&mut h);
    let sets: Vec<Vec<Req>> = (0..REPS).map(|_| source.mixed(MIXED_BATCH)).collect();
    let started = Instant::now();
    let batched = measure_batched(&mut h, lane_pid, &sets);
    let wall = started.elapsed();
    let reference = measure_reference(&mut h, reference_pid, &sets);
    println!(
        "mixed batch of {MIXED_BATCH} x {REPS}: backend {:.1} us/request, lane {:.1} us/request (wall {:.1} ms/batch); \
         reference one at a time: backend {:.1} us/request, client {:.1} us/request; ratio {:.2}x",
        batched.backend_us,
        batched.lane_us,
        wall.as_secs_f64() * 1e3 / (REPS + 10) as f64,
        reference.backend_us,
        reference.lane_us,
        reference.backend_us / batched.backend_us
    );
}

/// `enable_memoize` on against off, for every kind at batch 128 and 16 (best of three alternating runs): the
/// setting is kept only if it helps.
#[test]
#[ignore]
fn enable_memoize_experiment() {
    let url = bench_url();
    let off = SESSION_OPTIONS.to_owned();
    let on = off.replace("-c enable_memoize=off", "-c enable_memoize=on");
    assert_ne!(
        on, off,
        "SESSION_OPTIONS must carry enable_memoize=off for this experiment"
    );
    let mut with_off = Harness::open_with(&url, &off);
    let mut with_on = Harness::open_with(&url, &on);
    let (pid_off, _) = pids(&mut with_off);
    let (pid_on, _) = pids(&mut with_on);
    let mut source = Source::sample(&mut with_off);
    println!(
        "{:<15} {:>5} {:>14} {:>14}",
        "kind", "batch", "memoize off us", "memoize on us"
    );
    let only = std::env::var("READ_BENCH_KINDS").unwrap_or_default();
    for (name, kind) in KINDS
        .into_iter()
        .filter(|(name, _)| name.contains(only.as_str()))
    {
        for size in [16, 128] {
            let sets = sets_for(&mut source, kind, size);
            // Alternate and keep the best of three, so a cold cache or a noisy neighbour cannot favour one side.
            let (mut a, mut b) = (f64::MAX, f64::MAX);
            for _ in 0..3 {
                a = a.min(measure_batched(&mut with_off, pid_off, &sets).backend_us);
                b = b.min(measure_batched(&mut with_on, pid_on, &sets).backend_us);
            }
            println!("{name:<15} {size:>5} {a:>14.1} {b:>14.1}");
        }
    }
}
