mod api;
mod bcrypt_lanes;
mod crypt;
mod event_loop;
mod http;
mod json;
mod jwt;
mod pg;
mod sql;
mod sys;

use std::sync::{Arc, Mutex};

use mimalloc::MiMalloc;

use crate::api::Api;
use crate::crypt::{CryptPool, Mailbox};
use crate::event_loop::{EventLoop, LoopConfig};
use crate::pg::PgConfig;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

fn env_or(key: &str, default: usize) -> usize {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn main() {
    let cpus = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1);
    let loops = env_or("LOOPS", (cpus / 4).max(1));
    let read_conns = env_or("PG_READ", 4);
    let write_conns = env_or("PG_WRITE", 2);
    let write_batch = env_or("WRITE_BATCH", 64);
    let depth = env_or("PG_DEPTH", 1);
    let read_batch = env_or("READ_BATCH", 128);
    let bcrypt_threads = env_or("BCRYPT_THREADS", (cpus / 4).max(1));
    if loops * (read_conns + write_conns) > 95 {
        eprintln!(
            "too many Postgres connections: {}",
            loops * (read_conns + write_conns)
        );
        std::process::exit(1);
    }
    let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
    let secret = std::env::var("JWT_SECRET").expect("JWT_SECRET");
    let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into());
    let port: u16 = std::env::var("PORT")
        .ok()
        .and_then(|p| p.parse().ok())
        .unwrap_or(3000);
    let options = std::env::var("PG_OPTIONS").unwrap_or_else(|_| {
        "-c plan_cache_mode=force_generic_plan -c jit=off -c max_parallel_workers_per_gather=0"
            .into()
    });
    let pg = Arc::new(PgConfig::from_url(&url, options).expect("bad DATABASE_URL"));

    let mut collation = None;
    for attempt in 0..50 {
        match pg::probe_collation(&pg) {
            Ok(c) => {
                collation = Some(c);
                break;
            }
            Err(e) => {
                eprintln!("waiting for postgres (attempt {attempt}): {e}");
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
    let collation = collation.expect("postgres unreachable");
    let app_sort = matches!(collation.as_str(), "C" | "POSIX" | "C.UTF-8" | "C.utf8");
    eprintln!(
        "conduit: {loops} loops, {read_conns}+{write_conns} pg conns per loop, depth {depth}, \
         {bcrypt_threads} bcrypt threads, read batch {read_batch}, collation {collation}, \
         app sort {app_sort}"
    );

    let statements = Arc::new(sql::statements(app_sort));
    let api = Arc::new(Api::new(secret.as_bytes(), app_sort));
    let mut wake_fds = Vec::new();
    let mut mailboxes = Vec::new();
    for _ in 0..loops {
        let efd = sys::eventfd().expect("eventfd");
        wake_fds.push(efd);
        mailboxes.push(Mailbox {
            efd,
            done: Mutex::new(Vec::new()),
        });
    }
    let bcrypt_wait = std::time::Duration::from_millis(env_or("BCRYPT_WAIT_MS", 100) as u64);
    let crypt = CryptPool::start(bcrypt_threads, bcrypt_wait, mailboxes);

    let mut handles = Vec::new();
    for (id, wake_fd) in wake_fds.into_iter().enumerate() {
        let cfg = LoopConfig {
            id,
            host: host.clone(),
            port,
            pg: Arc::clone(&pg),
            statements: Arc::clone(&statements),
            read_conns,
            write_conns,
            depth,
            write_batch,
            read_batch,
            read_delay: std::time::Duration::from_micros(env_or("READ_DELAY_US", 20000) as u64),
            write_delay: std::time::Duration::from_micros(env_or("WRITE_DELAY_US", 10000) as u64),
            stats: std::env::var("STATS").is_ok_and(|v| v == "1"),
        };
        let mut ev = EventLoop::new(cfg, wake_fd, Arc::clone(&api), Arc::clone(&crypt))
            .unwrap_or_else(|e| {
                eprintln!("loop {id}: {e}");
                std::process::exit(1);
            });
        handles.push(std::thread::spawn(move || ev.run()));
    }
    for h in handles {
        let _ = h.join();
    }
}
