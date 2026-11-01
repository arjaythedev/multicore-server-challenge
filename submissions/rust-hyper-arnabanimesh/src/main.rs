//! Conduit (RealWorld) API for the Multicore Server Challenge.
//!
//! Architecture
//!  * N worker threads, each a single-threaded tokio runtime with its own SO_REUSEPORT listener and its
//!    own few Postgres connections: nothing is shared between threads on the request path, so there are
//!    no cross-thread wake-ups, locks or work-stealing.
//!  * hyper (HTTP/1.1 keep-alive) straight to a hand-written router, hand-written JSON.
//!  * tokio-postgres connections pipeline concurrent requests; statements are prepared once and each
//!    endpoint costs one round trip on the hot paths.
//!  * bcrypt runs on a separate low-priority OS-thread pool.

mod api;
mod auth;
mod db;
mod json;

use std::net::{SocketAddr, ToSocketAddrs};
use std::sync::Arc;
use std::time::Duration;

use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::{TcpListener, TcpStream};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

fn env_or(name: &str, default: &str) -> String {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => v,
        _ => default.to_string(),
    }
}

fn env_usize(name: &str, default: usize) -> usize {
    match std::env::var(name).ok().and_then(|v| v.parse::<usize>().ok()) {
        Some(v) if v > 0 => v,
        _ => default,
    }
}

fn main() {
    let database_url = std::env::var("DATABASE_URL").expect("DATABASE_URL is required");
    let cfg: tokio_postgres::Config = database_url.parse().expect("invalid DATABASE_URL");
    let generic = env_or("PG_GENERIC_PLANS", "1") != "0";

    // `conduit --check`: validate every SQL statement against the real database and print the plans.
    if std::env::args().any(|a| a == "--check") {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("failed to build tokio runtime");
        match rt.block_on(db::check(&cfg, generic)) {
            Ok(()) => return,
            Err(e) => {
                eprintln!("check failed: {e}");
                std::process::exit(1);
            }
        }
    }

    let jwt_secret = std::env::var("JWT_SECRET").expect("JWT_SECRET is required");
    let host = env_or("HOST", "127.0.0.1");
    let port: u16 = env_or("PORT", "3000").parse().expect("PORT must be a number");
    let addr: SocketAddr = (host.as_str(), port)
        .to_socket_addrs()
        .expect("cannot resolve HOST")
        .next()
        .expect("HOST resolved to no address");

    raise_nofile_limit();

    let cores = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(4);
    // The app itself needs little CPU; Postgres needs the rest. Fewer, busier threads also batch more
    // work per syscall. Tunable without recompiling.
    let threads = env_usize("APP_THREADS", std::cmp::max(2, cores / 2));
    // Total connections must stay <= 95 (max_connections = 100); stay well below.
    let per_thread = env_usize("DB_CONNS_PER_THREAD", 4).min(std::cmp::max(1, 90 / threads));
    let bcrypt_threads = env_usize("BCRYPT_THREADS", cores);
    let bcrypt_nice: i32 = std::env::var("BCRYPT_NICE").ok().and_then(|v| v.parse().ok()).unwrap_or(10);

    let jwt = Arc::new(auth::Jwt::new(&jwt_secret));
    let bc = Arc::new(auth::BcryptPool::new(bcrypt_threads, bcrypt_nice));

    eprintln!(
        "conduit: listening on {addr}, {threads} worker threads x {per_thread} postgres connections \
         (generic plans: {generic}), {bcrypt_threads} bcrypt threads (nice {bcrypt_nice})"
    );

    let mut handles = Vec::with_capacity(threads);
    for i in 0..threads {
        let cfg = cfg.clone();
        let jwt = jwt.clone();
        let bc = bc.clone();
        let handle = std::thread::Builder::new()
            .name(format!("conduit-{i}"))
            .spawn(move || worker(cfg, per_thread, generic, jwt, bc, addr))
            .expect("failed to spawn worker thread");
        handles.push(handle);
    }
    for h in handles {
        let _ = h.join();
    }
}

fn worker(
    cfg: tokio_postgres::Config,
    conns: usize,
    generic: bool,
    jwt: Arc<auth::Jwt>,
    bc: Arc<auth::BcryptPool>,
    addr: SocketAddr,
) {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("failed to build tokio runtime");
    rt.block_on(run(cfg, conns, generic, jwt, bc, addr));
}

async fn run(
    cfg: tokio_postgres::Config,
    conns: usize,
    generic: bool,
    jwt: Arc<auth::Jwt>,
    bc: Arc<auth::BcryptPool>,
    addr: SocketAddr,
) {
    // Connect and prepare first, listen afterwards: once a socket accepts, every request can be served.
    let db = db::Db::connect(&cfg, conns, generic).await;
    let app = Arc::new(api::App { db, jwt, bc });

    let listener = match make_listener(addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cannot listen on {addr}: {e}");
            std::process::exit(1);
        }
    };

    loop {
        match listener.accept().await {
            Ok((stream, _peer)) => {
                let _ = stream.set_nodelay(true);
                tokio::spawn(serve(stream, app.clone()));
            }
            Err(e) => {
                // EMFILE and friends: back off briefly instead of spinning.
                eprintln!("accept error: {e}");
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }
    }
}

async fn serve(stream: TcpStream, app: Arc<api::App>) {
    let io = TokioIo::new(stream);
    let svc = service_fn(move |req| api::handle(app.clone(), req));
    // Idle keep-alive connections are never closed by us (the load generator's users think for up to
    // 70 s between pages; behind Nginx its upstream keep-alive is 60 s). Resets are normal; ignore them.
    let _ = http1::Builder::new().serve_connection(io, svc).await;
}

/// One listener per worker thread, all bound to the same address with SO_REUSEPORT: the kernel spreads
/// incoming connections across the threads.
fn make_listener(addr: SocketAddr) -> std::io::Result<TcpListener> {
    let domain = if addr.is_ipv4() { Domain::IPV4 } else { Domain::IPV6 };
    let socket = Socket::new(domain, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_reuse_address(true)?;
    socket.set_reuse_port(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr.into())?;
    socket.listen(65_535)?;
    let std_listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(std_listener)
}

/// Direct mode keeps tens of thousands of keep-alive connections open. The service unit already grants
/// LimitNOFILE=200000; this just raises the soft limit to the hard limit when it is lower (best effort).
fn raise_nofile_limit() {
    unsafe {
        let mut rl = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut rl) == 0 && rl.rlim_cur < rl.rlim_max {
            rl.rlim_cur = rl.rlim_max;
            let _ = libc::setrlimit(libc::RLIMIT_NOFILE, &rl);
        }
    }
}