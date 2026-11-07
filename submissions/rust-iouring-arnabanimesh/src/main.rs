//! conduit — RealWorld "Conduit" API for the multicore-server-challenge.
//!
//! Thread-per-core io_uring HTTP server, pipelined binary-protocol Postgres connections owned by
//! each worker, and a small bcrypt thread pool. See README.md for the design.

mod auth;
mod bcrypt_pool;
mod http;
mod json;
mod pg;
mod render;
mod sql;
mod uring;
mod worker;

use std::env;
use std::io;
use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use crossbeam_channel::{unbounded, Receiver, Sender};

use crate::auth::Jwt;
use crate::bcrypt_pool::{BJob, BOut};
use crate::pg::{PgConfig, PgConn};
use crate::uring::Ring;
use crate::worker::{Worker, BGID, BUF_COUNT, BUF_SIZE};

struct Config {
    bind: SocketAddr,
    pg: PgConfig,
    jwt_secret: Vec<u8>,
    pg_conns: usize,
}

/// SIGTERM / SIGINT: close the Postgres sockets immediately (so their backends exit and free their
/// connection slots) and leave. Only async-signal-safe calls are made here.
extern "C" fn on_term(_sig: libc::c_int) {
    pg::shutdown_all();
    unsafe {
        libc::_exit(0);
    }
}

/// With SO_REUSEPORT an old instance that is still running does NOT make our bind fail: both would
/// listen on the port, share the traffic, and hold twice the Postgres connections. A plain bind (no
/// SO_REUSEPORT) fails while anything listens there, so use one as a probe and wait for the port.
fn wait_for_free_port(addr: SocketAddr) {
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut warned = false;
    loop {
        match std::net::TcpListener::bind(addr) {
            Ok(l) => {
                drop(l);
                return;
            }
            Err(e) => {
                if e.kind() != io::ErrorKind::AddrInUse {
                    fatal(&format!("cannot bind {}: {}", addr, e));
                }
                if Instant::now() >= deadline {
                    fatal(&format!(
                        "{} is still in use ({}). Is an old conduit running? Check: pgrep -af conduit",
                        addr, e
                    ));
                }
                if !warned {
                    eprintln!("{} is in use ({}); waiting up to 20 s for it to be released", addr, e);
                    warned = true;
                }
                thread::sleep(Duration::from_millis(250));
            }
        }
    }
}

fn fatal(msg: &str) -> ! {
    eprintln!("{}", msg);
    std::process::exit(1);
}

fn env_usize(name: &str, default: usize) -> usize {
    match env::var(name) {
        Ok(v) => v.parse::<usize>().unwrap_or(default),
        Err(_) => default,
    }
}

fn main() {
    // A closed client socket must never kill the process.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
        libc::signal(libc::SIGTERM, on_term as *const () as usize);
        libc::signal(libc::SIGINT, on_term as *const () as usize);
    }

    let host = env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
    let port: u16 = match env::var("PORT") {
        Ok(p) => p.parse::<u16>().unwrap_or(80),
        Err(_) => 80,
    };
    let bind: SocketAddr = match (host.as_str(), port).to_socket_addrs() {
        Ok(mut it) => match it.find(|a| a.is_ipv4()) {
            Some(a) => a,
            None => fatal(&format!("HOST {} has no IPv4 address", host)),
        },
        Err(e) => fatal(&format!("cannot resolve HOST {}: {}", host, e)),
    };

    wait_for_free_port(bind);

    let jwt_secret = env::var("JWT_SECRET")
        .unwrap_or_else(|_| "multicore-server-challenge".to_string())
        .into_bytes();
    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://conduit:conduit@127.0.0.1:5432/conduit".to_string());

    // `force_generic_plan` skips planning on every execution. Flip to `auto` without recompiling
    // (PLAN_CACHE_MODE=auto) if you ever see a bad generic plan.
    let mut plan_mode = env::var("PLAN_CACHE_MODE").unwrap_or_else(|_| "force_generic_plan".to_string());
    if plan_mode.is_empty() || !plan_mode.chars().all(|c| c.is_ascii_lowercase() || c == '_') {
        plan_mode = "force_generic_plan".to_string();
    }
    let pgcfg = pg::parse_url(&db_url, &plan_mode);

    let cpus = thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    let workers = env_usize("WORKERS", cpus).max(1);
    let mut pg_conns = env_usize("PG_CONNS_PER_WORKER", 2).max(1);
    // The rules allow at most 95 connections in total across all processes.
    if workers * pg_conns > 90 {
        pg_conns = (90 / workers).max(1);
    }
    let bcrypt_threads = env_usize("BCRYPT_THREADS", (cpus / 2).max(2)).max(1);

    // Per-worker result channel + eventfd for bcrypt completions.
    let mut outs: Vec<(Sender<BOut>, i32)> = Vec::with_capacity(workers);
    let mut sides: Vec<(Receiver<BOut>, i32)> = Vec::with_capacity(workers);
    for _ in 0..workers {
        let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        if efd < 0 {
            fatal("eventfd() failed");
        }
        let (tx, rx) = unbounded::<BOut>();
        outs.push((tx, efd));
        sides.push((rx, efd));
    }
    let jobs = bcrypt_pool::start(bcrypt_threads, outs);

    eprintln!(
        "conduit: {} io workers x {} postgres connections, {} bcrypt threads, listening on {}",
        workers, pg_conns, bcrypt_threads, bind
    );

    let cfg = Arc::new(Config {
        bind,
        pg: pgcfg,
        jwt_secret,
        pg_conns,
    });

    let mut handles = Vec::with_capacity(workers);
    for (id, (rx, efd)) in sides.into_iter().enumerate() {
        let cfg = Arc::clone(&cfg);
        let jobs = jobs.clone();
        let handle = thread::Builder::new()
            .name(format!("uring-{}", id))
            .spawn(move || {
                if let Err(e) = worker_main(id, cfg, jobs, rx, efd) {
                    eprintln!("worker {} failed: {}", id, e);
                    std::process::exit(1);
                }
            })
            .expect("spawn worker thread");
        handles.push(handle);
    }
    for h in handles {
        let _ = h.join();
    }
}

fn worker_main(
    id: usize,
    cfg: Arc<Config>,
    jobs: Sender<BJob>,
    results: Receiver<BOut>,
    efd: i32,
) -> io::Result<()> {
    let mut ring = Ring::new(4096, 32768)?;
    ring.setup_buf_ring(BGID, BUF_COUNT, BUF_SIZE)?;

    // Connect (and prepare) before binding the listener: we never accept what we cannot serve.
    let stmts = sql::build();
    // The first connection is mandatory (retried for ~55 s); the others are best effort, so that a
    // nearly full Postgres (e.g. a previous run still shutting down) degrades instead of failing.
    let mut pgs: Vec<PgConn> = Vec::with_capacity(cfg.pg_conns);
    pgs.push(connect_with_retry(id, &cfg.pg, &stmts)?);
    for _ in 1..cfg.pg_conns {
        match pg::connect(&cfg.pg, &stmts) {
            Ok(c) => pgs.push(c),
            Err(e) => {
                eprintln!(
                    "worker {}: running with {} of {} postgres connections: {}",
                    id,
                    pgs.len(),
                    cfg.pg_conns,
                    e
                );
                break;
            }
        }
    }

    let listen_fd = worker::create_listener(cfg.bind)?;
    let jwt = Jwt::new(&cfg.jwt_secret);
    let mut w = Worker::new(id, ring, listen_fd, pgs, jwt, jobs, results, efd);
    w.run()
}

/// Postgres may still be starting when we are launched: retry for up to ~55 s (the harness
/// allows 60 s until the first answer). SQL errors are not retried — they never fix themselves.
fn connect_with_retry(
    wid: usize,
    cfg: &PgConfig,
    stmts: &[(String, Vec<u32>)],
) -> io::Result<PgConn> {
    let deadline = Instant::now() + Duration::from_secs(55);
    let mut attempt = 0u32;
    loop {
        match pg::connect(cfg, stmts) {
            Ok(c) => return Ok(c),
            Err(e) => {
                let msg = e.to_string();
                if msg.starts_with("PREPARE FAILED") || Instant::now() >= deadline {
                    return Err(e);
                }
                if attempt % 10 == 0 {
                    eprintln!("worker {}: waiting for postgres: {}", wid, msg);
                    if msg.contains("53300") {
                        eprintln!(
                            "  hint: postgres is out of connection slots - another instance (or an earlier run) is still connected. \
                             Look at: SELECT application_name, state, count(*) FROM pg_stat_activity GROUP BY 1, 2;  and  pgrep -af conduit"
                        );
                    }
                }
                attempt += 1;
                thread::sleep(Duration::from_millis(300));
            }
        }
    }
}
