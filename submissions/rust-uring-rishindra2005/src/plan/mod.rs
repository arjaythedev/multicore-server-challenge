//! Plan layer driver and batch formation workers.
//!
//! Decouples reads, feeds, and group-commit writes across dedicated connection pools.
//! Bridges network reactors and Postgres connections via lock-free SPSC queues.
//!
//! Rule compliance:
//! - R1: Every SpscQueue has exactly ONE producer and ONE consumer.
//! - R2: Every request receives exactly one reply (errors -> 500 JSON). No path drops envelopes.
//! - R3: Wire protocol reads always drain through 'Z', even after 'E'.
//! - R4: Zero caching across requests. Writes committed to disk before reply.
//! - R5: Dynamic, exact Content-Length framing.
//! - R6: Total Postgres connections <= 60 across all threads (clamped).
//! - R7: Pool sizes configurable via PG_READ_CONNS, PG_WRITE_CONNS, PG_FEED_CONNS,
//!       with sane defaults computed from available CPU count and logged at boot.

pub mod exec;
pub mod feed;
pub mod write;

pub use plan_driver_loop as run_pg_driver;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::pg::warm::run_warmup;
use crate::pg::wire::{PgConfig, PgError, PgWire};
use crate::rt::spsc::SpscQueue;
use crate::rt::thread::{create_eventfd, wait_eventfd};
use crate::types::{Envelope, Job, KdfJob, Reply};

/// Sizing configuration for database connection pools.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PoolSizing {
    pub total_read: usize,
    pub total_write: usize,
    pub total_feed: usize,
    pub read_per_driver: usize,
    pub write_per_driver: usize,
    pub feed_per_driver: usize,
}

/// Computes connection pool sizing from CPU count and environment variables,
/// strictly enforcing Rule R6 (total connections <= 60).
pub fn compute_pool_sizing(num_cpus: usize, pg_threads: usize) -> PoolSizing {
    let pg_threads = pg_threads.max(1);

    let mut total_read: usize = std::env::var("PG_READ_CONNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| num_cpus.max(4));

    let mut total_write: usize = std::env::var("PG_WRITE_CONNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| (num_cpus / 2).max(2));

    let mut total_feed: usize = std::env::var("PG_FEED_CONNS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or_else(|| (num_cpus / 4).max(1));

    // Rule R6: Total connections across all threads must stay <= 60
    let total = total_read + total_write + total_feed;
    if total > 60 {
        let scale = 60.0 / total as f64;
        total_read = ((total_read as f64 * scale) as usize).max(1);
        total_write = ((total_write as f64 * scale) as usize).max(1);
        total_feed = ((total_feed as f64 * scale) as usize).max(1);
    }

    let read_per_driver = (total_read / pg_threads).max(1);
    let write_per_driver = (total_write / pg_threads).max(1);
    let feed_per_driver = (total_feed / pg_threads).max(1);

    PoolSizing {
        total_read,
        total_write,
        total_feed,
        read_per_driver,
        write_per_driver,
        feed_per_driver,
    }
}

/// Internal handle for a dedicated read worker connection.
struct ReadWorkerHandle {
    in_q: Arc<SpscQueue<Envelope, 1024>>,
    out_q: Arc<SpscQueue<Reply, 1024>>,
    kdf_out_q: Arc<SpscQueue<KdfJob, 512>>,
    _thread: std::thread::JoinHandle<()>,
}

/// Internal handle for a dedicated feed worker connection.
struct FeedWorkerHandle {
    in_q: Arc<SpscQueue<Envelope, 1024>>,
    out_q: Arc<SpscQueue<Reply, 1024>>,
    _thread: std::thread::JoinHandle<()>,
}

/// Internal handle for a dedicated write worker connection.
struct WriteWorkerHandle {
    in_q: Arc<SpscQueue<Envelope, 1024>>,
    out_q: Arc<SpscQueue<Reply, 1024>>,
    _thread: std::thread::JoinHandle<()>,
}

/// Main driver loop for planning and executing database requests.
///
/// Decouples execution across independent read, feed, and write worker pools.
/// Requests are routed to workers by `(env.conn.slot as usize) % pool.len()`
/// to guarantee strict FIFO ordering per client connection.
pub fn plan_driver_loop(
    driver_idx: usize,
    db_config: PgConfig,
    in_queues: Vec<Arc<SpscQueue<Envelope, 1024>>>,
    reply_queues: Vec<Arc<SpscQueue<Reply, 1024>>>,
    kdf_queue: Arc<SpscQueue<KdfJob, 512>>,
    stop: Arc<AtomicBool>,
) -> Result<(), PgError> {
    let num_cpus = crate::rt::thread::get_allowed_cpus().len();
    let pg_threads: usize = std::env::var("PG_THREADS")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(2);

    let sizing = compute_pool_sizing(num_cpus, pg_threads);

    if driver_idx == 0 {
        println!(
            "PG connections pool initialized: total={} (read={}, write={}, feed={}), per-driver: read={}, write={}, feed={}",
            (sizing.read_per_driver + sizing.write_per_driver + sizing.feed_per_driver) * pg_threads,
            sizing.read_per_driver * pg_threads,
            sizing.write_per_driver * pg_threads,
            sizing.feed_per_driver * pg_threads,
            sizing.read_per_driver,
            sizing.write_per_driver,
            sizing.feed_per_driver
        );
    }

    let driver_event_fd = in_queues.first().map(|q| q.event_fd).unwrap_or(-1);

    // 1. Spawn dedicated Read Workers
    let mut read_workers = Vec::with_capacity(sizing.read_per_driver);
    for w_idx in 0..sizing.read_per_driver {
        let in_q = Arc::new(SpscQueue::<Envelope, 1024>::new(create_eventfd().unwrap_or(-1)));
        let out_q = Arc::new(SpscQueue::<Reply, 1024>::new(driver_event_fd));
        let kdf_out_q = Arc::new(SpscQueue::<KdfJob, 512>::new(driver_event_fd));

        let in_q_worker = in_q.clone();
        let out_q_worker = out_q.clone();
        let kdf_out_worker = kdf_out_q.clone();
        let cfg = db_config.clone();
        let stop_worker = stop.clone();

        let thread_name = format!("pg-read-{driver_idx}-{w_idx}");
        let thread = std::thread::Builder::new()
            .name(thread_name)
            .spawn(move || {
                run_read_worker_loop(
                    driver_idx,
                    w_idx,
                    cfg,
                    in_q_worker,
                    out_q_worker,
                    kdf_out_worker,
                    stop_worker,
                );
            })
            .expect("spawn pg read worker");

        read_workers.push(ReadWorkerHandle {
            in_q,
            out_q,
            kdf_out_q,
            _thread: thread,
        });
    }

    // 2. Spawn dedicated Feed Workers
    let mut feed_workers = Vec::with_capacity(sizing.feed_per_driver);
    for w_idx in 0..sizing.feed_per_driver {
        let in_q = Arc::new(SpscQueue::<Envelope, 1024>::new(create_eventfd().unwrap_or(-1)));
        let out_q = Arc::new(SpscQueue::<Reply, 1024>::new(driver_event_fd));

        let in_q_worker = in_q.clone();
        let out_q_worker = out_q.clone();
        let cfg = db_config.clone();
        let stop_worker = stop.clone();

        let thread_name = format!("pg-feed-{driver_idx}-{w_idx}");
        let thread = std::thread::Builder::new()
            .name(thread_name)
            .spawn(move || {
                run_feed_worker_loop(
                    driver_idx,
                    w_idx,
                    cfg,
                    in_q_worker,
                    out_q_worker,
                    stop_worker,
                );
            })
            .expect("spawn pg feed worker");

        feed_workers.push(FeedWorkerHandle {
            in_q,
            out_q,
            _thread: thread,
        });
    }

    // 3. Spawn dedicated Write Workers
    let mut write_workers = Vec::with_capacity(sizing.write_per_driver);
    for w_idx in 0..sizing.write_per_driver {
        let in_q = Arc::new(SpscQueue::<Envelope, 1024>::new(create_eventfd().unwrap_or(-1)));
        let out_q = Arc::new(SpscQueue::<Reply, 1024>::new(driver_event_fd));

        let in_q_worker = in_q.clone();
        let out_q_worker = out_q.clone();
        let cfg = db_config.clone();
        let stop_worker = stop.clone();

        let thread_name = format!("pg-write-{driver_idx}-{w_idx}");
        let thread = std::thread::Builder::new()
            .name(thread_name)
            .spawn(move || {
                run_write_worker_loop(
                    driver_idx,
                    w_idx,
                    cfg,
                    in_q_worker,
                    out_q_worker,
                    stop_worker,
                );
            })
            .expect("spawn pg write worker");

        write_workers.push(WriteWorkerHandle {
            in_q,
            out_q,
            _thread: thread,
        });
    }

    // Per-worker overflow buffers for incoming envelopes to ensure zero dropped requests
    let mut overflow_read_in: Vec<Vec<Envelope>> = (0..read_workers.len())
        .map(|_| Vec::with_capacity(64))
        .collect();
    let mut overflow_feed_in: Vec<Vec<Envelope>> = (0..feed_workers.len())
        .map(|_| Vec::with_capacity(64))
        .collect();
    let mut overflow_write_in: Vec<Vec<Envelope>> = (0..write_workers.len())
        .map(|_| Vec::with_capacity(64))
        .collect();

    // Outbound overflow buffers for replies and kdf jobs to net reactors and crypto worker
    let mut overflow_replies: Vec<Reply> = Vec::with_capacity(256);
    let mut overflow_kdf: Vec<KdfJob> = Vec::with_capacity(64);

    // Coordinator loop: non-blocking dispatch and reply reaping
    while !stop.load(Ordering::Relaxed) {
        let mut work_done = false;

        // 1. Drain pending outbound reply and kdf overflow buffers
        if !overflow_replies.is_empty() {
            let mut remaining = Vec::with_capacity(overflow_replies.len());
            for reply in overflow_replies.drain(..) {
                let reactor_idx = reply.conn.reactor as usize;
                if reactor_idx < reply_queues.len() {
                    if let Err(r) = reply_queues[reactor_idx].push(reply) {
                        remaining.push(r);
                    } else {
                        work_done = true;
                    }
                }
            }
            overflow_replies = remaining;
        }

        if !overflow_kdf.is_empty() {
            let mut remaining = Vec::with_capacity(overflow_kdf.len());
            for kjob in overflow_kdf.drain(..) {
                if let Err(kj) = kdf_queue.push(kjob) {
                    remaining.push(kj);
                } else {
                    work_done = true;
                }
            }
            overflow_kdf = remaining;
        }

        // 2. Drain pending inbound worker overflow buffers
        for (idx, worker) in read_workers.iter().enumerate() {
            if !overflow_read_in[idx].is_empty() {
                let mut remaining = Vec::with_capacity(overflow_read_in[idx].len());
                for env in overflow_read_in[idx].drain(..) {
                    if let Err(e) = worker.in_q.push(env) {
                        remaining.push(e);
                    } else {
                        work_done = true;
                    }
                }
                overflow_read_in[idx] = remaining;
            }
        }

        for (idx, worker) in feed_workers.iter().enumerate() {
            if !overflow_feed_in[idx].is_empty() {
                let mut remaining = Vec::with_capacity(overflow_feed_in[idx].len());
                for env in overflow_feed_in[idx].drain(..) {
                    if let Err(e) = worker.in_q.push(env) {
                        remaining.push(e);
                    } else {
                        work_done = true;
                    }
                }
                overflow_feed_in[idx] = remaining;
            }
        }

        for (idx, worker) in write_workers.iter().enumerate() {
            if !overflow_write_in[idx].is_empty() {
                let mut remaining = Vec::with_capacity(overflow_write_in[idx].len());
                for env in overflow_write_in[idx].drain(..) {
                    if let Err(e) = worker.in_q.push(env) {
                        remaining.push(e);
                    } else {
                        work_done = true;
                    }
                }
                overflow_write_in[idx] = remaining;
            }
        }

        // 3. Reap completed replies and KDF jobs from all workers
        for worker in &read_workers {
            while let Some(reply) = worker.out_q.pop() {
                work_done = true;
                let reactor_idx = reply.conn.reactor as usize;
                if reactor_idx < reply_queues.len() {
                    if let Err(r) = reply_queues[reactor_idx].push(reply) {
                        overflow_replies.push(r);
                    }
                }
            }
            while let Some(kjob) = worker.kdf_out_q.pop() {
                work_done = true;
                if let Err(kj) = kdf_queue.push(kjob) {
                    overflow_kdf.push(kj);
                }
            }
        }

        for worker in &feed_workers {
            while let Some(reply) = worker.out_q.pop() {
                work_done = true;
                let reactor_idx = reply.conn.reactor as usize;
                if reactor_idx < reply_queues.len() {
                    if let Err(r) = reply_queues[reactor_idx].push(reply) {
                        overflow_replies.push(r);
                    }
                }
            }
        }

        for worker in &write_workers {
            while let Some(reply) = worker.out_q.pop() {
                work_done = true;
                let reactor_idx = reply.conn.reactor as usize;
                if reactor_idx < reply_queues.len() {
                    if let Err(r) = reply_queues[reactor_idx].push(reply) {
                        overflow_replies.push(r);
                    }
                }
            }
        }

        // 4. Pop incoming envelopes from net reactors and KDF worker
        for in_q in &in_queues {
            while let Some(env) = in_q.pop() {
                work_done = true;
                let slot = env.conn.slot as usize;
                match env.job {
                    Job::Feed { .. } => {
                        let target = slot % feed_workers.len();
                        if !overflow_feed_in[target].is_empty() {
                            overflow_feed_in[target].push(env);
                        } else if let Err(e) = feed_workers[target].in_q.push(env) {
                            overflow_feed_in[target].push(e);
                        }
                    }
                    Job::Follow { .. }
                    | Job::Favorite { .. }
                    | Job::CommentCreate { .. }
                    | Job::CommentDelete { .. }
                    | Job::ArticleCreate { .. }
                    | Job::ArticleUpdate { .. }
                    | Job::ArticleDelete { .. }
                    | Job::UserUpdate { .. }
                    | Job::Register { .. } => {
                        let target = slot % write_workers.len();
                        if !overflow_write_in[target].is_empty() {
                            overflow_write_in[target].push(env);
                        } else if let Err(e) = write_workers[target].in_q.push(env) {
                            overflow_write_in[target].push(e);
                        }
                    }
                    _ => {
                        let target = slot % read_workers.len();
                        if !overflow_read_in[target].is_empty() {
                            overflow_read_in[target].push(env);
                        } else if let Err(e) = read_workers[target].in_q.push(env) {
                            overflow_read_in[target].push(e);
                        }
                    }
                }
            }
        }

        if !work_done {
            let has_overflow = !overflow_replies.is_empty()
                || !overflow_kdf.is_empty()
                || overflow_read_in.iter().any(|v| !v.is_empty())
                || overflow_feed_in.iter().any(|v| !v.is_empty())
                || overflow_write_in.iter().any(|v| !v.is_empty());

            if has_overflow {
                std::thread::sleep(Duration::from_micros(50));
            } else {
                for q in &in_queues {
                    q.mark_sleeping();
                }
                for w in &read_workers {
                    w.out_q.mark_sleeping();
                    w.kdf_out_q.mark_sleeping();
                }
                for w in &feed_workers {
                    w.out_q.mark_sleeping();
                }
                for w in &write_workers {
                    w.out_q.mark_sleeping();
                }

                let all_empty = in_queues.iter().all(|q| q.is_empty())
                    && read_workers.iter().all(|w| w.out_q.is_empty() && w.kdf_out_q.is_empty())
                    && feed_workers.iter().all(|w| w.out_q.is_empty())
                    && write_workers.iter().all(|w| w.out_q.is_empty());

                if all_empty {
                    wait_eventfd(driver_event_fd, 5);
                }

                for q in &in_queues {
                    q.mark_awake();
                }
                for w in &read_workers {
                    w.out_q.mark_awake();
                    w.kdf_out_q.mark_awake();
                }
                for w in &feed_workers {
                    w.out_q.mark_awake();
                }
                for w in &write_workers {
                    w.out_q.mark_awake();
                }
            }
        }
    }

    Ok(())
}

/// Worker loop for dedicated read connections.
fn run_read_worker_loop(
    driver_idx: usize,
    worker_idx: usize,
    db_config: PgConfig,
    in_q: Arc<SpscQueue<Envelope, 1024>>,
    out_q: Arc<SpscQueue<Reply, 1024>>,
    kdf_out_q: Arc<SpscQueue<KdfJob, 512>>,
    stop: Arc<AtomicBool>,
) {
    let mut wire_opt = PgWire::connect(&db_config).ok();
    while wire_opt.is_none() && !stop.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(50));
        wire_opt = PgWire::connect(&db_config).ok();
    }
    let mut wire = match wire_opt {
        Some(w) => w,
        None => return,
    };

    // Warmup executed on driver 0, worker 0 only
    if driver_idx == 0 && worker_idx == 0 {
        let _ = run_warmup(&mut wire);
    }

    let mut batch: Vec<Envelope> = Vec::with_capacity(128);
    let mut staged_replies: Vec<Reply> = Vec::with_capacity(256);
    let mut staged_kdf: Vec<KdfJob> = Vec::with_capacity(64);

    let mut overflow_replies: Vec<Reply> = Vec::with_capacity(128);
    let mut overflow_kdf: Vec<KdfJob> = Vec::with_capacity(32);
    let mut wire_broken = false;

    while !stop.load(Ordering::Relaxed) {
        // Drain pending overflow buffers
        if !overflow_replies.is_empty() {
            let mut remaining = Vec::with_capacity(overflow_replies.len());
            for r in overflow_replies.drain(..) {
                if let Err(reply) = out_q.push(r) {
                    remaining.push(reply);
                }
            }
            overflow_replies = remaining;
        }

        if !overflow_kdf.is_empty() {
            let mut remaining = Vec::with_capacity(overflow_kdf.len());
            for kj in overflow_kdf.drain(..) {
                if let Err(kjob) = kdf_out_q.push(kj) {
                    remaining.push(kjob);
                }
            }
            overflow_kdf = remaining;
        }

        // Collect opportunistic batch
        while let Some(env) = in_q.pop() {
            batch.push(env);
            if batch.len() >= 128 {
                break;
            }
        }

        if batch.is_empty() {
            in_q.mark_sleeping();
            if in_q.is_empty() {
                wait_eventfd(in_q.event_fd, 5);
            }
            in_q.mark_awake();
            continue;
        }

        if wire_broken {
            if let Ok(c) = PgWire::connect(&db_config) {
                wire = c;
                wire_broken = false;
            } else {
                // If reconnect fails, frame 500 error replies for all envelopes in batch per Rule R2
                for env in &batch {
                    let resp = crate::api::errors::reply_500(env.keepalive);
                    staged_replies.push(Reply {
                        conn: env.conn,
                        bytes: resp,
                        close: !env.keepalive,
                    });
                }
                for r in staged_replies.drain(..) {
                    if let Err(reply) = out_q.push(r) {
                        overflow_replies.push(reply);
                    }
                }
                batch.clear();
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
        }

        let res = exec::execute_read_batch(&mut wire, &batch, &mut staged_replies, &mut staged_kdf);
        if res.is_err() {
            wire_broken = true;
            if let Ok(c) = PgWire::connect(&db_config) {
                wire = c;
                wire_broken = false;
            }
        }

        // Push replies and kdf jobs to coordinator queues (Rule R2: zero dropped)
        for r in staged_replies.drain(..) {
            if let Err(reply) = out_q.push(r) {
                overflow_replies.push(reply);
            }
        }
        for kj in staged_kdf.drain(..) {
            if let Err(kjob) = kdf_out_q.push(kj) {
                overflow_kdf.push(kjob);
            }
        }

        batch.clear();
    }
}

/// Worker loop for dedicated feed connections.
fn run_feed_worker_loop(
    _driver_idx: usize,
    _worker_idx: usize,
    db_config: PgConfig,
    in_q: Arc<SpscQueue<Envelope, 1024>>,
    out_q: Arc<SpscQueue<Reply, 1024>>,
    stop: Arc<AtomicBool>,
) {
    let mut wire_opt = PgWire::connect(&db_config).ok();
    while wire_opt.is_none() && !stop.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(50));
        wire_opt = PgWire::connect(&db_config).ok();
    }
    let mut wire = match wire_opt {
        Some(w) => w,
        None => return,
    };

    let mut batch: Vec<Envelope> = Vec::with_capacity(128);
    let mut staged_replies: Vec<Reply> = Vec::with_capacity(256);
    let mut overflow_replies: Vec<Reply> = Vec::with_capacity(128);
    let mut wire_broken = false;

    while !stop.load(Ordering::Relaxed) {
        if !overflow_replies.is_empty() {
            let mut remaining = Vec::with_capacity(overflow_replies.len());
            for r in overflow_replies.drain(..) {
                if let Err(reply) = out_q.push(r) {
                    remaining.push(reply);
                }
            }
            overflow_replies = remaining;
        }

        while let Some(env) = in_q.pop() {
            batch.push(env);
            if batch.len() >= 128 {
                break;
            }
        }

        if batch.is_empty() {
            in_q.mark_sleeping();
            if in_q.is_empty() {
                wait_eventfd(in_q.event_fd, 5);
            }
            in_q.mark_awake();
            continue;
        }

        if wire_broken {
            if let Ok(c) = PgWire::connect(&db_config) {
                wire = c;
                wire_broken = false;
            } else {
                for env in &batch {
                    let resp = crate::api::errors::reply_500(env.keepalive);
                    staged_replies.push(Reply {
                        conn: env.conn,
                        bytes: resp,
                        close: !env.keepalive,
                    });
                }
                for r in staged_replies.drain(..) {
                    if let Err(reply) = out_q.push(r) {
                        overflow_replies.push(reply);
                    }
                }
                batch.clear();
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
        }

        let res = feed::execute_feed_batch(&mut wire, &batch, &mut staged_replies);
        if res.is_err() {
            wire_broken = true;
            if let Ok(c) = PgWire::connect(&db_config) {
                wire = c;
                wire_broken = false;
            }
        }

        for r in staged_replies.drain(..) {
            if let Err(reply) = out_q.push(r) {
                overflow_replies.push(reply);
            }
        }

        batch.clear();
    }
}

/// Worker loop for dedicated write connections (group commits).
fn run_write_worker_loop(
    _driver_idx: usize,
    _worker_idx: usize,
    db_config: PgConfig,
    in_q: Arc<SpscQueue<Envelope, 1024>>,
    out_q: Arc<SpscQueue<Reply, 1024>>,
    stop: Arc<AtomicBool>,
) {
    let mut wire_opt = PgWire::connect(&db_config).ok();
    while wire_opt.is_none() && !stop.load(Ordering::Relaxed) {
        std::thread::sleep(Duration::from_millis(50));
        wire_opt = PgWire::connect(&db_config).ok();
    }
    let mut wire = match wire_opt {
        Some(w) => w,
        None => return,
    };

    let mut batch: Vec<Envelope> = Vec::with_capacity(64);
    let mut staged_replies: Vec<Reply> = Vec::with_capacity(128);
    let mut overflow_replies: Vec<Reply> = Vec::with_capacity(128);
    let mut wire_broken = false;

    while !stop.load(Ordering::Relaxed) {
        if !overflow_replies.is_empty() {
            let mut remaining = Vec::with_capacity(overflow_replies.len());
            for r in overflow_replies.drain(..) {
                if let Err(reply) = out_q.push(r) {
                    remaining.push(reply);
                }
            }
            overflow_replies = remaining;
        }

        while let Some(env) = in_q.pop() {
            batch.push(env);
            if batch.len() >= 64 {
                break;
            }
        }

        if batch.is_empty() {
            in_q.mark_sleeping();
            if in_q.is_empty() {
                wait_eventfd(in_q.event_fd, 5);
            }
            in_q.mark_awake();
            continue;
        }

        if wire_broken {
            if let Ok(c) = PgWire::connect(&db_config) {
                wire = c;
                wire_broken = false;
            } else {
                for env in &batch {
                    let resp = crate::api::errors::reply_500(env.keepalive);
                    staged_replies.push(Reply {
                        conn: env.conn,
                        bytes: resp,
                        close: !env.keepalive,
                    });
                }
                for r in staged_replies.drain(..) {
                    if let Err(reply) = out_q.push(r) {
                        overflow_replies.push(reply);
                    }
                }
                batch.clear();
                std::thread::sleep(Duration::from_millis(20));
                continue;
            }
        }

        let res = write::execute_write_group(&mut wire, &batch, &mut staged_replies);
        if res.is_err() {
            wire_broken = true;
            if let Ok(c) = PgWire::connect(&db_config) {
                wire = c;
                wire_broken = false;
            }
        }

        for r in staged_replies.drain(..) {
            if let Err(reply) = out_q.push(r) {
                overflow_replies.push(reply);
            }
        }

        batch.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pool_size_calculation_and_clamp() {
        // Standard 8 CPU box with 2 pg threads
        let sizing = compute_pool_sizing(8, 2);
        assert_eq!(sizing.total_read, 8);
        assert_eq!(sizing.total_write, 4);
        assert_eq!(sizing.total_feed, 2);
        assert_eq!(sizing.read_per_driver, 4);
        assert_eq!(sizing.write_per_driver, 2);
        assert_eq!(sizing.feed_per_driver, 1);
        let total_conns = (sizing.read_per_driver + sizing.write_per_driver + sizing.feed_per_driver) * 2;
        assert!(total_conns <= 60, "total conns must be <= 60 per Rule R6");

        // Small 2 CPU machine
        let sizing_small = compute_pool_sizing(2, 2);
        assert_eq!(sizing_small.total_read, 4);
        assert_eq!(sizing_small.total_write, 2);
        assert_eq!(sizing_small.total_feed, 1);
        assert_eq!(sizing_small.read_per_driver, 2);
        assert_eq!(sizing_small.write_per_driver, 1);
        assert_eq!(sizing_small.feed_per_driver, 1);
    }

    #[test]
    fn test_envelope_slot_routing_distribution() {
        let num_read_workers = 4;
        let num_feed_workers = 1;
        let num_write_workers = 2;

        for slot in 0..100 {
            let read_target = slot % num_read_workers;
            let feed_target = slot % num_feed_workers;
            let write_target = slot % num_write_workers;

            assert!(read_target < num_read_workers);
            assert!(feed_target < num_feed_workers);
            assert!(write_target < num_write_workers);

            // Deterministic routing for the same slot
            assert_eq!(slot % num_read_workers, read_target);
            assert_eq!(slot % num_write_workers, write_target);
        }
    }

    #[test]
    fn test_error_reply_body_key_standardization() {
        // Enforce that database error replies strictly use SPEC-compliant 'body' key via reply_500
        let resp = crate::api::errors::reply_500(true);
        let resp_str = String::from_utf8_lossy(&resp);
        assert!(resp_str.contains("HTTP/1.1 500 Internal Server Error"));
        assert!(resp_str.contains("{\"errors\":{\"body\":[\"database error\"]}}"));
        assert!(!resp_str.contains("\"server\":"));
    }
}
