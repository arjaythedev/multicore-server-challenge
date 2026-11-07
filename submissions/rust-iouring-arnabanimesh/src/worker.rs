//! One io_uring event loop per worker thread (thread-per-core, share-nothing):
//!
//!   accept (multishot) -> recv (multishot, provided buffers) -> parse HTTP -> route
//!     -> encode ONE pipelined Postgres batch -> (flush) -> read results -> render JSON -> send
//!
//! The only cross-thread traffic is the bcrypt pool (hash/verify jobs and an eventfd wake-up).

use std::borrow::Cow;
use std::io;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};

use crossbeam_channel::{Receiver, Sender};
use serde_json::{Map, Value};

use crate::auth::{AuthState, Jwt};
use crate::bcrypt_pool::{BJob, BOut};
use crate::http::{self, Method, Parsed, Req};
use crate::json::{self, Field};
use crate::pg::{self, PgConn, Scan};
use crate::render::{self, Done, Kind};
use crate::sql;
use crate::uring::{self, Cqe, Ring};

const T_ACCEPT: u64 = 1;
const T_RECV: u64 = 2;
const T_SEND: u64 = 3;
const T_PGRECV: u64 = 4;
const T_PGSEND: u64 = 5;
const T_EVENTFD: u64 = 6;

pub const BGID: u16 = 1;
pub const BUF_COUNT: u32 = 4096;
pub const BUF_SIZE: u32 = 2048;

/// Space reserved in front of every response body for the HTTP head (written last, right-aligned).
const HDR_RESERVE: usize = 160;
const MAX_REQ: usize = 2 * 1024 * 1024;
const GEN_MASK: u32 = 0x00FF_FFFF;

static ERR_LOGS: AtomicUsize = AtomicUsize::new(0);

#[inline]
fn ud(tag: u64, gid: u32, idx: u32) -> u64 {
    (tag << 56) | (((gid & GEN_MASK) as u64) << 32) | idx as u64
}

fn unix_now() -> i64 {
    match std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH) {
        Ok(d) => d.as_secs() as i64,
        Err(_) => 0,
    }
}

// ---------------------------------------------------------------------------- listener

/// Non-blocking SO_REUSEPORT listener: every worker owns one, the kernel spreads connections.
pub fn create_listener(addr: SocketAddr) -> io::Result<i32> {
    let v4 = match addr {
        SocketAddr::V4(a) => a,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "HOST must be an IPv4 address",
            ))
        }
    };
    unsafe {
        let fd = libc::socket(
            libc::AF_INET,
            libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
            0,
        );
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let one: libc::c_int = 1;
        let optlen = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        let p = &one as *const libc::c_int as *const libc::c_void;
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEADDR, p, optlen);
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_REUSEPORT, p, optlen);
        libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, p, optlen);

        let mut sin: libc::sockaddr_in = std::mem::zeroed();
        sin.sin_family = libc::AF_INET as libc::sa_family_t;
        sin.sin_port = v4.port().to_be();
        sin.sin_addr = libc::in_addr {
            s_addr: u32::from_ne_bytes(v4.ip().octets()),
        };
        let rc = libc::bind(
            fd,
            &sin as *const libc::sockaddr_in as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t,
        );
        if rc < 0 {
            let e = io::Error::last_os_error();
            libc::close(fd);
            return Err(e);
        }
        if libc::listen(fd, 16384) < 0 {
            let e = io::Error::last_os_error();
            libc::close(fd);
            return Err(e);
        }
        Ok(fd)
    }
}

// ---------------------------------------------------------------------------- state

pub enum HashAction {
    Register {
        username: String,
        email: String,
    },
    UpdateUser {
        email: Option<String>,
        username: Option<String>,
        bio: Option<String>,
        image: Option<String>,
    },
}

pub struct LoginCtx {
    id: i64,
    username: String,
    email: String,
    bio: Option<String>,
    image: Option<String>,
}

/// What a client connection is waiting for.
pub enum Pending {
    None,
    Db(Kind),
    Hash(HashAction),
    Verify(LoginCtx),
}

pub struct Conn {
    fd: i32,
    gid: u32,
    in_use: bool,
    recv_active: bool,
    send_active: bool,
    closing: bool,
    close_after_send: bool,
    /// A request is being processed (until its response is completely sent).
    busy: bool,
    keep_alive: bool,
    viewer: i64,
    /// Bytes of a partial (or pipelined) request.
    inbuf: Vec<u8>,
    /// Response being sent (pooled buffer; head is right-aligned in front of the body).
    out: Vec<u8>,
    out_off: usize,
    /// The token presented by the client (echoed by GET/PUT /api/user).
    token: Vec<u8>,
    /// Plaintext login password while the user row is being fetched.
    secret: String,
    pending: Pending,
}

impl Conn {
    fn new() -> Conn {
        Conn {
            fd: -1,
            gid: 0,
            in_use: false,
            recv_active: false,
            send_active: false,
            closing: false,
            close_after_send: false,
            busy: false,
            keep_alive: true,
            viewer: 0,
            inbuf: Vec::new(),
            out: Vec::new(),
            out_off: 0,
            token: Vec::new(),
            secret: String::new(),
            pending: Pending::None,
        }
    }
}

enum Outcome {
    Incomplete,
    Consumed(usize),
}

pub struct Worker {
    id: usize,
    ring: Ring,
    listen_fd: i32,
    conns: Vec<Conn>,
    free: Vec<u32>,
    pgs: Vec<PgConn>,
    pool: Vec<Vec<u8>>,
    scan: Scan,
    jwt: Jwt,
    jobs: Sender<BJob>,
    results: Receiver<BOut>,
    efd: i32,
    efd_buf: Box<u64>,
    now: i64,
}

impl Worker {
    pub fn new(
        id: usize,
        ring: Ring,
        listen_fd: i32,
        pgs: Vec<PgConn>,
        jwt: Jwt,
        jobs: Sender<BJob>,
        results: Receiver<BOut>,
        efd: i32,
    ) -> Worker {
        Worker {
            id,
            ring,
            listen_fd,
            conns: Vec::with_capacity(4096),
            free: Vec::new(),
            pgs,
            pool: Vec::new(),
            scan: Scan::default(),
            jwt,
            jobs,
            results,
            efd,
            efd_buf: Box::new(0u64),
            now: unix_now(),
        }
    }

    // ------------------------------------------------------------------------ event loop

    pub fn run(&mut self) -> io::Result<()> {
        self.arm_accept();
        self.arm_eventfd();
        for pi in 0..self.pgs.len() {
            self.arm_pg_recv(pi);
        }
        loop {
            self.flush_pgs();
            self.ring.buf_publish();
            self.ring.submit_and_wait(1)?;
            self.now = unix_now();
            let mut n = 0u32;
            while let Some(cqe) = self.ring.next_cqe() {
                self.handle_cqe(cqe);
                n += 1;
                if n >= 256 {
                    self.ring.cq_commit();
                    n = 0;
                }
            }
            self.ring.cq_commit();
        }
    }

    fn handle_cqe(&mut self, cqe: Cqe) {
        let tag = cqe.user_data >> 56;
        let gid = ((cqe.user_data >> 32) & GEN_MASK as u64) as u32;
        let idx = (cqe.user_data & 0xFFFF_FFFF) as usize;
        match tag {
            T_ACCEPT => self.on_accept(cqe.res, cqe.flags),
            T_RECV => self.on_recv(idx, gid, cqe.res, cqe.flags),
            T_SEND => self.on_send(idx, gid, cqe.res),
            T_PGRECV => self.on_pg_recv(idx, cqe.res),
            T_PGSEND => self.on_pg_send(idx, cqe.res),
            T_EVENTFD => self.on_eventfd(),
            _ => {}
        }
    }

    fn arm_accept(&mut self) {
        let fd = self.listen_fd;
        self.ring.push_accept_multi(fd, ud(T_ACCEPT, 0, 0));
    }

    fn arm_eventfd(&mut self) {
        let p = &mut *self.efd_buf as *mut u64 as *mut u8;
        let fd = self.efd;
        self.ring.push_read(fd, p, 8, ud(T_EVENTFD, 0, 0));
    }

    // ------------------------------------------------------------------------ connections

    fn on_accept(&mut self, res: i32, flags: u32) {
        if res >= 0 {
            let fd = res;
            let one: libc::c_int = 1;
            unsafe {
                libc::setsockopt(
                    fd,
                    libc::IPPROTO_TCP,
                    libc::TCP_NODELAY,
                    &one as *const libc::c_int as *const libc::c_void,
                    std::mem::size_of::<libc::c_int>() as libc::socklen_t,
                );
            }
            let ci = match self.free.pop() {
                Some(i) => i as usize,
                None => {
                    self.conns.push(Conn::new());
                    self.conns.len() - 1
                }
            };
            {
                let c = &mut self.conns[ci];
                c.fd = fd;
                c.in_use = true;
                c.recv_active = false;
                c.send_active = false;
                c.closing = false;
                c.close_after_send = false;
                c.busy = false;
                c.keep_alive = true;
                c.viewer = 0;
                c.inbuf.clear();
                c.token.clear();
                c.secret.clear();
                c.pending = Pending::None;
            }
            self.arm_recv(ci);
        }
        if flags & uring::CQE_F_MORE == 0 {
            self.arm_accept();
        }
    }

    fn arm_recv(&mut self, ci: usize) {
        let (fd, gid) = {
            let c = &self.conns[ci];
            (c.fd, c.gid)
        };
        self.ring.push_recv_multishot(fd, BGID, ud(T_RECV, gid, ci as u32));
        self.conns[ci].recv_active = true;
    }

    fn on_recv(&mut self, ci: usize, gid: u32, res: i32, flags: u32) {
        let has_buf = flags & uring::CQE_F_BUFFER != 0;
        let bid = (flags >> 16) as u16;
        let valid = ci < self.conns.len() && self.conns[ci].in_use && self.conns[ci].gid == gid;
        if !valid {
            if has_buf {
                self.ring.buf_recycle(bid);
            }
            return;
        }
        let more = flags & uring::CQE_F_MORE != 0;
        if !more {
            self.conns[ci].recv_active = false;
        }

        if res > 0 && has_buf {
            let data = self.ring.buf_slice(bid, res as usize);
            if !self.conns[ci].closing {
                if self.conns[ci].busy || !self.conns[ci].inbuf.is_empty() {
                    self.conns[ci].inbuf.extend_from_slice(data);
                    if self.conns[ci].inbuf.len() > MAX_REQ + http::MAX_HEAD {
                        self.begin_close(ci);
                    } else if !self.conns[ci].busy {
                        self.process_inbuf(ci);
                    }
                } else {
                    match self.process_slice(ci, data) {
                        Outcome::Incomplete => self.conns[ci].inbuf.extend_from_slice(data),
                        Outcome::Consumed(n) => {
                            if n < data.len() {
                                self.conns[ci].inbuf.extend_from_slice(&data[n..]);
                            }
                        }
                    }
                }
            }
            self.ring.buf_recycle(bid);
            if !more && !self.conns[ci].closing {
                self.arm_recv(ci);
            }
            return;
        }

        if has_buf {
            self.ring.buf_recycle(bid);
        }
        if res == 0 {
            self.begin_close(ci); // peer closed
        } else if res == -uring::ENOBUFS && !self.conns[ci].closing {
            self.arm_recv(ci); // provided buffers ran out for a moment: just re-arm
        } else if res < 0 {
            self.begin_close(ci);
        }
    }

    /// Marks the connection as closing; the slot is released once no io_uring operation is in flight.
    fn begin_close(&mut self, ci: usize) {
        {
            let c = &mut self.conns[ci];
            if !c.closing {
                c.closing = true;
                if c.recv_active || c.send_active {
                    // wakes the multishot recv (it completes with 0) and fails a pending send
                    unsafe {
                        libc::shutdown(c.fd, libc::SHUT_RDWR);
                    }
                }
            }
        }
        self.try_free(ci);
    }

    fn try_free(&mut self, ci: usize) {
        let release = {
            let c = &self.conns[ci];
            c.in_use && c.closing && !c.recv_active && !c.send_active
        };
        if !release {
            return;
        }
        let out = {
            let c = &mut self.conns[ci];
            unsafe {
                libc::close(c.fd);
            }
            c.fd = -1;
            c.in_use = false;
            c.busy = false;
            c.gid = (c.gid + 1) & GEN_MASK;
            c.pending = Pending::None;
            c.secret.clear();
            c.token.clear();
            c.inbuf = Vec::new();
            c.out_off = 0;
            std::mem::take(&mut c.out)
        };
        self.recycle_buf(out);
        self.free.push(ci as u32);
    }

    fn conn_ok(&self, ci: usize, gid: u32) -> bool {
        ci < self.conns.len()
            && self.conns[ci].in_use
            && self.conns[ci].gid == gid
            && !self.conns[ci].closing
    }

    // ------------------------------------------------------------------------ buffers and sending

    fn take_buf(&mut self) -> Vec<u8> {
        let mut b = match self.pool.pop() {
            Some(b) => b,
            None => Vec::with_capacity(16 * 1024),
        };
        b.clear();
        b.resize(HDR_RESERVE, 0);
        b
    }

    fn recycle_buf(&mut self, mut b: Vec<u8>) {
        if b.capacity() > 0 && b.capacity() <= 256 * 1024 && self.pool.len() < 4096 {
            b.clear();
            self.pool.push(b);
        }
    }

    /// `out` holds HDR_RESERVE placeholder bytes followed by the body. Writes the head in front of the
    /// body and starts sending.
    fn send_response(&mut self, ci: usize, mut out: Vec<u8>, status: u16) {
        if self.conns[ci].closing {
            self.recycle_buf(out);
            self.conns[ci].busy = false;
            self.try_free(ci);
            return;
        }
        let close = !self.conns[ci].keep_alive;
        let body_len = out.len() - HDR_RESERVE;
        let mut head = [0u8; HDR_RESERVE];
        let n = http::write_head(&mut head, status, body_len, close);
        out[HDR_RESERVE - n..HDR_RESERVE].copy_from_slice(&head[..n]);
        let old = {
            let c = &mut self.conns[ci];
            let old = std::mem::replace(&mut c.out, out);
            c.out_off = HDR_RESERVE - n;
            c.close_after_send = close;
            old
        };
        self.recycle_buf(old);
        self.submit_send(ci);
    }

    fn submit_send(&mut self, ci: usize) {
        let (fd, gid, ptr, len) = {
            let c = &self.conns[ci];
            let p = unsafe { c.out.as_ptr().add(c.out_off) };
            (c.fd, c.gid, p, (c.out.len() - c.out_off) as u32)
        };
        self.ring.push_send(fd, ptr, len, ud(T_SEND, gid, ci as u32));
        self.conns[ci].send_active = true;
    }

    fn on_send(&mut self, ci: usize, gid: u32, res: i32) {
        if ci >= self.conns.len() || !self.conns[ci].in_use || self.conns[ci].gid != gid {
            return;
        }
        self.conns[ci].send_active = false;
        if res <= 0 {
            let out = std::mem::take(&mut self.conns[ci].out);
            self.recycle_buf(out);
            self.conns[ci].busy = false;
            self.begin_close(ci);
            return;
        }
        let done = {
            let c = &mut self.conns[ci];
            c.out_off += res as usize;
            c.out_off >= c.out.len()
        };
        if !done {
            self.submit_send(ci);
            return;
        }
        let out = std::mem::take(&mut self.conns[ci].out);
        self.recycle_buf(out);
        let (close, closing, has_more) = {
            let c = &mut self.conns[ci];
            c.busy = false;
            (c.close_after_send, c.closing, !c.inbuf.is_empty())
        };
        if close {
            self.begin_close(ci);
        } else if closing {
            self.try_free(ci);
        } else if has_more {
            self.process_inbuf(ci);
        }
    }

    fn reply_error(&mut self, ci: usize, status: u16, msg: &str) {
        let mut out = self.take_buf();
        json::error_body(&mut out, msg);
        self.send_response(ci, out, status);
    }

    // ------------------------------------------------------------------------ request intake

    fn process_inbuf(&mut self, ci: usize) {
        loop {
            {
                let c = &self.conns[ci];
                if !c.in_use || c.closing || c.busy {
                    return;
                }
            }
            let mut buf = std::mem::take(&mut self.conns[ci].inbuf);
            if buf.is_empty() {
                self.conns[ci].inbuf = buf;
                return;
            }
            match self.process_slice(ci, &buf) {
                Outcome::Incomplete => {
                    self.conns[ci].inbuf = buf;
                    return;
                }
                Outcome::Consumed(n) => {
                    if n >= buf.len() {
                        buf.clear();
                        if buf.capacity() > 16 * 1024 {
                            buf = Vec::new();
                        }
                    } else {
                        buf.copy_within(n.., 0);
                        let l = buf.len() - n;
                        buf.truncate(l);
                    }
                    self.conns[ci].inbuf = buf;
                }
            }
        }
    }

    fn process_slice(&mut self, ci: usize, data: &[u8]) -> Outcome {
        match http::parse(data) {
            Parsed::Incomplete => {
                if data.len() > MAX_REQ {
                    self.start_request(ci, false);
                    self.reply_error(ci, 413, "request too large");
                    return Outcome::Consumed(data.len());
                }
                Outcome::Incomplete
            }
            Parsed::Bad(code) => {
                self.start_request(ci, false);
                self.reply_error(ci, code, "bad request");
                Outcome::Consumed(data.len())
            }
            Parsed::Complete(req) => {
                let n = req.consumed;
                self.start_request(ci, req.keep_alive);
                self.dispatch(ci, &req);
                Outcome::Consumed(n)
            }
        }
    }

    fn start_request(&mut self, ci: usize, keep_alive: bool) {
        let c = &mut self.conns[ci];
        c.busy = true;
        c.keep_alive = keep_alive;
        c.viewer = 0;
        c.pending = Pending::None;
    }

    // ------------------------------------------------------------------------ postgres plumbing

    fn pick_pg(&self) -> usize {
        let mut best = 0usize;
        let mut best_n = usize::MAX;
        for (i, p) in self.pgs.iter().enumerate() {
            let n = p.inflight.len();
            if n < best_n {
                best = i;
                best_n = n;
            }
        }
        best
    }

    /// Terminates the batch with Sync and registers the client as waiting for its result.
    fn submit_db(&mut self, ci: usize, pi: usize, kind: Kind) {
        let gid = self.conns[ci].gid;
        {
            let p = &mut self.pgs[pi];
            pg::sync(&mut p.tx_pending);
            p.inflight.push_back((ci as u32, gid));
        }
        self.conns[ci].pending = Pending::Db(kind);
    }

    fn flush_pgs(&mut self) {
        for pi in 0..self.pgs.len() {
            let start = {
                let p = &self.pgs[pi];
                !p.sending && !p.tx_pending.is_empty()
            };
            if start {
                self.start_pg_send(pi);
            }
        }
    }

    fn start_pg_send(&mut self, pi: usize) {
        let (fd, ptr, len) = {
            let p = &mut self.pgs[pi];
            std::mem::swap(&mut p.tx_active, &mut p.tx_pending);
            p.tx_pending.clear();
            p.tx_sent = 0;
            p.sending = true;
            (p.fd, p.tx_active.as_ptr(), p.tx_active.len() as u32)
        };
        self.ring.push_send(fd, ptr, len, ud(T_PGSEND, 0, pi as u32));
    }

    fn on_pg_send(&mut self, pi: usize, res: i32) {
        if res <= 0 {
            self.pg_fatal(pi, "send", res);
        }
        let (done, fd, ptr, len) = {
            let p = &mut self.pgs[pi];
            p.tx_sent += res as usize;
            let done = p.tx_sent >= p.tx_active.len();
            let ptr = unsafe { p.tx_active.as_ptr().add(p.tx_sent) };
            let len = (p.tx_active.len() - p.tx_sent) as u32;
            (done, p.fd, ptr, len)
        };
        if !done {
            self.ring.push_send(fd, ptr, len, ud(T_PGSEND, 0, pi as u32));
            return;
        }
        {
            let p = &mut self.pgs[pi];
            p.sending = false;
            p.tx_active.clear();
        }
        if !self.pgs[pi].tx_pending.is_empty() {
            self.start_pg_send(pi);
        }
    }

    fn arm_pg_recv(&mut self, pi: usize) {
        let (fd, ptr, len) = {
            let p = &mut self.pgs[pi];
            if p.rx.capacity() - p.rx.len() < 16 * 1024 {
                p.rx.reserve(64 * 1024);
            }
            p.recv_active = true;
            let ptr = unsafe { p.rx.as_mut_ptr().add(p.rx.len()) };
            (p.fd, ptr, (p.rx.capacity() - p.rx.len()) as u32)
        };
        self.ring.push_recv(fd, ptr, len, ud(T_PGRECV, 0, pi as u32));
    }

    fn on_pg_recv(&mut self, pi: usize, res: i32) {
        self.pgs[pi].recv_active = false;
        if res <= 0 {
            self.pg_fatal(pi, "recv", res);
        }
        {
            let p = &mut self.pgs[pi];
            unsafe {
                let new_len = p.rx.len() + res as usize;
                p.rx.set_len(new_len);
            }
        }
        self.process_pg_rx(pi);
        self.arm_pg_recv(pi);
    }

    fn pg_fatal(&self, pi: usize, what: &str, res: i32) -> ! {
        eprintln!(
            "worker {}: postgres connection {} failed ({} returned {}); exiting",
            self.id, pi, what, res
        );
        std::process::exit(1);
    }

    /// Splits the receive buffer into per-request frame groups (each ends with ReadyForQuery) and
    /// completes the oldest in-flight request for each of them.
    fn process_pg_rx(&mut self, pi: usize) {
        let mut rx = std::mem::take(&mut self.pgs[pi].rx);
        let mut pos = self.pgs[pi].rx_pos;
        let mut start = self.pgs[pi].req_start;
        let mut scan = std::mem::take(&mut self.scan);
        loop {
            if rx.len() < pos + 5 {
                break;
            }
            let tag = rx[pos];
            let len = u32::from_be_bytes([rx[pos + 1], rx[pos + 2], rx[pos + 3], rx[pos + 4]]) as usize;
            let end = pos + 1 + len;
            if rx.len() < end {
                break;
            }
            pos = end;
            if tag == b'Z' {
                let front = self.pgs[pi].inflight.pop_front();
                if let Some((ci, gid)) = front {
                    self.complete_db(&rx[start..end], &mut scan, ci, gid);
                }
                start = end;
            }
        }
        self.scan = scan;
        if start == rx.len() {
            rx.clear();
            pos = 0;
            start = 0;
        } else if start >= 64 * 1024 {
            rx.copy_within(start.., 0);
            let l = rx.len() - start;
            rx.truncate(l);
            pos -= start;
            start = 0;
        }
        let p = &mut self.pgs[pi];
        p.rx = rx;
        p.rx_pos = pos;
        p.req_start = start;
    }

    /// A pipelined batch finished: turn its rows into the HTTP response.
    fn complete_db(&mut self, rx: &[u8], scan: &mut Scan, ci: u32, gid: u32) {
        let ci = ci as usize;
        if !self.conn_ok(ci, gid) {
            return; // client went away; a committed write stays committed
        }
        let pending = std::mem::replace(&mut self.conns[ci].pending, Pending::None);
        let kind = match pending {
            Pending::Db(k) => k,
            other => {
                self.conns[ci].pending = other;
                return;
            }
        };
        scan.run(rx);
        let mut out = self.take_buf();
        let done = {
            let c = &self.conns[ci];
            render::finish(kind, c.viewer, &c.token, rx, scan, &mut out, self.now, &self.jwt)
        };
        match done {
            Done::Json(status) => self.send_response(ci, out, status),
            Done::NoContent => {
                out.truncate(HDR_RESERVE);
                self.send_response(ci, out, 204);
            }
            Done::Err(status, msg) => {
                if scan.has_err && ERR_LOGS.fetch_add(1, Ordering::Relaxed) < 20 {
                    eprintln!("[db error] {}", scan.err_text);
                }
                out.truncate(HDR_RESERVE);
                json::error_body(&mut out, msg);
                self.send_response(ci, out, status);
            }
            Done::Login(row) => {
                self.recycle_buf(out);
                let render::LoginRow {
                    id,
                    username,
                    email,
                    bio,
                    image,
                    hash,
                } = row;
                let pw = std::mem::take(&mut self.conns[ci].secret);
                let gid = self.conns[ci].gid;
                self.conns[ci].pending = Pending::Verify(LoginCtx {
                    id,
                    username,
                    email,
                    bio,
                    image,
                });
                let job = BJob::Verify {
                    wid: self.id,
                    ci: ci as u32,
                    gid,
                    pw,
                    hash,
                };
                if self.jobs.try_send(job).is_err() {
                    self.conns[ci].pending = Pending::None;
                    self.reply_error(ci, 503, "server busy");
                }
            }
        }
    }

    // ------------------------------------------------------------------------ bcrypt hand-off

    fn on_eventfd(&mut self) {
        loop {
            match self.results.try_recv() {
                Ok(BOut::Hashed { ci, gid, res }) => self.on_hashed(ci as usize, gid, res),
                Ok(BOut::Verified { ci, gid, ok }) => self.on_verified(ci as usize, gid, ok),
                Err(_) => break,
            }
        }
        self.arm_eventfd();
    }

    fn start_hash(&mut self, ci: usize, pw: String, action: HashAction) {
        let gid = self.conns[ci].gid;
        self.conns[ci].pending = Pending::Hash(action);
        let job = BJob::Hash {
            wid: self.id,
            ci: ci as u32,
            gid,
            pw,
        };
        if self.jobs.try_send(job).is_err() {
            self.conns[ci].pending = Pending::None;
            self.reply_error(ci, 503, "server busy");
        }
    }

    fn on_hashed(&mut self, ci: usize, gid: u32, res: Option<String>) {
        if !self.conn_ok(ci, gid) {
            return;
        }
        let pending = std::mem::replace(&mut self.conns[ci].pending, Pending::None);
        let action = match pending {
            Pending::Hash(a) => a,
            other => {
                self.conns[ci].pending = other;
                return;
            }
        };
        let hash = match res {
            Some(h) => h,
            None => {
                self.reply_error(ci, 500, "internal server error");
                return;
            }
        };
        match action {
            HashAction::Register { username, email } => {
                let pi = self.pick_pg();
                {
                    let tx = &mut self.pgs[pi].tx_pending;
                    let b = pg::bind_begin(tx, sql::name(sql::S_USER_INSERT), 3);
                    pg::p_text(tx, username.as_bytes());
                    pg::p_text(tx, email.as_bytes());
                    pg::p_text(tx, hash.as_bytes());
                    pg::bind_end(tx, b);
                }
                self.submit_db(ci, pi, Kind::Register);
            }
            HashAction::UpdateUser {
                email,
                username,
                bio,
                image,
            } => {
                let viewer = self.conns[ci].viewer;
                self.submit_update_user(
                    ci,
                    viewer,
                    email.as_deref(),
                    username.as_deref(),
                    Some(hash.as_str()),
                    bio.as_deref(),
                    image.as_deref(),
                );
            }
        }
    }

    fn on_verified(&mut self, ci: usize, gid: u32, ok: bool) {
        if !self.conn_ok(ci, gid) {
            return;
        }
        let pending = std::mem::replace(&mut self.conns[ci].pending, Pending::None);
        let ctx = match pending {
            Pending::Verify(c) => c,
            other => {
                self.conns[ci].pending = other;
                return;
            }
        };
        if !ok {
            self.reply_error(ci, 401, "invalid email or password");
            return;
        }
        let mut tok: Vec<u8> = Vec::with_capacity(200);
        self.jwt.sign(ctx.id, self.now, &mut tok);
        let mut out = self.take_buf();
        render::write_user_json(
            &mut out,
            &ctx.username,
            &ctx.email,
            ctx.bio.as_deref(),
            ctx.image.as_deref(),
            &tok,
        );
        self.send_response(ci, out, 200);
    }

    // ------------------------------------------------------------------------ auth helpers

    fn viewer_required(&mut self, ci: usize, req: &Req) -> Option<i64> {
        match self.jwt.check(req.auth, self.now) {
            AuthState::User(id) => {
                self.conns[ci].viewer = id;
                Some(id)
            }
            _ => {
                self.reply_error(ci, 401, "unauthorized");
                None
            }
        }
    }

    fn viewer_optional(&mut self, ci: usize, req: &Req) -> Option<i64> {
        match self.jwt.check(req.auth, self.now) {
            AuthState::User(id) => {
                self.conns[ci].viewer = id;
                Some(id)
            }
            AuthState::Anonymous => Some(0),
            AuthState::Invalid => {
                self.reply_error(ci, 401, "unauthorized");
                None
            }
        }
    }

    fn set_token(&mut self, ci: usize, auth: Option<&[u8]>) {
        let c = &mut self.conns[ci];
        c.token.clear();
        if let Some(a) = auth {
            if let Some(t) = a.strip_prefix(b"Token ") {
                c.token.extend_from_slice(t);
            }
        }
    }

    // ------------------------------------------------------------------------ routing

    fn dispatch(&mut self, ci: usize, req: &Req) {
        match route(req.method, req.path) {
            Route::NotFound => self.reply_error(ci, 404, "not found"),
            Route::BadMethod => self.reply_error(ci, 405, "method not allowed"),
            Route::Tags => self.do_tags(ci),
            Route::Register => self.do_register(ci, req),
            Route::Login => self.do_login(ci, req),
            Route::UserGet => self.do_user_get(ci, req),
            Route::UserUpdate => self.do_user_update(ci, req),
            Route::Profile(u) => self.do_profile(ci, req, u),
            Route::Follow(u, f) => self.do_follow(ci, req, u, f),
            Route::ArticleList => self.do_list(ci, req, false),
            Route::Feed => self.do_list(ci, req, true),
            Route::ArticleCreate => self.do_article_create(ci, req),
            Route::ArticleGet(s) => self.do_article_get(ci, req, s),
            Route::ArticleUpdate(s) => self.do_article_update(ci, req, s),
            Route::ArticleDelete(s) => self.do_article_delete(ci, req, s),
            Route::Favorite(s, f) => self.do_favorite(ci, req, s, f),
            Route::CommentsList(s) => self.do_comments_list(ci, req, s),
            Route::CommentCreate(s) => self.do_comment_create(ci, req, s),
            Route::CommentDelete(s, id) => self.do_comment_delete(ci, req, s, id),
        }
    }

    // ------------------------------------------------------------------------ handlers

    fn do_tags(&mut self, ci: usize) {
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_TAGS), 0);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::Tags);
    }

    fn do_register(&mut self, ci: usize, req: &Req) {
        let v = match json::parse_body(req.body()) {
            Some(v) => v,
            None => return self.reply_error(ci, 422, "invalid request body"),
        };
        let obj = match v.get("user").and_then(|u| u.as_object()) {
            Some(o) => o,
            None => return self.reply_error(ci, 422, "user is required"),
        };
        let username = match req_field(obj, "username") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "username can't be blank"),
        };
        let email = match req_field(obj, "email") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "email can't be blank"),
        };
        let password = match req_field(obj, "password") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "password can't be blank"),
        };
        // bcrypt only looks at the first 72 bytes: longer passwords are rejected, not truncated.
        if password.len() > 72 {
            return self.reply_error(ci, 422, "password must be at most 72 bytes");
        }
        let action = HashAction::Register {
            username: username.to_string(),
            email: email.to_string(),
        };
        self.start_hash(ci, password.to_string(), action);
    }

    fn do_login(&mut self, ci: usize, req: &Req) {
        let v = match json::parse_body(req.body()) {
            Some(v) => v,
            None => return self.reply_error(ci, 422, "invalid request body"),
        };
        let obj = match v.get("user").and_then(|u| u.as_object()) {
            Some(o) => o,
            None => return self.reply_error(ci, 422, "user is required"),
        };
        let email = match req_field(obj, "email") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "email can't be blank"),
        };
        let password = match req_field(obj, "password") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "password can't be blank"),
        };
        {
            let c = &mut self.conns[ci];
            c.secret.clear();
            c.secret.push_str(password);
        }
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_USER_BY_EMAIL), 1);
            pg::p_text(tx, email.as_bytes());
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::Login);
    }

    fn do_user_get(&mut self, ci: usize, req: &Req) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        self.set_token(ci, req.auth);
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_USER_BY_ID), 1);
            pg::p_i64(tx, viewer);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::UserGet);
    }

    fn do_user_update(&mut self, ci: usize, req: &Req) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        self.set_token(ci, req.auth);
        let v = match json::parse_body(req.body()) {
            Some(v) => v,
            None => return self.reply_error(ci, 422, "invalid request body"),
        };
        let obj = match v.get("user").and_then(|u| u.as_object()) {
            Some(o) => o,
            None => return self.reply_error(ci, 422, "user is required"),
        };
        let email = match opt_field(obj, "email") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "email must be a string"),
        };
        let username = match opt_field(obj, "username") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "username must be a string"),
        };
        let password = match opt_field(obj, "password") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "password must be a string"),
        };
        let bio = match opt_field(obj, "bio") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "bio must be a string"),
        };
        let image = match opt_field(obj, "image") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "image must be a string"),
        };
        if email == Some("") || username == Some("") || password == Some("") {
            return self.reply_error(ci, 422, "email, username and password cannot be blank");
        }
        if let Some(pw) = password {
            if pw.len() > 72 {
                return self.reply_error(ci, 422, "password must be at most 72 bytes");
            }
        }
        match password {
            Some(pw) => {
                let action = HashAction::UpdateUser {
                    email: email.map(|s| s.to_string()),
                    username: username.map(|s| s.to_string()),
                    bio: bio.map(|s| s.to_string()),
                    image: image.map(|s| s.to_string()),
                };
                self.start_hash(ci, pw.to_string(), action);
            }
            None => self.submit_update_user(ci, viewer, email, username, None, bio, image),
        }
    }

    fn submit_update_user(
        &mut self,
        ci: usize,
        viewer: i64,
        email: Option<&str>,
        username: Option<&str>,
        hash: Option<&str>,
        bio: Option<&str>,
        image: Option<&str>,
    ) {
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_USER_UPDATE), 6);
            pg::p_i64(tx, viewer);
            pg::p_opt_text(tx, email);
            pg::p_opt_text(tx, username);
            pg::p_opt_text(tx, hash);
            pg::p_opt_text(tx, bio);
            pg::p_opt_text(tx, image);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::UserUpdate);
    }

    fn do_profile(&mut self, ci: usize, req: &Req, raw: &[u8]) {
        let viewer = match self.viewer_optional(ci, req) {
            Some(v) => v,
            None => return,
        };
        let uname = match seg_text(raw) {
            Some(u) => u,
            None => return self.reply_error(ci, 404, "profile not found"),
        };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_PROFILE), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &uname);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::Profile(0));
    }

    fn do_follow(&mut self, ci: usize, req: &Req, raw: &[u8], follow: bool) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let uname = match seg_text(raw) {
            Some(u) => u,
            None => return self.reply_error(ci, 404, "profile not found"),
        };
        let stmt = if follow { sql::S_FOLLOW } else { sql::S_UNFOLLOW };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(stmt), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &uname);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_PROFILE), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &uname);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::Profile(1));
    }

    /// GET /api/articles and GET /api/articles/feed
    fn do_list(&mut self, ci: usize, req: &Req, feed: bool) {
        let viewer = if feed {
            match self.viewer_required(ci, req) {
                Some(v) => v,
                None => return,
            }
        } else {
            match self.viewer_optional(ci, req) {
                Some(v) => v,
                None => return,
            }
        };
        let (limit, offset) = match list_params(req.query) {
            Some(x) => x,
            None => return self.reply_error(ci, 422, "limit must be 1..100 and offset must be >= 0"),
        };

        let mut kind = sql::LIST_NONE;
        let mut filter: Option<Cow<[u8]>> = None;
        if feed {
            kind = sql::LIST_FEED;
        } else {
            let tag = non_empty(http::query_get(req.query, b"tag"));
            let author = non_empty(http::query_get(req.query, b"author"));
            let fav = non_empty(http::query_get(req.query, b"favorited"));
            if let Some(t) = tag {
                kind = sql::LIST_TAG;
                filter = Some(http::pct_decode(t, true));
            } else if let Some(a) = author {
                kind = sql::LIST_AUTHOR;
                filter = Some(http::pct_decode(a, true));
            } else if let Some(f) = fav {
                kind = sql::LIST_FAV;
                filter = Some(http::pct_decode(f, true));
            }
        }
        if let Some(f) = &filter {
            if std::str::from_utf8(f).is_err() {
                // not valid text => cannot match anything
                let mut out = self.take_buf();
                out.extend_from_slice(b"{\"articles\":[],\"articlesCount\":0}");
                self.send_response(ci, out, 200);
                return;
            }
        }

        let pi = self.pick_pg();
        {
            let p = &mut self.pgs[pi];
            sql::ensure_list(p, kind, limit);
            let tx = &mut p.tx_pending;
            let mut nm = [0u8; 8];
            let name = sql::list_name(kind, limit, &mut nm);
            let nparams: u16 = if filter.is_some() { 3 } else { 2 };
            let b = pg::bind_begin(tx, name, nparams);
            pg::p_i64(tx, viewer);
            pg::p_i64(tx, offset);
            if let Some(f) = &filter {
                pg::p_text(tx, f);
            }
            pg::bind_end(tx, b);

            let (cstmt, cparams) = match kind {
                sql::LIST_TAG => (sql::S_COUNT_TAG, 1u16),
                sql::LIST_AUTHOR => (sql::S_COUNT_AUTHOR, 1u16),
                sql::LIST_FAV => (sql::S_COUNT_FAV, 1u16),
                sql::LIST_FEED => (sql::S_COUNT_FEED, 1u16),
                _ => (sql::S_COUNT_NONE, 0u16),
            };
            let b = pg::bind_begin(tx, sql::name(cstmt), cparams);
            if kind == sql::LIST_FEED {
                pg::p_i64(tx, viewer);
            } else if let Some(f) = &filter {
                pg::p_text(tx, f);
            }
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::ArticleList);
    }

    fn do_article_get(&mut self, ci: usize, req: &Req, raw: &[u8]) {
        let viewer = match self.viewer_optional(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_ARTICLE_SLUG), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::ArticleOne(0, 200));
    }

    fn do_article_create(&mut self, ci: usize, req: &Req) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let v = match json::parse_body(req.body()) {
            Some(v) => v,
            None => return self.reply_error(ci, 422, "invalid request body"),
        };
        let obj = match v.get("article").and_then(|a| a.as_object()) {
            Some(o) => o,
            None => return self.reply_error(ci, 422, "article is required"),
        };
        let title = match req_field(obj, "title") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "title can't be blank"),
        };
        let description = match req_field(obj, "description") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "description can't be blank"),
        };
        let body = match req_field(obj, "body") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "body can't be blank"),
        };
        let mut tags: Vec<String> = Vec::new();
        match obj.get("tagList") {
            None => {}
            Some(Value::Null) => {}
            Some(Value::Array(items)) => {
                for t in items {
                    match t {
                        Value::String(s) if !s.is_empty() => tags.push(s.clone()),
                        _ => return self.reply_error(ci, 422, "tagList must contain non-empty strings"),
                    }
                }
            }
            Some(_) => return self.reply_error(ci, 422, "tagList must be an array"),
        }

        let pi = self.pick_pg();
        let last: u8;
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_INSERT), 4);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, title.as_bytes());
            pg::p_text(tx, description.as_bytes());
            pg::p_text(tx, body.as_bytes());
            pg::bind_end(tx, b);
            let mut idx: u8 = 1;
            if !tags.is_empty() {
                let b = pg::bind_begin(tx, sql::name(sql::S_TAGS_INSERT), 1);
                pg::p_text_array(tx, &tags);
                pg::bind_end(tx, b);
                let b = pg::bind_begin(tx, sql::name(sql::S_AT_INSERT), 1);
                pg::p_text_array(tx, &tags);
                pg::bind_end(tx, b);
                idx = 3;
            }
            let b = pg::bind_begin(tx, sql::name(sql::S_ARTICLE_CURR), 1);
            pg::p_i64(tx, viewer);
            pg::bind_end(tx, b);
            last = idx;
        }
        self.submit_db(ci, pi, Kind::ArticleOne(last, 201));
    }

    fn do_article_update(&mut self, ci: usize, req: &Req, raw: &[u8]) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let v = match json::parse_body(req.body()) {
            Some(v) => v,
            None => return self.reply_error(ci, 422, "invalid request body"),
        };
        let obj = match v.get("article").and_then(|a| a.as_object()) {
            Some(o) => o,
            None => return self.reply_error(ci, 422, "article is required"),
        };
        let title = match opt_field(obj, "title") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "title must be a string"),
        };
        let description = match opt_field(obj, "description") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "description must be a string"),
        };
        let body = match opt_field(obj, "body") {
            Ok(x) => x,
            Err(_) => return self.reply_error(ci, 422, "body must be a string"),
        };
        if title == Some("") || description == Some("") || body == Some("") {
            return self.reply_error(ci, 422, "title, description and body cannot be blank");
        }
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_AUTH), 1);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_UPDATE), 5);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &slug);
            pg::p_opt_text(tx, title);
            pg::p_opt_text(tx, description);
            pg::p_opt_text(tx, body);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::ArticleUpdate);
    }

    fn do_article_delete(&mut self, ci: usize, req: &Req, raw: &[u8]) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_AUTH), 1);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_DELETE), 2);
            pg::p_text(tx, &slug);
            pg::p_i64(tx, viewer);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::ArticleDelete);
    }

    fn do_favorite(&mut self, ci: usize, req: &Req, raw: &[u8], add: bool) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let stmt = if add { sql::S_FAV } else { sql::S_UNFAV };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(stmt), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_ARTICLE_SLUG), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::ArticleOne(1, 200));
    }

    fn do_comments_list(&mut self, ci: usize, req: &Req, raw: &[u8]) {
        let viewer = match self.viewer_optional(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_ID), 1);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_COMMENTS), 2);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::CommentsList);
    }

    fn do_comment_create(&mut self, ci: usize, req: &Req, raw: &[u8]) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let v = match json::parse_body(req.body()) {
            Some(v) => v,
            None => return self.reply_error(ci, 422, "invalid request body"),
        };
        let obj = match v.get("comment").and_then(|c| c.as_object()) {
            Some(o) => o,
            None => return self.reply_error(ci, 422, "comment is required"),
        };
        let body = match req_field(obj, "body") {
            Some(s) => s,
            None => return self.reply_error(ci, 422, "body can't be blank"),
        };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_ART_ID), 1);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_COMMENT_INSERT), 3);
            pg::p_text(tx, &slug);
            pg::p_i64(tx, viewer);
            pg::p_text(tx, body.as_bytes());
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::CommentCreate);
    }

    fn do_comment_delete(&mut self, ci: usize, req: &Req, raw_slug: &[u8], raw_id: &[u8]) {
        let viewer = match self.viewer_required(ci, req) {
            Some(v) => v,
            None => return,
        };
        let slug = match seg_text(raw_slug) {
            Some(s) => s,
            None => return self.reply_error(ci, 404, "article not found"),
        };
        let id = match http::parse_int(raw_id) {
            Some(i) => i,
            None => return self.reply_error(ci, 404, "comment not found"),
        };
        let pi = self.pick_pg();
        {
            let tx = &mut self.pgs[pi].tx_pending;
            let b = pg::bind_begin(tx, sql::name(sql::S_COMMENT_AUTH), 2);
            pg::p_i64(tx, id);
            pg::p_text(tx, &slug);
            pg::bind_end(tx, b);
            let b = pg::bind_begin(tx, sql::name(sql::S_COMMENT_DELETE), 3);
            pg::p_i64(tx, id);
            pg::p_text(tx, &slug);
            pg::p_i64(tx, viewer);
            pg::bind_end(tx, b);
        }
        self.submit_db(ci, pi, Kind::CommentDelete);
    }
}

// ---------------------------------------------------------------------------- free helpers

enum Route<'a> {
    Tags,
    Register,
    Login,
    UserGet,
    UserUpdate,
    Profile(&'a [u8]),
    Follow(&'a [u8], bool),
    ArticleList,
    ArticleCreate,
    Feed,
    ArticleGet(&'a [u8]),
    ArticleUpdate(&'a [u8]),
    ArticleDelete(&'a [u8]),
    Favorite(&'a [u8], bool),
    CommentsList(&'a [u8]),
    CommentCreate(&'a [u8]),
    CommentDelete(&'a [u8], &'a [u8]),
    NotFound,
    BadMethod,
}

fn route<'a>(m: Method, path: &'a [u8]) -> Route<'a> {
    let rest = match path.strip_prefix(b"/api/") {
        Some(r) => r,
        None => return Route::NotFound,
    };
    let empty: &'a [u8] = &[];
    let mut seg: [&'a [u8]; 5] = [empty; 5];
    let mut n = 0usize;
    for part in rest.split(|&b| b == b'/') {
        if n == 5 {
            return Route::NotFound;
        }
        seg[n] = part;
        n += 1;
    }
    match n {
        1 => match seg[0] {
            b"tags" => {
                if m == Method::Get {
                    Route::Tags
                } else {
                    Route::BadMethod
                }
            }
            b"users" => {
                if m == Method::Post {
                    Route::Register
                } else {
                    Route::BadMethod
                }
            }
            b"user" => match m {
                Method::Get => Route::UserGet,
                Method::Put => Route::UserUpdate,
                _ => Route::BadMethod,
            },
            b"articles" => match m {
                Method::Get => Route::ArticleList,
                Method::Post => Route::ArticleCreate,
                _ => Route::BadMethod,
            },
            _ => Route::NotFound,
        },
        2 => match (seg[0], seg[1]) {
            (b"users", b"login") => {
                if m == Method::Post {
                    Route::Login
                } else {
                    Route::BadMethod
                }
            }
            (b"profiles", u) => {
                if m == Method::Get {
                    Route::Profile(u)
                } else {
                    Route::BadMethod
                }
            }
            (b"articles", b"feed") => {
                if m == Method::Get {
                    Route::Feed
                } else {
                    Route::BadMethod
                }
            }
            (b"articles", s) => match m {
                Method::Get => Route::ArticleGet(s),
                Method::Put => Route::ArticleUpdate(s),
                Method::Delete => Route::ArticleDelete(s),
                _ => Route::BadMethod,
            },
            _ => Route::NotFound,
        },
        3 => match (seg[0], seg[2]) {
            (b"profiles", b"follow") => match m {
                Method::Post => Route::Follow(seg[1], true),
                Method::Delete => Route::Follow(seg[1], false),
                _ => Route::BadMethod,
            },
            (b"articles", b"favorite") => match m {
                Method::Post => Route::Favorite(seg[1], true),
                Method::Delete => Route::Favorite(seg[1], false),
                _ => Route::BadMethod,
            },
            (b"articles", b"comments") => match m {
                Method::Get => Route::CommentsList(seg[1]),
                Method::Post => Route::CommentCreate(seg[1]),
                _ => Route::BadMethod,
            },
            _ => Route::NotFound,
        },
        4 => {
            if seg[0] == b"articles" && seg[2] == b"comments" {
                if m == Method::Delete {
                    Route::CommentDelete(seg[1], seg[3])
                } else {
                    Route::BadMethod
                }
            } else {
                Route::NotFound
            }
        }
        _ => Route::NotFound,
    }
}

/// Percent-decoded path segment, or None if it is empty or not valid UTF-8 (=> 404).
fn seg_text(raw: &[u8]) -> Option<Cow<'_, [u8]>> {
    let d = http::pct_decode(raw, false);
    if d.is_empty() || std::str::from_utf8(&d).is_err() {
        return None;
    }
    Some(d)
}

fn non_empty(v: Option<&[u8]>) -> Option<&[u8]> {
    match v {
        Some(s) if !s.is_empty() => Some(s),
        _ => None,
    }
}

/// limit: default 20, 1..=100; offset: default 0, >= 0. Anything else => None (422).
fn list_params(query: &[u8]) -> Option<(usize, i64)> {
    let limit = match http::query_get(query, b"limit") {
        None => 20usize,
        Some(v) => {
            let n = http::parse_int(v)?;
            if n < 1 || n > 100 {
                return None;
            }
            n as usize
        }
    };
    let offset = match http::query_get(query, b"offset") {
        None => 0i64,
        Some(v) => {
            let n = http::parse_int(v)?;
            if n < 0 {
                return None;
            }
            n
        }
    };
    Some((limit, offset))
}

/// Required, non-empty string field of a JSON object.
fn req_field<'a>(obj: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    match json::field(obj, key) {
        Field::Str(s) if !s.is_empty() => Some(s),
        _ => None,
    }
}

/// Optional string field: absent or null => Ok(None); wrong type => Err.
fn opt_field<'a>(obj: &'a Map<String, Value>, key: &str) -> Result<Option<&'a str>, ()> {
    match json::field(obj, key) {
        Field::Absent => Ok(None),
        Field::Str(s) => Ok(Some(s)),
        Field::Bad => Err(()),
    }
}
