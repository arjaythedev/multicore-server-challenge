//! Conduit (RealWorld) API for the multicore server challenge (see SPEC.md and README.md).
//! Direct HTTP/1.1 on Tokio, pipelined PostgreSQL and hand-written JSON.

mod api;
mod auth;
mod db;
mod http;
mod json;
mod password;
mod sql;
#[cfg(feature = "group-commit")]
mod writer;

use std::{
    env,
    net::{SocketAddr, ToSocketAddrs},
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};

use tokio::{net::TcpListener, sync::Semaphore};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

pub const BCRYPT_COST: u32 = 10;

pub struct App {
    pub db: db::Db,
    pub jwt: auth::Jwt,
    /// Caps concurrent bcrypt work so a burst of logins can't take every core from Postgres and the event loop.
    pub bcrypt: Arc<Semaphore>,
    #[cfg(all(feature = "batch-bcrypt", target_os = "linux"))]
    pub bcrypt_batch: password::Pool,
}

static APP: OnceLock<App> = OnceLock::new();
pub fn app() -> &'static App {
    APP.get().expect("app initialized")
}

/// ASCII digits only (no sign, no spaces) that fit in an i64.
pub fn parse_uint(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.parse().ok()
}

fn env_or<T: std::str::FromStr>(key: &str, default: T) -> T {
    match env::var(key) {
        Ok(v) if !v.is_empty() => v.parse().unwrap_or_else(|_| panic!("{key} is invalid")),
        _ => default,
    }
}

fn main() {
    let cores = std::thread::available_parallelism().map_or(1, |n| n.get());
    let threads = env_or("APP_THREADS", cores.div_ceil(4).min(8));
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(threads)
        .enable_all()
        .build()
        .expect("Tokio runtime")
        .block_on(run(cores, threads));
}

async fn run(cores: usize, threads: usize) {
    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let jwt_secret = env::var("JWT_SECRET").expect("JWT_SECRET must be set");
    let host: String = env_or("HOST", "127.0.0.1".to_string());
    let port: u16 = env_or("PORT", 3000);
    let read_conns: usize = env_or("DB_CONNS", (3 * cores).div_ceil(4).min(16));
    let write_conns: usize = env_or("DB_WRITE_CONNS", cores.div_ceil(4).min(8));
    let slots = env_or(
        "BCRYPT_THREADS",
        if cfg!(all(feature = "batch-bcrypt", target_os = "linux")) {
            cores.div_ceil(8)
        } else {
            cores.div_ceil(4)
        },
    );
    assert!(slots > 0, "at least one bcrypt worker");

    // Postgres may still be starting: retry for up to 50 s (the health check allows 60).
    let deadline = Instant::now() + Duration::from_secs(50);
    let db = loop {
        match db::Db::connect(&database_url, read_conns, write_conns).await {
            Ok(db) => break db,
            Err(e) if Instant::now() < deadline => {
                eprintln!("[db] connect failed, retrying: {e}");
                tokio::time::sleep(Duration::from_millis(500)).await;
            }
            Err(e) => panic!("could not connect to Postgres: {e}"),
        }
    };
    let (n_reads, n_writes) = db.len();
    let state = App {
        db,
        jwt: auth::Jwt::new(&jwt_secret),
        bcrypt: Arc::new(Semaphore::new(slots)),
        #[cfg(all(feature = "batch-bcrypt", target_os = "linux"))]
        bcrypt_batch: password::Pool::new(slots),
    };
    assert!(APP.set(state).is_ok());

    let addr: SocketAddr = (host.as_str(), port)
        .to_socket_addrs()
        .expect("HOST/PORT")
        .next()
        .expect("address");
    let listener = listen(addr).expect("could not bind");
    println!(
        "[server] listening on http://{addr} (pid {}, {threads} runtime workers, {n_reads} read + {n_writes} write Postgres connections)",
        std::process::id()
    );

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let _ = stream.set_nodelay(true);
                tokio::spawn(http::serve(stream));
            }
            Err(e) => {
                // Out of file descriptors and the like: back off briefly rather than spin.
                eprintln!("[server] accept: {e}");
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }
    }
}

fn listen(addr: SocketAddr) -> std::io::Result<TcpListener> {
    let socket = socket2::Socket::new(
        socket2::Domain::for_address(addr),
        socket2::Type::STREAM,
        None,
    )?;
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr.into())?;
    // A deep accept queue for direct mode, where tens of thousands of users connect during the ramp.
    socket.listen(16384)?;
    TcpListener::from_std(socket.into())
}

#[cfg(test)]
mod security_tests;
