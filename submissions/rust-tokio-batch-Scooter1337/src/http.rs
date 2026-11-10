//! HTTP/1.1 framing with buffers held only while work is in flight. Idle sockets retain
//! neither request nor response buffers. Parsing uses httparse; JSON remains in api.rs.
use crate::api;
use http::Method;
use std::{cell::RefCell, io, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

const MAX_HEAD: usize = 64 * 1024;
const MAX_BODY: usize = 16 * 1024 * 1024;
const READ_TIMEOUT: Duration = Duration::from_secs(30);
/// JSON bodies this large may be gzipped (level 1) for clients that accept it, as the challenge's Nginx does
/// (`gzip_min_length 1024`). List pages (~10 KB) shrink ~2.7x, but compression costs ~7% of the box's CPU per
/// request, so by default it runs only while the link is busy (see `egress`).
const GZIP_MIN: usize = 1024;
// Separate tiny request heads from response buffers so active requests do not
// retain a large response allocation while waiting for PostgreSQL. Each class
// has a fixed 64-slot free stack and never allocates its bookkeeping.
struct Pool {
    slots: [[Vec<u8>; 64]; 4],
    len: [usize; 4],
}
impl Pool {
    const fn new() -> Self {
        Self {
            slots: [const { [const { Vec::new() }; 64] }; 4],
            len: [0; 4],
        }
    }
    fn take(&mut self, class: usize) -> Vec<u8> {
        if self.len[class] != 0 {
            self.len[class] -= 1;
            std::mem::take(&mut self.slots[class][self.len[class]])
        } else {
            Vec::with_capacity([1024, 4096, 16384, 65536][class])
        }
    }
    fn release(&mut self, mut b: Vec<u8>) {
        let class = match b.capacity() {
            1..=1024 => 0,
            1025..=4096 => 1,
            4097..=16384 => 2,
            16385..=65536 => 3,
            _ => return,
        };
        let n = self.len[class];
        if n < 64 {
            b.clear();
            self.slots[class][n] = b;
            self.len[class] += 1;
        }
    }
}
thread_local! { static BUFFERS: RefCell<Pool> = const { RefCell::new(Pool::new()) }; }
pub(crate) fn take() -> Vec<u8> {
    BUFFERS.with(|p| {
        let mut p = p.borrow_mut();
        // Prefer an available response allocation over growing a small buffer.
        let class = if p.len[2] > 0 {
            2
        } else if p.len[3] > 0 {
            3
        } else {
            1
        };
        p.take(class)
    })
}
fn take_input() -> Vec<u8> {
    BUFFERS.with(|p| p.borrow_mut().take(0))
}
fn release(b: Vec<u8>) {
    BUFFERS.with(|p| p.borrow_mut().release(b));
}
thread_local! {
    static GZIP: RefCell<Option<libdeflater::Compressor>> = const { RefCell::new(None) };
}
#[derive(Clone, Copy, PartialEq)]
enum GzipMode {
    Off,
    Always,
    /// Compress while the bytes sent exceed this many per `egress::WINDOW_MS`.
    Above(u64),
}
/// Reads the gzip settings and opens the TCP counters before any connection takes a descriptor.
pub fn init() {
    if let GzipMode::Above(_) = gzip_mode() {
        let _ = egress::tcp_segments();
    }
}
fn gzip_mode() -> GzipMode {
    static MODE: std::sync::OnceLock<GzipMode> = std::sync::OnceLock::new();
    *MODE.get_or_init(|| match std::env::var("HTTP_GZIP").ok().as_deref() {
        Some("0") => GzipMode::Off,
        Some("1") => GzipMode::Always,
        _ => {
            let mbs: u64 = std::env::var("HTTP_GZIP_ABOVE_MBS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(100);
            GzipMode::Above(mbs * 1_000_000 * egress::WINDOW_MS / 1000)
        }
    })
}

/// Adaptive compression. Every 50 ms the share of eligible responses that get compressed moves up by 1/16
/// while the bytes actually sent in the last window were over the limit and the link was dropping segments
/// (see `lossy`), and down by 1/16 otherwise. A CPU-bound box on a fast link therefore sends plain JSON, and
/// a full link compresses just enough to stay under the limit. The meter is two relaxed atomics per
/// response; the share is dithered per worker thread.
mod egress {
    use std::{
        cell::Cell,
        sync::{
            OnceLock,
            atomic::{AtomicU64, Ordering::Relaxed},
        },
        time::Instant,
    };
    pub const WINDOW_MS: u64 = 50;
    const FULL: u64 = 256;
    const STEP: u64 = FULL / 16;
    static WINDOW: AtomicU64 = AtomicU64::new(0);
    static BYTES: AtomicU64 = AtomicU64::new(0);
    static SHARE: AtomicU64 = AtomicU64::new(0);
    thread_local! { static TURN: Cell<u64> = const { Cell::new(0) }; }

    fn window() -> u64 {
        static START: OnceLock<Instant> = OnceLock::new();
        START.get_or_init(Instant::now).elapsed().as_millis() as u64 / WINDOW_MS + 1
    }
    /// Record `n` bytes sent; the first response of a new window updates the share.
    pub fn sent(n: usize, limit: u64) {
        let w = window();
        let last = WINDOW.load(Relaxed);
        if last != w && WINDOW.compare_exchange(last, w, Relaxed, Relaxed).is_ok() {
            // Read the TCP counters every window so the loss rate always covers the last 50 ms.
            let lossy = lossy();
            let over = BYTES.swap(0, Relaxed) > limit && lossy;
            SHARE.store(
                next_share(SHARE.load(Relaxed), w == last + 1, over),
                Relaxed,
            );
        }
        BYTES.fetch_add(n as u64, Relaxed);
    }
    /// A gap of idle windows counts as under the limit.
    pub(super) fn next_share(share: u64, consecutive: bool, over: bool) -> u64 {
        if consecutive && over {
            (share + STEP).min(FULL)
        } else {
            share.saturating_sub(STEP)
        }
    }
    /// Whether TCP retransmitted at least `HTTP_GZIP_RETRANS` per mille (default 5) of the segments sent since
    /// the last call, from the kernel's counters in /proc/net/snmp. A link that is really full drops segments
    /// (10% on the Boat boxes); a CPU-bound box sending the same bytes over a faster link drops none, and there
    /// compressing would only cost CPU. `HTTP_GZIP_RETRANS=0`, or no /proc, leaves the byte limit alone.
    fn lossy() -> bool {
        static PERMILLE: OnceLock<u64> = OnceLock::new();
        static OUT: AtomicU64 = AtomicU64::new(0);
        static RETRANS: AtomicU64 = AtomicU64::new(0);
        let permille = *PERMILLE.get_or_init(|| {
            std::env::var("HTTP_GZIP_RETRANS")
                .ok()
                .and_then(|v| v.parse().ok())
                .unwrap_or(5)
        });
        if permille == 0 {
            return true;
        }
        let Some(counters) = tcp_segments() else {
            return true;
        };
        // A failed read (EINTR and the like) leaves the share to decay rather than counting as loss.
        let Some((out, retrans)) = counters else {
            return false;
        };
        let out = out.saturating_sub(OUT.swap(out, Relaxed));
        let retrans = retrans.saturating_sub(RETRANS.swap(retrans, Relaxed));
        retrans * 1000 >= out.max(1) * permille
    }
    /// `(OutSegs, RetransSegs)` from the `Tcp:` header and value lines of /proc/net/snmp; `None` without /proc.
    /// The file is opened once and reread from the start: with one connection per user the process can run
    /// out of descriptors, and a fresh open then failed with EMFILE, which counted as loss and turned
    /// compression on for a CPU-bound box (0.55 of its 8 cores at 200,000 users).
    pub(super) fn tcp_segments() -> Option<Option<(u64, u64)>> {
        use std::io::{Read, Seek};
        static SNMP: OnceLock<Option<std::sync::Mutex<std::fs::File>>> = OnceLock::new();
        let file = SNMP
            .get_or_init(|| {
                std::fs::File::open("/proc/net/snmp")
                    .ok()
                    .map(std::sync::Mutex::new)
            })
            .as_ref()?;
        let mut snmp = String::with_capacity(2048);
        let mut f = file.lock().unwrap_or_else(|e| e.into_inner());
        if f.rewind().is_err() || f.read_to_string(&mut snmp).is_err() {
            return Some(None);
        }
        Some(parse_tcp(&snmp))
    }
    fn parse_tcp(snmp: &str) -> Option<(u64, u64)> {
        let mut tcp = snmp.lines().filter(|l| l.starts_with("Tcp:"));
        let (names, values) = (tcp.next()?, tcp.next()?);
        let field = |name| {
            let i = names.split_ascii_whitespace().position(|n| n == name)?;
            values.split_ascii_whitespace().nth(i)?.parse().ok()
        };
        Some((field("OutSegs")?, field("RetransSegs")?))
    }
    /// Whether this eligible response should be compressed.
    pub fn compress() -> bool {
        let share = SHARE.load(Relaxed);
        share != 0
            && TURN.with(|t| {
                let turn = t.get().wrapping_add(1);
                t.set(turn);
                turn % FULL < share
            })
    }
}
/// The gzip encoding of `body` in a pooled buffer, if it is smaller.
fn gzip(body: &[u8]) -> Option<Vec<u8>> {
    GZIP.with(|c| {
        let mut c = c.borrow_mut();
        let c = c.get_or_insert_with(|| {
            libdeflater::Compressor::new(libdeflater::CompressionLvl::new(1).expect("level 1"))
        });
        let mut out = take();
        out.resize(c.gzip_compress_bound(body.len()), 0);
        match c.gzip_compress(body, &mut out) {
            Ok(n) if n < body.len() => {
                out.truncate(n);
                Some(out)
            }
            _ => {
                release(out);
                None
            }
        }
    })
}
/// Accept-Encoding allows gzip: a `gzip` or `*` coding without `q=0`.
fn accepts_gzip(value: &[u8]) -> bool {
    value.split(|b| *b == b',').any(|coding| {
        let mut parts = coding.split(|b| *b == b';');
        let name = parts.next().unwrap_or_default().trim_ascii();
        (name.eq_ignore_ascii_case(b"gzip") || name == b"*")
            && parts.all(|p| {
                let p = p.trim_ascii();
                !(p.len() >= 2 && p[..2].eq_ignore_ascii_case(b"q="))
                    || p[2..].iter().any(|b| b.is_ascii_digit() && *b != b'0')
            })
    })
}
fn invalid() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, "invalid HTTP framing")
}
async fn more(s: &mut TcpStream, b: &mut Vec<u8>, max: usize) -> io::Result<()> {
    if b.len() >= max {
        return Err(invalid());
    }
    b.reserve(1024);
    if s.read_buf(b).await? == 0 {
        return Err(io::ErrorKind::UnexpectedEof.into());
    }
    Ok(())
}
async fn through(s: &mut TcpStream, b: &mut Vec<u8>, end: usize) -> io::Result<()> {
    while b.len() < end {
        more(s, b, end).await?;
    }
    Ok(())
}
async fn line(s: &mut TcpStream, b: &mut Vec<u8>, at: usize) -> io::Result<usize> {
    loop {
        if let Some(n) = memchr::memmem::find(&b[at..], b"\r\n") {
            return if n <= MAX_HEAD {
                Ok(at + n)
            } else {
                Err(invalid())
            };
        }
        if b.len() - at > MAX_HEAD {
            return Err(invalid());
        }
        more(s, b, MAX_BODY + MAX_HEAD).await?;
    }
}
fn has_token(value: &[u8], token: &[u8]) -> bool {
    value
        .split(|b| *b == b',')
        .any(|x| x.trim_ascii().eq_ignore_ascii_case(token))
}

pub async fn serve(mut stream: TcpStream) {
    let mut input = Vec::new();
    loop {
        // No allocation until the next request becomes readable.
        if input.is_empty() {
            release(std::mem::take(&mut input));
            if stream.readable().await.is_err() {
                return;
            }
            input = take_input();
            // read_buf, not try_read_buf: Tokio clears readiness after a short read only on the
            // poll_read path, so try_read_buf left every socket "readable" after its request and
            // cost one EAGAIN read per request.
            match stream.read_buf(&mut input).await {
                Ok(n) if n > 0 => {}
                _ => {
                    release(input);
                    return;
                }
            }
        }
        #[cfg(feature = "boxed-requests")]
        let keep = Box::pin(handle_one(&mut stream, &mut input)).await;
        #[cfg(not(feature = "boxed-requests"))]
        let keep = handle_one(&mut stream, &mut input).await;
        if !matches!(keep, Ok(true)) {
            release(input);
            return;
        }
    }
}

async fn read_request(
    s: &mut TcpStream,
    input: &mut Vec<u8>,
) -> io::Result<(Head, Vec<u8>, usize)> {
    let mut scan = 0;
    loop {
        if memchr::memmem::find(&input[scan..], b"\r\n\r\n").is_some() {
            break;
        }
        if input.len() > MAX_HEAD {
            return Err(invalid());
        }
        scan = input.len().saturating_sub(3);
        more(s, input, MAX_HEAD).await?;
    }
    let parsed = parse_head(input)?;
    let head = parsed.end;
    if parsed.expect {
        s.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").await?;
    }
    let mut decoded = Vec::new();
    let end;
    if parsed.chunked {
        let mut at = head;
        loop {
            let stop = line(s, input, at).await?;
            let size = input[at..stop]
                .split(|b| *b == b';')
                .next()
                .ok_or_else(invalid)?;
            if size.is_empty() || size.len() > 16 || !size.iter().all(|b| b.is_ascii_hexdigit()) {
                return Err(invalid());
            }
            let n = usize::from_str_radix(std::str::from_utf8(size).map_err(|_| invalid())?, 16)
                .map_err(|_| invalid())?;
            at = stop + 2;
            if n == 0 {
                let trailer_start = at;
                loop {
                    let stop = line(s, input, at).await?;
                    if stop == at {
                        at += 2;
                        break;
                    }
                    if stop - trailer_start > MAX_HEAD || !input[at..stop].contains(&b':') {
                        return Err(invalid());
                    }
                    at = stop + 2;
                }
                end = at;
                break;
            }
            if n > MAX_BODY - decoded.len() {
                return Err(invalid());
            }
            let next = at
                .checked_add(n)
                .and_then(|x| x.checked_add(2))
                .ok_or_else(invalid)?;
            through(s, input, next).await?;
            if &input[next - 2..next] != b"\r\n" {
                return Err(invalid());
            }
            decoded.extend_from_slice(&input[at..next - 2]);
            at = next;
            // Release consumed wire framing independently of decoded body size.
            // Keep the request head (target/auth offsets) and any pipelined bytes.
            if at - head >= MAX_HEAD {
                input.drain(head..at);
                at = head;
            }
        }
    } else {
        end = head + parsed.length.unwrap_or(0);
        through(s, input, end).await?;
    }
    Ok((parsed, decoded, end))
}

async fn handle_one(s: &mut TcpStream, input: &mut Vec<u8>) -> io::Result<bool> {
    // Idle keep-alive is unlimited; completion is bounded once a request starts.
    // The timer ends before database/CPU work and cannot cancel a mutation.
    let (head, decoded, end) = tokio::time::timeout(READ_TIMEOUT, read_request(s, input))
        .await
        .map_err(|_| io::Error::new(io::ErrorKind::TimedOut, "request read deadline"))??;
    let Head {
        method,
        target: target_range,
        auth,
        chunked,
        close,
        gzip: accepts,
        end: head,
        ..
    } = head;
    let target = std::str::from_utf8(&input[target_range]).map_err(|_| invalid())?;
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, Some(q)),
        None => (target, None),
    };
    let auth = api::Auth(auth.map(|r| &input[r]));
    let body = if chunked {
        &decoded[..]
    } else {
        &input[head..end]
    };
    let resp = api::route(&method, path, query, auth, body)
        .await
        .unwrap_or_else(api::error_response);
    let bodiless = method == Method::HEAD || resp.status == 204;
    let mut body = resp.body;
    let mut encoded = false;
    let mode = gzip_mode();
    if accepts
        && !bodiless
        && body.len() >= GZIP_MIN
        && match mode {
            GzipMode::Off => false,
            GzipMode::Always => true,
            GzipMode::Above(_) => egress::compress(),
        }
        && let Some(z) = gzip(&body)
    {
        release(std::mem::replace(&mut body, z));
        encoded = true;
    }
    // Serialize headers and body once, then reuse the output allocation for the write.
    let mut output = Header {
        bytes: [0; 192],
        len: 0,
    };
    output.extend_from_slice(b"HTTP/1.1 ");
    output.extend_from_slice(itoa::Buffer::new().format(resp.status).as_bytes());
    output.extend_from_slice(b" OK\r\nContent-Type: application/json\r\n");
    if encoded {
        output.extend_from_slice(b"Content-Encoding: gzip\r\n");
    }
    if resp.status != 204 {
        output.extend_from_slice(b"Content-Length: ");
        output.extend_from_slice(itoa::Buffer::new().format(body.len()).as_bytes());
        output.extend_from_slice(b"\r\n");
    }
    output.extend_from_slice(if close {
        b"Connection: close\r\n\r\n"
    } else {
        b"\r\n"
    });
    let payload = if bodiless { &[][..] } else { &body };
    if let GzipMode::Above(limit) = mode {
        egress::sent(output.len + payload.len(), limit);
    }
    let written = write_response(s, &output.bytes[..output.len], payload).await;
    release(body);
    written?;
    input.drain(..end);
    Ok(!close)
}

// Fixed HTTP fields plus the status, encoding and Content-Length fit in 192 bytes.
struct Header {
    bytes: [u8; 192],
    len: usize,
}
impl Header {
    fn extend_from_slice(&mut self, b: &[u8]) {
        let end = self.len + b.len();
        self.bytes[self.len..end].copy_from_slice(b);
        self.len = end;
    }
}

struct Head {
    method: Method,
    target: std::ops::Range<usize>,
    auth: Option<std::ops::Range<usize>>,
    length: Option<usize>,
    chunked: bool,
    expect: bool,
    close: bool,
    gzip: bool,
    end: usize,
}
// Keep parser scratch space off the idle connection future.
fn parse_head(input: &[u8]) -> io::Result<Head> {
    let mut headers = [httparse::EMPTY_HEADER; 64];
    let mut req = httparse::Request::new(&mut headers);
    let head = match req.parse(input).map_err(|_| invalid())? {
        httparse::Status::Complete(n) if n <= MAX_HEAD => n,
        _ => return Err(invalid()),
    };
    let method =
        Method::from_bytes(req.method.ok_or_else(invalid)?.as_bytes()).map_err(|_| invalid())?;
    // Offsets allow the backing buffer to grow while a request body arrives.
    let target = req.path.ok_or_else(invalid)?;
    let target_range = (target.as_ptr() as usize - input.as_ptr() as usize)
        ..(target.as_ptr() as usize - input.as_ptr() as usize + target.len());
    let mut auth = None;
    let mut length = None;
    let mut chunked = false;
    let mut expect = false;
    let mut gzip = false;
    let mut close = req.version != Some(1);
    for h in req.headers.iter() {
        if h.name.eq_ignore_ascii_case("content-length") {
            if length.is_some() {
                return Err(invalid());
            }
            let v = std::str::from_utf8(h.value).map_err(|_| invalid())?;
            let n = crate::parse_uint(v).ok_or_else(invalid)? as usize;
            if n > MAX_BODY {
                return Err(invalid());
            }
            length = Some(n);
        } else if h.name.eq_ignore_ascii_case("transfer-encoding") {
            if chunked || !h.value.eq_ignore_ascii_case(b"chunked") {
                return Err(invalid());
            }
            chunked = true;
        } else if h.name.eq_ignore_ascii_case("authorization") {
            if auth.is_some() {
                return Err(invalid());
            }
            let start = h.value.as_ptr() as usize - input.as_ptr() as usize;
            auth = Some(start..start + h.value.len());
        } else if h.name.eq_ignore_ascii_case("connection") {
            if has_token(h.value, b"close") {
                close = true;
            } else if req.version == Some(0) && has_token(h.value, b"keep-alive") {
                close = false;
            }
        } else if h.name.eq_ignore_ascii_case("accept-encoding") {
            gzip |= accepts_gzip(h.value);
        } else if h.name.eq_ignore_ascii_case("expect") {
            if !h.value.eq_ignore_ascii_case(b"100-continue") {
                return Err(invalid());
            }
            expect = true;
        }
    }
    if length.is_some() && chunked {
        return Err(invalid());
    }
    Ok(Head {
        method,
        target: target_range,
        auth,
        length,
        chunked,
        expect,
        close,
        gzip,
        end: head,
    })
}

async fn write_response(s: &TcpStream, mut head: &[u8], mut body: &[u8]) -> io::Result<()> {
    while !head.is_empty() || !body.is_empty() {
        s.writable().await?;
        match s.try_write_vectored(&[io::IoSlice::new(head), io::IoSlice::new(body)]) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) if n < head.len() => head = &head[n..],
            Ok(n) => {
                body = &body[n - head.len()..];
                head = &[];
            }
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;
    #[tokio::test]
    #[ignore]
    async fn future_sizes() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut stream = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let mut input = Vec::new();
        eprintln!(
            "active request future: {} bytes",
            std::mem::size_of_val(&handle_one(&mut stream, &mut input))
        );
        eprintln!(
            "idle connection future: {} bytes",
            std::mem::size_of_val(&serve(stream))
        );
    }
    #[tokio::test]
    async fn chunk_framing_compacts_and_preserves_pipeline() {
        let payload = vec![b'x'; 3 * 1024 * 1024];
        let mut wire = b"POST /api/example HTTP/1.1\r\nTransfer-Encoding: chunked\r\nAuthorization: Token example\r\n\r\n".to_vec();
        for b in &payload {
            wire.extend_from_slice(&[b'1', b'\r', b'\n', *b, b'\r', b'\n']);
        }
        let pipeline = b"GET /api/tags HTTP/1.1\r\n\r\n";
        wire.extend_from_slice(b"0\r\nX-Trailer: present\r\n\r\n");
        wire.extend_from_slice(pipeline);
        for segment in [4096, 7777] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut client = TcpStream::connect(listener.local_addr().unwrap())
                .await
                .unwrap();
            let (mut server, _) = listener.accept().await.unwrap();
            let bytes = wire.clone();
            let sender = tokio::spawn(async move {
                for part in bytes.chunks(segment) {
                    client.write_all(part).await.unwrap();
                    tokio::task::yield_now().await;
                }
            });
            let mut input = Vec::new();
            let (head, body, end) = read_request(&mut server, &mut input).await.unwrap();
            assert_eq!(body, payload);
            assert_eq!(&input[head.target], b"/api/example");
            assert_eq!(&input[head.auth.unwrap()], b"Token example");
            assert!(input.len() < 128 * 1024);
            input.drain(..end);
            through(&mut server, &mut input, pipeline.len())
                .await
                .unwrap();
            assert_eq!(input, pipeline);
            sender.await.unwrap();
        }
    }
    #[test]
    fn egress_share_rises_over_the_limit_and_decays_otherwise() {
        let mut share = 0;
        for _ in 0..20 {
            share = egress::next_share(share, true, true);
        }
        assert_eq!(share, 256);
        assert_eq!(egress::next_share(share, true, false), 240);
        assert_eq!(egress::next_share(share, false, true), 240);
        assert_eq!(egress::next_share(0, true, false), 0);
    }

    #[test]
    fn accept_encoding() {
        for (v, ok) in [
            ("gzip", true),
            ("gzip, deflate, br", true),
            ("br;q=1.0, GZIP;q=0.5", true),
            ("*", true),
            ("gzip;q=0", false),
            ("gzip;q=0.000", false),
            ("deflate, br", false),
            ("identity", false),
            ("", false),
        ] {
            assert_eq!(accepts_gzip(v.as_bytes()), ok, "{v}");
        }
        let body = br#"{"articles":[{"slug":"a-b-c","title":"t"}],"articlesCount":1}"#.repeat(40);
        let z = gzip(&body).expect("smaller");
        let mut d = libdeflater::Decompressor::new();
        let mut out = vec![0; body.len()];
        assert_eq!(d.gzip_decompress(&z, &mut out).unwrap(), body.len());
        assert_eq!(out, body);
    }

    #[test]
    fn reject_ambiguous_framing() {
        for head in [
            "POST /api/users HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
            "POST /api/users HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /api/users HTTP/1.1\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
            "POST /api/users HTTP/1.1\r\nContent-Length: +2\r\n\r\n",
        ] {
            assert!(parse_head(head.as_bytes()).is_err());
        }
    }
    #[test]
    fn preserve_empty_authorization() {
        let b = b"GET /api/articles HTTP/1.1\r\nAuthorization:\r\n\r\n";
        let h = parse_head(b).unwrap();
        assert_eq!(h.auth.map(|r| &b[r]), Some(&b""[..]));
    }
}
