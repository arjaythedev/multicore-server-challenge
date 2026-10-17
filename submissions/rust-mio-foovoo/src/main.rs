//! Conduit (RealWorld) API for the multicore server challenge: raw std threads, one mio/epoll event loop per thread,
//! a hand-rolled pipelined Postgres client, and bcrypt on its own low-priority threads.

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

mod auth;
mod bcrypt2;
mod handlers;
mod json;
mod pg;
mod pool;
mod server;
mod sql;
mod util;

use std::net::{SocketAddr, ToSocketAddrs};
use std::process::exit;
use std::time::{Duration, Instant};

use handlers::Kind;

/// Postgres allows 100 connections; the challenge asks every submission to stay at or below 95.
const MAX_PG_CONNECTIONS: usize = 95;

fn required_env(key: &str) -> String {
    match std::env::var(key) {
        Ok(v) if !v.is_empty() => v,
        _ => {
            eprintln!("{key} must be set");
            exit(2);
        }
    }
}

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).ok().filter(|v| !v.is_empty()).unwrap_or_else(|| default.to_string())
}

fn env_num(key: &str, default: usize) -> usize {
    match env_or(key, &default.to_string()).parse() {
        Ok(n) => n,
        Err(_) => {
            eprintln!("{key} must be a non-negative integer");
            exit(2);
        }
    }
}

/// Every client is a socket: lift our soft descriptor limit to the hard one (the box sets 200000 / 1048576).
fn raise_fd_limit() {
    #[cfg(unix)]
    unsafe {
        let mut lim = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut lim) == 0 && lim.rlim_cur < lim.rlim_max {
            lim.rlim_cur = lim.rlim_max;
            libc::setrlimit(libc::RLIMIT_NOFILE, &lim);
        }
    }
}

fn main() {
    raise_fd_limit();
    let database_url = required_env("DATABASE_URL");
    let jwt_secret = required_env("JWT_SECRET");
    let host = env_or("HOST", "127.0.0.1");
    let port = env_num("PORT", 3000);
    // One loop of four backends (one per core) per four CPUs: more backends than cores made every statement slower
    // (time-slicing, cache misses) and cost ~19% more CPU per request; more loops split each loop's connection pool.
    let cpus = std::thread::available_parallelism().map_or(1, |n| n.get());
    let loops = match std::env::var("LOOPS") {
        Ok(v) if !v.is_empty() => env_num("LOOPS", 1).max(1),
        _ => (cpus / 4).clamp(1, MAX_PG_CONNECTIONS / 4),
    };
    // Per loop: PG_HEAVY + PG_READ connections form the read pool (feed, lists and point reads), PG_WRITE the writes.
    let pg_heavy = env_num("PG_HEAVY", 1);
    let pg_read = env_num("PG_READ", 2).max(1);
    let pg_write = env_num("PG_WRITE", 1);
    let bcrypt_threads = env_num("BCRYPT_THREADS", 2).max(1);
    let bcrypt_queue = env_num("BCRYPT_QUEUE", 256).max(1);
    if std::env::var_os("PG_HEAVY_SPILL").is_some() {
        eprintln!("PG_HEAVY_SPILL is no longer used: reads share one pool routed by queued work");
    }
    let route = match env_or("PG_ROUTE", "work").as_str() {
        "work" => server::Route::LeastWork,
        "count" => server::Route::LeastCount,
        _ => {
            eprintln!("PG_ROUTE must be work or count");
            exit(2);
        }
    };
    if loops * (pg_heavy + pg_read + pg_write) > MAX_PG_CONNECTIONS {
        eprintln!("LOOPS * (PG_HEAVY + PG_READ + PG_WRITE) must be <= {MAX_PG_CONNECTIONS}");
        exit(2);
    }

    let mut pg_cfg = pg::PgConfig::from_url(&database_url).unwrap_or_else(|e| {
        eprintln!("{e}");
        exit(2);
    });
    // jit/parallel query only add latency to these small OLTP statements; the timeouts bound a stuck lock or query.
    pg_cfg.settings =
        "SET jit = off; SET max_parallel_workers_per_gather = 0; SET statement_timeout = 9000; SET lock_timeout = 5000".into();
    // Generic plans skip 0.1-0.4 ms of planning per statement, and the plans are as good as the custom ones here.
    // They must come with jit = off: a generic LIMIT $n plan costs more than jit_above_cost and would JIT every call.
    let plan_cache_mode = env_or("PG_PLAN_CACHE_MODE", "force_generic_plan");
    if !plan_cache_mode.is_empty() {
        if !matches!(plan_cache_mode.as_str(), "auto" | "force_generic_plan" | "force_custom_plan") {
            eprintln!("PG_PLAN_CACHE_MODE must be auto, force_generic_plan or force_custom_plan");
            exit(2);
        }
        pg_cfg.settings.push_str(&format!("; SET plan_cache_mode = {plan_cache_mode}"));
    }

    let addr: SocketAddr = match format!("{host}:{port}").to_socket_addrs().ok().and_then(|mut a| a.next()) {
        Some(a) => a,
        None => {
            eprintln!("cannot resolve {host}:{port}");
            exit(2);
        }
    };

    // Every Postgres connection is up and prepared before anything listens, so the first /api/tags is real.
    let deadline = Instant::now() + Duration::from_secs(50);
    let mut setups = Vec::with_capacity(loops);
    for _ in 0..loops {
        let mut conns = Vec::new();
        let kinds = std::iter::repeat_n(Kind::Heavy, pg_heavy)
            .chain(std::iter::repeat_n(Kind::Read, pg_read))
            .chain(std::iter::repeat_n(Kind::Write, pg_write));
        for kind in kinds {
            match pg::connect(&pg_cfg, deadline) {
                Ok(s) => conns.push((kind, s)),
                Err(e) => {
                    eprintln!("cannot connect to Postgres: {e}");
                    exit(1);
                }
            }
        }
        setups.push(server::LoopSetup::new(conns).expect("create poll"));
    }

    let shared: &'static server::Shared = Box::leak(Box::new(server::Shared {
        stats_secs: env_num("STATS", 0) as u64,
        route,
        read_batch: env_num("READ_BATCH", 8).max(1),
        write_batch: env_num("WRITE_BATCH", 32).max(1),
        jwt: auth::Jwt::new(jwt_secret.as_bytes()),
        bcrypt: pool::BcryptPool::start(bcrypt_threads, bcrypt_queue),
        pg: pg_cfg,
    }));

    let mut handles = Vec::with_capacity(loops);
    for (id, setup) in setups.into_iter().enumerate() {
        let listener = server::bind(addr).unwrap_or_else(|e| {
            eprintln!("cannot bind {addr}: {e}");
            exit(1);
        });
        handles.push(
            std::thread::Builder::new()
                .name(format!("loop-{id}"))
                .spawn(move || server::run(id, setup, listener, shared))
                .expect("spawn event loop"),
        );
    }
    println!(
        "[server] listening on http://{addr} (pid {}, {loops} loops, {} pg connections, {bcrypt_threads} bcrypt threads)",
        std::process::id(),
        loops * (pg_heavy + pg_read + pg_write)
    );
    for h in handles {
        if h.join().is_err() {
            eprintln!("an event loop panicked");
            exit(1);
        }
    }
}
