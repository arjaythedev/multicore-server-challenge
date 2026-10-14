//! Conduit (RealWorld) API for the multicore server challenge (see SPEC.md and README.md).
//! hyper 1 HTTP/1.1 straight on tokio, tokio-postgres with pipelined shared connections, hand-written JSON.

mod api;
mod auth;
mod db;
mod json;
mod sql;

use std::{
    convert::Infallible,
    env,
    net::{SocketAddr, ToSocketAddrs},
    sync::OnceLock,
    time::{Duration, Instant},
};

use bytes::Bytes;
use http_body_util::{BodyExt, Full};
use hyper::{Request, Response, body::Incoming, header::AUTHORIZATION, server::conn::http1, service::service_fn};
use hyper_util::rt::TokioIo;
use tokio::{net::TcpListener, sync::Semaphore};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

pub const BCRYPT_COST: u32 = 10;

pub struct App {
    pub db: db::Db,
    pub jwt: auth::Jwt,
    /// Caps concurrent bcrypt work so a burst of logins can't take every core from Postgres and the event loop.
    pub bcrypt: Semaphore,
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
    let threads = env_or("APP_THREADS", cores);
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(threads)
        .enable_all()
        .build()
        .expect("tokio runtime")
        .block_on(run(cores, threads));
}

async fn run(cores: usize, threads: usize) {
    let database_url = env::var("DATABASE_URL").expect("DATABASE_URL must be set");
    let jwt_secret = env::var("JWT_SECRET").expect("JWT_SECRET must be set");
    let host: String = env_or("HOST", "127.0.0.1".to_string());
    let port: u16 = env_or("PORT", 3000);
    let read_conns: usize = env_or("DB_CONNS", 2 * cores);
    let write_conns: usize = env_or("DB_WRITE_CONNS", 4 * cores);
    let bcrypt_slots: usize = env_or("BCRYPT_THREADS", cores.max(2) - 1);

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
    if APP.set(App { db, jwt: auth::Jwt::new(&jwt_secret), bcrypt: Semaphore::new(bcrypt_slots) }).is_err() {
        unreachable!();
    }

    let addr: SocketAddr = (host.as_str(), port).to_socket_addrs().expect("HOST/PORT").next().expect("address");
    let listener = listen(addr).expect("could not bind");
    println!(
        "[server] listening on http://{addr} (pid {}, {threads} threads, {n_reads} read + {n_writes} write Postgres connections)",
        std::process::id()
    );

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let _ = stream.set_nodelay(true);
                tokio::spawn(serve(stream));
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
    let socket = socket2::Socket::new(socket2::Domain::for_address(addr), socket2::Type::STREAM, None)?;
    socket.set_reuse_address(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&addr.into())?;
    // A deep accept queue for direct mode, where tens of thousands of users connect during the ramp.
    socket.listen(16384)?;
    TcpListener::from_std(socket.into())
}

/// One keep-alive connection. No idle timeout: a connection stays open until the client closes it.
async fn serve(stream: tokio::net::TcpStream) {
    let _ = http1::Builder::new()
        .keep_alive(true)
        .header_read_timeout(None)
        .serve_connection(TokioIo::new(stream), service_fn(handle))
        .await;
}

async fn handle(req: Request<Incoming>) -> Result<Response<Full<Bytes>>, Infallible> {
    let (parts, body) = req.into_parts();
    let body = match body.collect().await {
        Ok(b) => b.to_bytes(),
        Err(_) => Bytes::new(),
    };
    let auth = api::Auth(parts.headers.get(AUTHORIZATION).map(|v| v.as_bytes()).filter(|v| !v.is_empty()));
    let resp = api::route(&parts.method, parts.uri.path(), parts.uri.query(), auth, &body).await;
    Ok(resp.unwrap_or_else(api::error_response))
}
