//! Throughput and Postgres CPU of group commit for groups of 1, 16 and 128 writes (`#[ignore]`d).
//!
//! `cargo test --release --lib write::bench_tests -- --ignored --nocapture`. The numbers are the wall time of
//! `Lane::process` over pre-built jobs (request parsing and the io threads are not in it) and the CPU time that
//! Postgres processes burned meanwhile, read from `/proc`. "backend" is the connection serving the lane,
//! "all pg" is every child of the postmaster (WAL writer, checkpointer ... and any other client of the same server,
//! so it is noisy when other work runs on that Postgres).

use std::collections::HashSet;
use std::time::Instant;

use super::test_support::*;
use crate::app::jobs::WriteJob;

const GROUP_SIZES: [usize; 3] = [1, 16, 128];
const POSTMASTER_PID_FILE: &str =
    "/home/meros/git/personal/12dollar/multicore/pg/data/postmaster.pid";
/// Clock ticks per second of /proc/<pid>/stat (the Linux default).
const TICKS_PER_SEC: f64 = 100.0;
/// Writes per cell: the same for every group size, so a favorite or comment counts over equally many rows in each
/// cell. A multiple of every group size.
const WRITES: usize = 3072;

fn postmaster_pid() -> Option<u32> {
    let pid_file = std::env::var("PG_PIDFILE").unwrap_or_else(|_| POSTMASTER_PID_FILE.to_owned());
    std::fs::read_to_string(pid_file)
        .ok()?
        .lines()
        .next()?
        .trim()
        .parse()
        .ok()
}

/// (pid, utime + stime ticks, command line) of every child of the postmaster.
fn pg_children(master: u32) -> Vec<(u32, u64, String)> {
    let Ok(dir) = std::fs::read_dir("/proc") else {
        return Vec::new();
    };
    dir.flatten()
        .filter_map(|entry| {
            let pid: u32 = entry.file_name().to_str()?.parse().ok()?;
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            // Fields after the parenthesised command name: state, ppid, ..., utime (12th), stime (13th).
            let rest: Vec<&str> = stat[stat.rfind(')')? + 2..].split(' ').collect();
            if rest.get(1)?.parse::<u32>().ok()? != master {
                return None;
            }
            let ticks = rest.get(11)?.parse::<u64>().ok()? + rest.get(12)?.parse::<u64>().ok()?;
            let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
            Some((
                pid,
                ticks,
                String::from_utf8_lossy(&cmdline).replace('\0', " "),
            ))
        })
        .collect()
}

#[derive(Clone, Copy)]
enum Workload {
    CreateArticle,
    Favorite,
    Comment,
}

impl Workload {
    fn name(self) -> &'static str {
        match self {
            Workload::CreateArticle => "create article (2 tags)",
            Workload::Favorite => "favorite",
            Workload::Comment => "add comment",
        }
    }
}

/// `count` jobs of one workload. Favorites use distinct (user, article) pairs so none is a no-op.
fn jobs(
    workload: Workload,
    author: i64,
    slug: &str,
    first_viewer: i64,
    count: usize,
) -> Vec<WriteJob> {
    (0..count as i64)
        .map(|i| match workload {
            Workload::CreateArticle => create_article(
                author,
                &format!("Bench article {first_viewer} {i}"),
                &["bench", "write"],
            ),
            Workload::Favorite => favorite(first_viewer + i, slug, true),
            Workload::Comment => {
                add_comment(author, slug, "A benchmark comment of ordinary length.")
            }
        })
        .collect()
}

#[test]
#[ignore]
fn group_commit_throughput_and_postgres_cpu() {
    let master = postmaster_pid();
    let mut next_viewer = 1_000;
    println!(
        "\n{:<24} {:>5} {:>9} {:>12} {:>16} {:>16}",
        "workload", "group", "writes", "writes/s", "backend us/write", "all pg us/write"
    );
    for workload in [
        Workload::CreateArticle,
        Workload::Favorite,
        Workload::Comment,
    ] {
        for size in GROUP_SIZES {
            let before: HashSet<u32> = master
                .map(|m| pg_children(m).into_iter().map(|c| c.0).collect())
                .unwrap_or_default();
            let mut h = Harness::new();
            let (author, _) = new_user(&mut h, "bn");
            let slug = new_article(&mut h, author, &[]);
            let writes = WRITES;
            let batches: Vec<Vec<WriteJob>> = (0..writes / size)
                .map(|b| {
                    jobs(
                        workload,
                        author,
                        &slug,
                        next_viewer + (b * size) as i64,
                        size,
                    )
                })
                .collect();
            next_viewer += writes as i64;
            let ours = master.and_then(|m| {
                pg_children(m)
                    .into_iter()
                    .find(|c| !before.contains(&c.0) && c.2.contains("write_test"))
            });
            let cpu0 = master.map(pg_children).unwrap_or_default();
            let started = Instant::now();
            for batch in batches {
                let mut batch = batch;
                h.lane.process(&mut batch);
            }
            let elapsed = started.elapsed().as_secs_f64();
            let cpu1 = master.map(pg_children).unwrap_or_default();
            // Only processes that exist in both samples (an autovacuum worker may come and go in between).
            let total = |list: &[(u32, u64, String)], other: &[(u32, u64, String)]| {
                list.iter()
                    .filter(|c| other.iter().any(|o| o.0 == c.0))
                    .map(|c| c.1)
                    .sum::<u64>() as f64
                    / TICKS_PER_SEC
            };
            let backend = ours.map_or(f64::NAN, |o| {
                let after = cpu1.iter().find(|c| c.0 == o.0).map_or(0, |c| c.1);
                let start = cpu0.iter().find(|c| c.0 == o.0).map_or(0, |c| c.1);
                (after - start) as f64 / TICKS_PER_SEC
            });
            let all = total(&cpu1, &cpu0) - total(&cpu0, &cpu1);
            let done = (writes / size * size) as f64;
            println!(
                "{:<24} {:>5} {:>9} {:>12.0} {:>16.1} {:>16.1}",
                workload.name(),
                size,
                done as u64,
                done / elapsed,
                backend / done * 1e6,
                all / done * 1e6
            );
        }
    }
}
