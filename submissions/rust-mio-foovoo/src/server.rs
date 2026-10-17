//! One event loop per thread: its own SO_REUSEPORT listener, its own clients and its own Postgres connections, all on
//! one mio `Poll` (epoll, edge-triggered). Nothing is shared between loops except the bcrypt pool.
//!
//! A client connection handles one request at a time. While a request is in flight the socket is not read (the
//! kernel buffers anything else the client sends), and after the response is written the loop goes back to the
//! connection to look for the next request, since an edge-triggered socket won't report bytes that already arrived.

use std::io::{self, Read, Write};
use std::net::SocketAddr;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use mio::net::{TcpListener, TcpStream};
use mio::{Events, Interest, Poll, Token};

use crate::auth::Jwt;
use crate::handlers::{self, Cont, Ctx, Kind, Next, Outcome, Req};
use crate::pg::{self, GroupResult, PgConfig, PgConn, PipeStats, Policy};
use crate::pool::{BcryptPool, Inbox, Task};
use crate::util::{http_date, unix_now};

const LISTENER: Token = Token(usize::MAX - 1);
const WAKER: Token = Token(usize::MAX - 2);
const PG_BASE: usize = 1 << 40;

const MAX_HEADER_BYTES: usize = 16 * 1024;
const MAX_BODY_BYTES: usize = 256 * 1024;
/// Far above what the box can serve (an idle connection costs ~100 bytes here plus the kernel's socket); only a guard.
const MAX_CLIENTS_PER_LOOP: usize = 1 << 20;
const MAX_PENDING_PER_PG: usize = 4096;
/// Per-loop read buffer: a request is parsed straight out of it, so idle connections own no buffer.
const READ_CHUNK: usize = 16 * 1024;

pub struct Shared {
    /// Seconds between per-loop stats lines on stdout; 0 = off.
    pub stats_secs: u64,
    pub route: Route,
    /// Most groups sharing one Sync on a read connection; 1 = one Sync per group.
    pub read_batch: usize,
    /// Most groups sharing one commit on a write connection; 1 = one Sync per group, pipelined.
    pub write_batch: usize,
    pub jwt: Jwt,
    pub bcrypt: Arc<BcryptPool>,
    pub pg: PgConfig,
}

/// How a read picks among the read connections.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Route {
    /// Least estimated work (sum of per-statement costs) queued: a feed counts six times a point read.
    LeastWork,
    /// Fewest groups queued.
    LeastCount,
}

/// A loop's prepared resources, created on the main thread before any listener is bound.
pub struct LoopSetup {
    pub poll: Poll,
    pub inbox: Arc<Inbox>,
    /// (kind, connected stream) per Postgres connection.
    pub pgs: Vec<(Kind, std::net::TcpStream)>,
}

impl LoopSetup {
    pub fn new(pgs: Vec<(Kind, std::net::TcpStream)>) -> io::Result<LoopSetup> {
        let poll = Poll::new()?;
        let waker = mio::Waker::new(poll.registry(), WAKER)?;
        let inbox = Arc::new(Inbox { bcrypt: Default::default(), reconnected: Default::default(), waker });
        Ok(LoopSetup { poll, inbox, pgs })
    }
}

struct Client {
    stream: TcpStream,
    epoch: u32,
    inbuf: Vec<u8>,
    outbuf: Vec<u8>,
    out_pos: usize,
    /// A request is being served (waiting on Postgres/bcrypt, or its response is still being written).
    busy: bool,
    /// The socket may hold unread bytes: set on a readable event while busy, or when we stopped reading early.
    read_pending: bool,
    close_after: bool,
    writing: bool,
    cont: Option<Cont>,
    cancel: Option<Arc<AtomicBool>>,
    /// Bytes of `inbuf` still unparsed after the request just taken from it (set by apply_parsed).
    inbuf_keep: usize,
    /// When the current request was parsed (service time = parse to response written into the socket).
    started: Instant,
}

/// Per-loop counters for the stats line; reset after every line.
struct Stats {
    since: Instant,
    by_class: [u64; 6],
    /// Service-time histogram: 4 buckets per power of two of microseconds.
    lat: [u32; 160],
    lat_max_us: u64,
    groups: u64,
    accepted: u64,
}

impl Stats {
    fn new() -> Stats {
        Stats { since: Instant::now(), by_class: [0; 6], lat: [0; 160], lat_max_us: 0, groups: 0, accepted: 0 }
    }

    fn record(&mut self, status: u16, us: u64) {
        self.by_class[(status / 100).min(5) as usize] += 1;
        let us = us.max(1);
        let log = 63 - us.leading_zeros() as usize;
        let sub = if log >= 2 { (us >> (log - 2)) & 3 } else { 0 } as usize;
        self.lat[(log * 4 + sub).min(159)] += 1;
        self.lat_max_us = self.lat_max_us.max(us);
    }

    /// Upper bound of the bucket holding quantile `q`, in microseconds.
    fn quantile(&self, q: f64) -> u64 {
        let total: u64 = self.lat.iter().map(|&n| n as u64).sum();
        if total == 0 {
            return 0;
        }
        let target = (total as f64 * q).ceil() as u64;
        let mut seen = 0;
        for (i, &n) in self.lat.iter().enumerate() {
            seen += n as u64;
            if seen >= target {
                let (log, sub) = (i / 4, (i % 4) as u64);
                return if log >= 2 { (4 + sub + 1) << (log - 2) } else { 1 << (log + 1) };
            }
        }
        self.lat_max_us
    }
}

struct PgSlot {
    kind: Kind,
    conn: Option<PgConn>,
    dirty: bool,
    writable: bool,
}

struct Loop {
    id: usize,
    poll: Poll,
    listener: TcpListener,
    accept_paused: bool,
    clients: Vec<Option<Client>>,
    epochs: Vec<u32>,
    free: Vec<usize>,
    live: usize,
    runnable: Vec<(usize, u32)>,
    pgs: Vec<PgSlot>,
    inbox: Arc<Inbox>,
    shared: &'static Shared,
    done: Vec<(u64, GroupResult)>,
    scratch: Vec<u8>,
    out: Vec<u8>,
    wbuf: Vec<u8>,
    stats: Stats,
    /// Postgres batch counters at the last stats line.
    pg_prev: PipeStats,
    date: Vec<u8>,
    date_sec: i64,
    now: i64,
}

pub fn bind(addr: SocketAddr) -> io::Result<TcpListener> {
    use socket2::{Domain, Protocol, Socket, Type};
    let s = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP))?;
    s.set_reuse_address(true)?;
    #[cfg(unix)]
    s.set_reuse_port(true)?;
    s.set_tcp_nodelay(true)?;
    s.set_nonblocking(true)?;
    s.bind(&addr.into())?;
    s.listen(65_535)?;
    Ok(TcpListener::from_std(s.into()))
}

/// Batching for a connection of `kind` (see `pg::Policy`).
fn policy(kind: Kind, shared: &Shared) -> Policy {
    match kind {
        Kind::Write if shared.write_batch > 1 => Policy::Write { cap: shared.write_batch },
        Kind::Write => Policy::Read { cap: 1 },
        Kind::Read | Kind::Heavy => Policy::Read { cap: shared.read_batch.max(1) },
    }
}

pub fn run(id: usize, setup: LoopSetup, mut listener: TcpListener, shared: &'static Shared) {
    let LoopSetup { poll, inbox, pgs } = setup;
    poll.registry().register(&mut listener, LISTENER, Interest::READABLE).expect("register listener");
    let mut lp = Loop {
        id,
        poll,
        listener,
        accept_paused: false,
        clients: Vec::new(),
        epochs: Vec::new(),
        free: Vec::new(),
        live: 0,
        runnable: Vec::new(),
        pgs: Vec::new(),
        inbox,
        shared,
        done: Vec::new(),
        scratch: vec![0; READ_CHUNK],
        out: Vec::with_capacity(16 * 1024),
        wbuf: Vec::with_capacity(16 * 1024),
        stats: Stats::new(),
        pg_prev: PipeStats::default(),
        date: Vec::new(),
        date_sec: 0,
        now: 0,
    };
    for (i, (kind, stream)) in pgs.into_iter().enumerate() {
        let mut conn = PgConn::from_std(stream, policy(kind, shared));
        lp.poll.registry().register(&mut conn.stream, Token(PG_BASE + i), Interest::READABLE).expect("register pg");
        lp.pgs.push(PgSlot { kind, conn: Some(conn), dirty: false, writable: false });
    }
    lp.event_loop();
}

impl Loop {
    fn event_loop(&mut self) {
        let mut events = Events::with_capacity(1024);
        loop {
            let mut timeout = self.accept_paused.then(|| Duration::from_millis(100));
            if self.shared.stats_secs > 0 {
                let next = Duration::from_secs(self.shared.stats_secs).saturating_sub(self.stats.since.elapsed());
                timeout = Some(timeout.map_or(next, |t| t.min(next)));
            }
            if let Err(e) = self.poll.poll(&mut events, timeout) {
                if e.kind() != io::ErrorKind::Interrupted {
                    eprintln!("[loop {}] poll: {e}", self.id);
                }
                continue;
            }
            self.tick_clock();
            if self.accept_paused {
                self.accept_paused = false;
                self.accept();
            }
            for (n, ev) in events.iter().enumerate() {
                // Under load an iteration holds hundreds of events; send queued statements as we go instead of
                // making the first request of the batch wait for the last one to be parsed.
                if n % 16 == 15 {
                    self.flush_pgs();
                }
                match ev.token() {
                    LISTENER => self.accept(),
                    WAKER => self.drain_inbox(),
                    Token(t) if t >= PG_BASE => self.pg_event(t - PG_BASE, ev.is_readable(), ev.is_writable()),
                    Token(i) => self.client_event(i, ev.is_readable() || ev.is_read_closed() || ev.is_error(), ev.is_writable()),
                }
            }
            while let Some((i, epoch)) = self.runnable.pop() {
                if self.client(i, epoch).is_some_and(|c| !c.busy) {
                    self.read_client(i);
                }
            }
            self.flush_pgs();
            if self.shared.stats_secs > 0 && self.stats.since.elapsed().as_secs() >= self.shared.stats_secs {
                self.print_stats();
            }
        }
    }

    /// One line per loop: traffic, service-time quantiles, Postgres pipeline depth and bcrypt backlog.
    fn print_stats(&mut self) {
        let s = &self.stats;
        let secs = s.since.elapsed().as_secs_f64().max(0.001);
        let done: u64 = s.by_class.iter().sum();
        let (mut live_pg, mut total) = (0, PipeStats::default());
        // Per connection: queued groups / held groups / estimated queued work in ms ("-" = down).
        let mut per_pg = String::new();
        for slot in &self.pgs {
            let tag = if slot.kind == Kind::Write { 'w' } else { 'r' };
            match &slot.conn {
                Some(c) => {
                    live_pg += 1;
                    per_pg.push_str(&format!(" {tag}{}/{}/{}", c.queued(), c.held(), c.work_us() / 1000));
                    total.batches += c.stats.batches;
                    total.batched += c.stats.batched;
                    total.retries += c.stats.retries;
                }
                None => per_pg.push_str(&format!(" {tag}-")),
            }
        }
        let prev = std::mem::replace(&mut self.pg_prev, total);
        let batches = total.batches.saturating_sub(prev.batches);
        let batched = total.batched.saturating_sub(prev.batched);
        let batch_size =
            if batches == 0 { "-".to_string() } else { format!("{:.1}", batched as f64 / batches as f64) };
        println!(
            "[stats L{}] t={} conns={} new={} rps={:.0} 2xx={} 4xx={} 5xx={} svc_us p50={} p90={} p99={} max={} \
             pg_live={}/{} pg=[{} ] batches={} batch_size={} batch_retries={} groups={} bcrypt_q={}",
            self.id,
            self.now,
            self.live,
            s.accepted,
            done as f64 / secs,
            s.by_class[2],
            s.by_class[4],
            s.by_class[5],
            s.quantile(0.50),
            s.quantile(0.90),
            s.quantile(0.99),
            s.lat_max_us,
            live_pg,
            self.pgs.len(),
            per_pg,
            batches,
            batch_size,
            total.retries.saturating_sub(prev.retries),
            s.groups,
            self.shared.bcrypt.queue_len(),
        );
        self.stats = Stats::new();
    }

    fn tick_clock(&mut self) {
        let (secs, _) = unix_now();
        self.now = secs;
        if secs != self.date_sec {
            self.date_sec = secs;
            self.date.clear();
            http_date(secs, &mut self.date);
        }
    }

    fn client(&mut self, i: usize, epoch: u32) -> Option<&mut Client> {
        self.clients.get_mut(i)?.as_mut().filter(|c| c.epoch == epoch)
    }

    // ------------------------------------------------------------ accept / close

    fn accept(&mut self) {
        loop {
            match self.listener.accept() {
                Ok((mut stream, _)) => {
                    if self.live >= MAX_CLIENTS_PER_LOOP {
                        continue; // dropped: closes the socket
                    }
                    let _ = stream.set_nodelay(true);
                    let i = self.free.pop().unwrap_or_else(|| {
                        self.clients.push(None);
                        self.epochs.push(0);
                        self.clients.len() - 1
                    });
                    if self.poll.registry().register(&mut stream, Token(i), Interest::READABLE).is_err() {
                        self.free.push(i);
                        continue;
                    }
                    self.clients[i] = Some(Client {
                        stream,
                        epoch: self.epochs[i],
                        inbuf: Vec::new(),
                        outbuf: Vec::new(),
                        out_pos: 0,
                        busy: false,
                        read_pending: true,
                        close_after: false,
                        writing: false,
                        cont: None,
                        cancel: None,
                        inbuf_keep: 0,
                        started: Instant::now(),
                    });
                    self.live += 1;
                    self.stats.accepted += 1;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return,
                Err(e) if matches!(e.kind(), io::ErrorKind::ConnectionAborted | io::ErrorKind::ConnectionReset | io::ErrorKind::Interrupted) => {}
                Err(e) => {
                    // EMFILE/ENFILE/ENOBUFS: the listener won't signal again (edge-triggered), so retry on a timer.
                    eprintln!("[loop {}] accept: {e}", self.id);
                    self.accept_paused = true;
                    return;
                }
            }
        }
    }

    fn close(&mut self, i: usize) {
        if let Some(mut c) = self.clients[i].take() {
            let _ = self.poll.registry().deregister(&mut c.stream);
            if let Some(flag) = c.cancel.take() {
                flag.store(true, Ordering::Relaxed);
            }
            self.epochs[i] = self.epochs[i].wrapping_add(1);
            self.free.push(i);
            self.live -= 1;
        }
    }

    // ------------------------------------------------------------ client I/O

    fn client_event(&mut self, i: usize, readable: bool, writable: bool) {
        let Some(c) = self.clients.get_mut(i).and_then(Option::as_mut) else { return };
        if writable && c.writing {
            self.flush_client(i);
        }
        let Some(c) = self.clients.get_mut(i).and_then(Option::as_mut) else { return };
        if readable {
            if c.busy {
                c.read_pending = true;
            } else {
                self.read_client(i);
            }
        }
    }

    /// Reads until one complete request is parsed (then dispatches it) or the socket has nothing more.
    ///
    /// A fresh request is read into the loop's scratch buffer and parsed in place. Only an incomplete request, or bytes
    /// after a complete one, are copied into the connection's own `inbuf`; once `inbuf` holds anything, later reads are
    /// appended to it and parsed from there.
    fn read_client(&mut self, i: usize) {
        loop {
            if self.clients[i].as_ref().is_some_and(|c| !c.inbuf.is_empty()) {
                match self.try_request(i) {
                    Step::Dispatched | Step::Closed => return,
                    Step::Incomplete => {}
                }
            }
            let Some(c) = self.clients[i].as_mut() else { return };
            let n = match c.stream.read(&mut self.scratch) {
                Ok(0) => return self.close(i),
                Ok(n) => n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => {
                    c.read_pending = false;
                    if c.inbuf.is_empty() {
                        c.inbuf = Vec::new();
                    }
                    return;
                }
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return self.close(i),
            };
            // A short read drained the socket; only a full one can leave bytes behind (edge-triggered).
            c.read_pending = n == READ_CHUNK;
            if !c.inbuf.is_empty() {
                c.inbuf.extend_from_slice(&self.scratch[..n]);
                continue;
            }
            let epoch = c.epoch;
            let scratch = std::mem::take(&mut self.scratch);
            let parsed = self.parse_and_start(&scratch[..n]);
            let step = self.apply_parsed(i, epoch, parsed, &scratch[..n], false);
            self.scratch = scratch;
            match step {
                Step::Dispatched | Step::Closed => return,
                Step::Incomplete => {}
            }
        }
    }

    /// Parses the connection's buffered bytes (a partial or pipelined request).
    fn try_request(&mut self, i: usize) -> Step {
        let Some(c) = self.clients[i].as_mut() else { return Step::Closed };
        let epoch = c.epoch;
        let inbuf = std::mem::take(&mut c.inbuf);
        let parsed = self.parse_and_start(&inbuf);
        let step = self.apply_parsed(i, epoch, parsed, &inbuf, true);
        if let Some(c) = self.client(i, epoch) {
            // Keep what wasn't consumed: all of it if incomplete, the remainder after a request otherwise.
            let keep = match step {
                Step::Incomplete => inbuf.len(),
                _ => c.inbuf_keep,
            };
            if keep > 0 {
                let mut inbuf = inbuf;
                inbuf.drain(..inbuf.len() - keep);
                c.inbuf = inbuf;
            }
            c.inbuf_keep = 0;
        }
        step
    }

    /// Acts on a parse of `buf`. From the scratch buffer (`owned == false`) unconsumed bytes are copied into the
    /// connection's `inbuf`; from `inbuf` itself, `try_request` trims it using `inbuf_keep`.
    fn apply_parsed(&mut self, i: usize, epoch: u32, parsed: Parsed, buf: &[u8], owned: bool) -> Step {
        let Some(c) = self.client(i, epoch) else { return Step::Closed };
        match parsed {
            Parsed::Incomplete => {
                if !owned {
                    c.inbuf.extend_from_slice(buf);
                }
                Step::Incomplete
            }
            Parsed::Reject(status) => {
                c.busy = true;
                c.close_after = true;
                c.inbuf_keep = 0;
                self.respond(i, status);
                Step::Dispatched
            }
            Parsed::Request { consumed, close_after, next } => {
                let rest = &buf[consumed..];
                if owned {
                    c.inbuf_keep = rest.len();
                } else if !rest.is_empty() {
                    c.inbuf.extend_from_slice(rest);
                }
                c.busy = true;
                c.close_after = close_after;
                c.started = Instant::now();
                self.dispatch(i, next);
                Step::Dispatched
            }
        }
    }

    fn parse_and_start(&mut self, buf: &[u8]) -> Parsed {
        let mut headers = [httparse::EMPTY_HEADER; 32];
        let mut req = httparse::Request::new(&mut headers);
        let hlen = match req.parse(buf) {
            Ok(httparse::Status::Complete(n)) => n,
            Ok(httparse::Status::Partial) if buf.len() > MAX_HEADER_BYTES => return Parsed::reject(&mut self.out, 431),
            Ok(httparse::Status::Partial) => return Parsed::Incomplete,
            Err(_) => return Parsed::reject(&mut self.out, 400),
        };
        let mut content_length = 0usize;
        let mut auth = None;
        let mut close_after = req.version == Some(0);
        for h in req.headers.iter() {
            if h.name.eq_ignore_ascii_case("content-length") {
                match std::str::from_utf8(h.value).ok().and_then(|v| v.trim().parse::<usize>().ok()) {
                    Some(n) => content_length = n,
                    None => return Parsed::reject(&mut self.out, 400),
                }
            } else if h.name.eq_ignore_ascii_case("authorization") {
                auth.get_or_insert(h.value);
            } else if h.name.eq_ignore_ascii_case("transfer-encoding") {
                return Parsed::reject(&mut self.out, 501);
            } else if h.name.eq_ignore_ascii_case("connection") {
                if h.value.eq_ignore_ascii_case(b"close") {
                    close_after = true;
                } else if h.value.eq_ignore_ascii_case(b"keep-alive") {
                    close_after = false;
                }
            }
        }
        if content_length > MAX_BODY_BYTES {
            return Parsed::reject(&mut self.out, 413);
        }
        if buf.len() < hlen + content_length {
            return Parsed::Incomplete;
        }
        let target = req.path.unwrap_or("/");
        let (path, query) = target.split_once('?').unwrap_or((target, ""));
        let request = Req { method: req.method.unwrap_or(""), path, query, auth, body: &buf[hlen..hlen + content_length] };
        let ctx = Ctx { jwt: &self.shared.jwt, now: self.now };
        let out = &mut self.out;
        let next = guarded(out, |out| handlers::start(&ctx, &request, out));
        Parsed::Request { consumed: hlen + content_length, close_after, next }
    }

    fn dispatch(&mut self, i: usize, next: Next) {
        let Some(epoch) = self.clients[i].as_ref().map(|c| c.epoch) else { return };
        match next {
            Next::Respond(status) => self.respond(i, status),
            Next::Db(kind, group, cont) => {
                let Some(p) = self.pick_pg(kind) else {
                    handlers::fail(&mut self.out, 503, "database unavailable");
                    return self.respond(i, 503);
                };
                let slot = &mut self.pgs[p];
                let conn = slot.conn.as_mut().expect("picked a live connection");
                if conn.queued() >= MAX_PENDING_PER_PG {
                    handlers::fail(&mut self.out, 503, "server busy");
                    return self.respond(i, 503);
                }
                conn.submit(&group, (i as u64) << 32 | epoch as u64, kind == Kind::Write);
                slot.dirty = true;
                self.stats.groups += 1;
                if let Some(c) = self.clients[i].as_mut() {
                    c.cont = Some(cont);
                }
            }
            Next::Bcrypt(job, cont) => {
                let cancelled = Arc::new(AtomicBool::new(false));
                let task = Task { job, inbox: self.inbox.clone(), conn: (i, epoch), cancelled: cancelled.clone() };
                if self.shared.bcrypt.submit(task).is_err() {
                    handlers::fail(&mut self.out, 503, "server busy");
                    return self.respond(i, 503);
                }
                if let Some(c) = self.clients[i].as_mut() {
                    c.cont = Some(cont);
                    c.cancel = Some(cancelled);
                }
            }
        }
    }

    /// Sends `self.out` as the body of a response with `status`.
    fn respond(&mut self, i: usize, status: u16) {
        let Some(c) = self.clients[i].as_mut() else { return };
        if self.shared.stats_secs > 0 {
            self.stats.record(status, c.started.elapsed().as_micros() as u64);
        }
        let w = &mut self.wbuf;
        w.clear();
        w.extend_from_slice(b"HTTP/1.1 ");
        w.extend_from_slice(itoa::Buffer::new().format(status).as_bytes());
        w.push(b' ');
        w.extend_from_slice(reason(status));
        if status == 204 {
            w.extend_from_slice(b"\r\n");
        } else {
            w.extend_from_slice(b"\r\nContent-Type: application/json\r\nContent-Length: ");
            w.extend_from_slice(itoa::Buffer::new().format(self.out.len()).as_bytes());
            w.extend_from_slice(b"\r\n");
        }
        w.extend_from_slice(b"Date: ");
        w.extend_from_slice(&self.date);
        if c.close_after {
            w.extend_from_slice(b"\r\nConnection: close");
        }
        w.extend_from_slice(b"\r\n\r\n");
        let body: &[u8] = if status == 204 { &[] } else { &self.out };
        let total = w.len() + body.len();
        // Header and body go out in one writev; nearly always completely.
        let mut pos = 0;
        while pos < total {
            let res = if pos < w.len() {
                c.stream.write_vectored(&[io::IoSlice::new(&w[pos..]), io::IoSlice::new(body)])
            } else {
                c.stream.write(&body[pos - w.len()..])
            };
            match res {
                Ok(0) => return self.close(i),
                Ok(n) => pos += n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return self.close(i),
            }
        }
        if pos == total {
            return self.finish(i);
        }
        let mut rest = Vec::with_capacity(total - pos);
        if pos < w.len() {
            rest.extend_from_slice(&w[pos..]);
            rest.extend_from_slice(body);
        } else {
            rest.extend_from_slice(&body[pos - w.len()..]);
        }
        c.outbuf = rest;
        c.out_pos = 0;
        c.writing = true;
        if self.poll.registry().reregister(&mut c.stream, Token(i), Interest::READABLE | Interest::WRITABLE).is_err() {
            self.close(i);
        }
    }

    fn flush_client(&mut self, i: usize) {
        let Some(c) = self.clients[i].as_mut() else { return };
        while c.out_pos < c.outbuf.len() {
            match c.stream.write(&c.outbuf[c.out_pos..]) {
                Ok(0) => return self.close(i),
                Ok(n) => c.out_pos += n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => return self.close(i),
            }
        }
        c.outbuf = Vec::new();
        c.out_pos = 0;
        c.writing = false;
        if self.poll.registry().reregister(&mut c.stream, Token(i), Interest::READABLE).is_err() {
            return self.close(i);
        }
        self.finish(i);
    }

    /// The response is fully written: close, or queue the connection to look for its next request.
    fn finish(&mut self, i: usize) {
        let Some(c) = self.clients[i].as_mut() else { return };
        c.busy = false;
        c.cont = None;
        c.cancel = None;
        if c.close_after {
            return self.close(i);
        }
        if c.read_pending || !c.inbuf.is_empty() {
            self.runnable.push((i, c.epoch));
        }
    }

    // ------------------------------------------------------------ completions

    fn resume(&mut self, i: usize, epoch: u32, outcome: Outcome) {
        let Some(c) = self.client(i, epoch) else { return }; // client went away; drop the continuation
        let Some(cont) = c.cont.take() else { return };
        c.cancel = None;
        let ctx = Ctx { jwt: &self.shared.jwt, now: self.now };
        let next = guarded(&mut self.out, |out| handlers::resume(&ctx, cont, outcome, out));
        self.dispatch(i, next);
    }

    fn complete_groups(&mut self) {
        let mut done = std::mem::take(&mut self.done);
        for (tag, res) in done.drain(..) {
            self.resume((tag >> 32) as usize, tag as u32, Outcome::Db(res));
        }
        self.done = done;
    }

    fn drain_inbox(&mut self) {
        let finished = std::mem::take(&mut *self.inbox.bcrypt.lock().unwrap());
        for ((i, epoch), result) in finished {
            self.resume(i, epoch, Outcome::Bcrypt(result));
        }
        let reconnected = std::mem::take(&mut *self.inbox.reconnected.lock().unwrap());
        for (p, stream) in reconnected {
            let mut conn = PgConn::from_std(stream, policy(self.pgs[p].kind, self.shared));
            if self.poll.registry().register(&mut conn.stream, Token(PG_BASE + p), Interest::READABLE).is_ok() {
                eprintln!("[loop {}] postgres connection {p} restored", self.id);
                let slot = &mut self.pgs[p];
                slot.conn = Some(conn);
                slot.writable = false;
                slot.dirty = false;
            }
        }
    }

    // ------------------------------------------------------------ Postgres connections

    /// The least-loaded live connection of the group's side: writes on the write connections, every read (feed and
    /// lists included) on one pool of read connections. Mixing heavy and light reads keeps every connection's drain
    /// time equal; a dedicated heavy connection drained ~3x slower than the others at saturation. A side that is down
    /// falls back to the other one.
    fn pick_pg(&self, kind: Kind) -> Option<usize> {
        let route = self.shared.route;
        let best = |write: bool| {
            self.pgs
                .iter()
                .enumerate()
                .filter_map(|(p, s)| Some((p, s.conn.as_ref()?, s.kind == Kind::Write)))
                .filter(|&(_, _, w)| w == write)
                .min_by_key(|&(_, c, _)| match route {
                    Route::LeastWork => (c.work_us(), c.queued()),
                    Route::LeastCount => (c.queued() as u64, 0),
                })
                .map(|(p, _, _)| p)
        };
        let write = kind == Kind::Write;
        best(write).or_else(|| best(!write))
    }

    fn pg_event(&mut self, p: usize, readable: bool, writable: bool) {
        let Some(slot) = self.pgs.get_mut(p) else { return };
        let Some(conn) = slot.conn.as_mut() else { return };
        if writable {
            if let Err(e) = conn.flush() {
                return self.pg_lost(p, &e.to_string());
            }
            if !conn.has_output() && slot.writable {
                slot.writable = false;
                let _ = self.poll.registry().reregister(&mut conn.stream, Token(PG_BASE + p), Interest::READABLE);
            }
        }
        if readable {
            let res = conn.read_ready(&mut self.done);
            // A resend or a released write batch was queued while parsing: send it with this iteration's output.
            if let Ok(true) = res {
                slot.dirty = true;
            }
            self.complete_groups();
            if let Err(e) = res {
                return self.pg_lost(p, &e.to_string());
            }
        }
    }

    /// Sends everything queued this iteration: one write per connection carries all of its new groups.
    fn flush_pgs(&mut self) {
        for p in 0..self.pgs.len() {
            let slot = &mut self.pgs[p];
            if !slot.dirty {
                continue;
            }
            slot.dirty = false;
            let Some(conn) = slot.conn.as_mut() else { continue };
            if let Err(e) = conn.flush() {
                self.pg_lost(p, &e.to_string());
                continue;
            }
            if conn.has_output() && !slot.writable {
                slot.writable = true;
                let _ = self.poll.registry().reregister(
                    &mut conn.stream,
                    Token(PG_BASE + p),
                    Interest::READABLE | Interest::WRITABLE,
                );
            }
        }
    }

    /// Fails the connection's in-flight groups and reconnects it in the background; the loop keeps serving on its
    /// other connections meanwhile.
    fn pg_lost(&mut self, p: usize, why: &str) {
        let Some(mut conn) = self.pgs[p].conn.take() else { return };
        eprintln!("[loop {}] postgres connection {p} lost: {why}", self.id);
        let _ = self.poll.registry().deregister(&mut conn.stream);
        conn.fail_all(&mut self.done, why);
        self.complete_groups();
        let cfg = self.shared.pg.clone();
        let inbox = self.inbox.clone();
        std::thread::spawn(move || {
            loop {
                match pg::connect(&cfg, Instant::now() + Duration::from_secs(30)) {
                    Ok(stream) => {
                        inbox.reconnected.lock().unwrap().push((p, stream));
                        let _ = inbox.waker.wake();
                        return;
                    }
                    Err(e) => eprintln!("[pg] reconnect of connection {p} failed: {e}"),
                }
            }
        });
    }
}

enum Step {
    Dispatched,
    Incomplete,
    Closed,
}

enum Parsed {
    Incomplete,
    Reject(u16),
    Request { consumed: usize, close_after: bool, next: Next },
}

impl Parsed {
    fn reject(out: &mut Vec<u8>, status: u16) -> Parsed {
        handlers::fail(out, status, "bad request");
        Parsed::Reject(status)
    }
}

/// Runs a handler step; a panic becomes a 500 for that request instead of taking the server down.
fn guarded(out: &mut Vec<u8>, f: impl FnOnce(&mut Vec<u8>) -> Next) -> Next {
    match catch_unwind(AssertUnwindSafe(|| f(out))) {
        Ok(next) => next,
        Err(_) => handlers::fail(out, 500, "internal error"),
    }
}

fn reason(status: u16) -> &'static [u8] {
    match status {
        200 => b"OK",
        201 => b"Created",
        204 => b"No Content",
        400 => b"Bad Request",
        401 => b"Unauthorized",
        403 => b"Forbidden",
        404 => b"Not Found",
        413 => b"Content Too Large",
        422 => b"Unprocessable Entity",
        431 => b"Request Header Fields Too Large",
        501 => b"Not Implemented",
        503 => b"Service Unavailable",
        _ => b"Internal Server Error",
    }
}
