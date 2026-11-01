//! Conduit API server: a small HTTP/1.1 keep-alive layer on multi-thread Tokio, Postgres via tokio-postgres.

mod api;
mod bcrypt;
mod blowfish_consts;
mod cross;
mod db;
mod json;

use std::io::Write;
use std::net::SocketAddr;
use std::ops::Range;

use tokio::io::AsyncWriteExt;
use tokio::net::{TcpSocket, TcpStream};

#[global_allocator]
static GLOBAL: mimalloc::MiMalloc = mimalloc::MiMalloc;

const MAX_HEAD: usize = 16 << 10;
const MAX_BODY: usize = 1 << 20;

fn env(k: &str, d: &str) -> String {
    std::env::var(k).unwrap_or_else(|_| d.to_owned())
}
fn env_n(k: &str, d: usize) -> usize {
    env(k, &d.to_string()).parse().unwrap_or_else(|_| panic!("{k} must be a number"))
}

fn main() {
    let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(env_n("APP_THREADS", 3)).enable_all().build().unwrap();
    api::init_secret(&std::env::var("JWT_SECRET").expect("JWT_SECRET"));
    bcrypt::init(env_n("BCRYPT_THREADS", 2), std::time::Duration::from_millis(env_n("BCRYPT_BATCH_MS", 250) as u64));
    rt.block_on(async {
        let url = std::env::var("DATABASE_URL").expect("DATABASE_URL");
        let wait = std::time::Duration::from_micros(env_n("READ_BATCH_US", 20_000) as u64);
        db::init(&url, env_n("DB_READ_CONNS", 8), env_n("DB_WRITE_CONNS", 2), wait, env_n("READ_CROSS", 1) == 1).await;
        let addr: SocketAddr = format!("{}:{}", env("HOST", "0.0.0.0"), env("PORT", "3000")).parse().expect("HOST:PORT");
        let sock = if addr.is_ipv4() { TcpSocket::new_v4() } else { TcpSocket::new_v6() }.unwrap();
        sock.set_reuseaddr(true).unwrap();
        sock.bind(addr).expect("bind");
        let listener = sock.listen(65535).unwrap();
        eprintln!("listening on {addr}");
        loop {
            match listener.accept().await {
                Ok((s, _)) => {
                    let _ = s.set_nodelay(true);
                    tokio::spawn(serve(s));
                }
                Err(e) => {
                    // e.g. out of file descriptors: back off instead of spinning
                    eprintln!("accept: {e}");
                    tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                }
            }
        }
    });
}

fn reason(code: u16) -> &'static str {
    match code {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        422 => "Unprocessable Entity",
        _ => "Internal Server Error",
    }
}

struct Head {
    method: &'static str,
    path: Range<usize>,
    auth: Option<Range<usize>>,
    body: Range<usize>,
    close: bool,
}

/// The next request in `buf` as offsets into it. Ok(None): not all here yet. Err: malformed or too big.
fn head(buf: &[u8]) -> Result<Option<Head>, ()> {
    let mut hs = [httparse::EMPTY_HEADER; 32];
    let mut req = httparse::Request::new(&mut hs);
    let n = match req.parse(buf) {
        Ok(httparse::Status::Complete(n)) => n,
        Ok(httparse::Status::Partial) if buf.len() <= MAX_HEAD => return Ok(None),
        _ => return Err(()),
    };
    let at = |s: &[u8]| {
        let o = s.as_ptr() as usize - buf.as_ptr() as usize;
        o..o + s.len()
    };
    let (mut len, mut auth, mut close) = (0usize, None, false);
    for h in req.headers.iter() {
        if h.name.eq_ignore_ascii_case("content-length") {
            len = std::str::from_utf8(h.value).ok().and_then(|v| v.trim().parse().ok()).ok_or(())?;
        } else if h.name.eq_ignore_ascii_case("authorization") {
            auth = Some(at(h.value));
        } else if h.name.eq_ignore_ascii_case("connection") {
            close = h.value.eq_ignore_ascii_case(b"close");
        } else if h.name.eq_ignore_ascii_case("transfer-encoding") {
            return Err(()); // clients here send Content-Length; don't guess at chunked framing
        }
    }
    if len > MAX_BODY {
        return Err(());
    }
    if buf.len() < n + len {
        return Ok(None);
    }
    let method = match req.method.unwrap() {
        "GET" => "GET",
        "POST" => "POST",
        "PUT" => "PUT",
        "DELETE" => "DELETE",
        _ => "",
    };
    Ok(Some(Head { method, path: at(req.path.unwrap().as_bytes()), auth, body: n..n + len, close }))
}

async fn serve(mut s: TcpStream) {
    // The read buffer exists only while a request is arriving or in flight: idle keep-alive connections (most
    // of them, most of the time) hold just the socket and this small task. Never closed for idleness.
    let mut buf: Vec<u8> = Vec::new();
    loop {
        if buf.is_empty() {
            buf = Vec::new();
            if s.readable().await.is_err() {
                return;
            }
        } else {
            match head(&buf) {
                Err(()) => {
                    let _ = s.write_all(b"HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 35\r\nConnection: close\r\n\r\n{\"errors\":{\"body\":[\"bad request\"]}}").await;
                    return;
                }
                Ok(Some(h)) => {
                    let path = std::str::from_utf8(&buf[h.path.clone()]).unwrap_or("");
                    let auth = h.auth.clone().map(|r| &buf[r]);
                    let (code, body) = Box::pin(api::handle(h.method, path, auth, &buf[h.body.clone()])).await;
                    let mut out = Vec::with_capacity(body.len() + 100);
                    if code == 204 {
                        out.extend_from_slice(b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n");
                    } else {
                        let _ = write!(
                            out,
                            "HTTP/1.1 {code} {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",
                            reason(code),
                            body.len()
                        );
                        out.extend_from_slice(&body);
                    }
                    if s.write_all(&out).await.is_err() || h.close {
                        return;
                    }
                    buf.drain(..h.body.end);
                    continue;
                }
                Ok(None) => {}
            }
        }
        if buf.capacity() - buf.len() < 2048 {
            buf.reserve(4096);
        }
        match s.try_read_buf(&mut buf) {
            Ok(0) => return,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                if s.readable().await.is_err() {
                    return;
                }
            }
            Err(_) => return,
        }
    }
}
