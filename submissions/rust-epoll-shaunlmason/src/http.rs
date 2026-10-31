//! HTTP/1.1 on raw epoll: one thread per SO_REUSEPORT listener, each connection owned by one thread for life.
//!
//! An idle keep-alive connection holds no buffers. Reads land in the thread's scratch buffer and requests are parsed
//! from there; only bytes that don't make a whole request yet (a split read, or pipelined requests queued behind one
//! in flight) are copied into the connection.

use std::io;
use std::os::fd::RawFd;

use crate::api::{self, Outcome};
use crate::reply::{self, Addr, Response};

const LISTENER: u64 = u64::MAX;
const OUTBOX: u64 = u64::MAX - 1;
const MAX_HEAD: usize = 64 * 1024;
pub const MAX_BODY: usize = 1024 * 1024;
const SCRATCH: usize = 256 * 1024;

#[derive(Default)]
struct Conn {
    fd: RawFd,
    generation: u32,
    /// bytes received but not yet a whole request
    pending: Vec<u8>,
    /// bytes not yet accepted by the socket
    out: Vec<u8>,
    out_pos: usize,
    /// a request is with the database; later requests wait in `pending`
    busy: bool,
    close_after: bool,
    peer_closed: bool,
    polling_out: bool,
    sent_continue: bool,
}

pub struct Server {
    thread: u16,
    ep: RawFd,
    lfd: RawFd,
    conns: Vec<Conn>,
    free: Vec<u32>,
    scratch: Vec<u8>,
    keys: &'static crate::jwt::Keys,
}

fn cvt(r: i32) -> io::Result<i32> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

fn errno() -> i32 {
    io::Error::last_os_error().raw_os_error().unwrap_or(0)
}

/// A non-blocking SO_REUSEPORT listener on HOST:PORT.
pub fn listener(host: &str, port: u16) -> io::Result<RawFd> {
    let ip: std::net::IpAddr =
        host.parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "HOST must be an IP address"))?;
    unsafe {
        let family = if ip.is_ipv4() { libc::AF_INET } else { libc::AF_INET6 };
        let fd = cvt(libc::socket(family, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0))?;
        let one: libc::c_int = 1;
        for opt in [libc::SO_REUSEADDR, libc::SO_REUSEPORT] {
            cvt(libc::setsockopt(fd, libc::SOL_SOCKET, opt, &one as *const _ as *const libc::c_void, 4))?;
        }
        match ip {
            std::net::IpAddr::V4(v4) => {
                let a = libc::sockaddr_in {
                    sin_family: libc::AF_INET as u16,
                    sin_port: port.to_be(),
                    sin_addr: libc::in_addr { s_addr: u32::from_ne_bytes(v4.octets()) },
                    sin_zero: [0; 8],
                };
                cvt(libc::bind(fd, &a as *const _ as *const libc::sockaddr, size_of::<libc::sockaddr_in>() as u32))?;
            }
            std::net::IpAddr::V6(v6) => {
                let zero: libc::c_int = 0;
                cvt(libc::setsockopt(fd, libc::IPPROTO_IPV6, libc::IPV6_V6ONLY, &zero as *const _ as *const libc::c_void, 4))?;
                let a = libc::sockaddr_in6 {
                    sin6_family: libc::AF_INET6 as u16,
                    sin6_port: port.to_be(),
                    sin6_flowinfo: 0,
                    sin6_addr: libc::in6_addr { s6_addr: v6.octets() },
                    sin6_scope_id: 0,
                };
                cvt(libc::bind(fd, &a as *const _ as *const libc::sockaddr, size_of::<libc::sockaddr_in6>() as u32))?;
            }
        }
        cvt(libc::listen(fd, 65535))?;
        Ok(fd)
    }
}

fn status_line(s: u16) -> &'static [u8] {
    match s {
        200 => b"HTTP/1.1 200 OK\r\n",
        201 => b"HTTP/1.1 201 Created\r\n",
        204 => b"HTTP/1.1 204 No Content\r\n",
        400 => b"HTTP/1.1 400 Bad Request\r\n",
        401 => b"HTTP/1.1 401 Unauthorized\r\n",
        403 => b"HTTP/1.1 403 Forbidden\r\n",
        404 => b"HTTP/1.1 404 Not Found\r\n",
        405 => b"HTTP/1.1 405 Method Not Allowed\r\n",
        413 => b"HTTP/1.1 413 Payload Too Large\r\n",
        422 => b"HTTP/1.1 422 Unprocessable Entity\r\n",
        431 => b"HTTP/1.1 431 Request Header Fields Too Large\r\n",
        503 => b"HTTP/1.1 503 Service Unavailable\r\n",
        _ => b"HTTP/1.1 500 Internal Server Error\r\n",
    }
}

/// What one parse of the input found.
enum Parsed {
    /// a whole request: dispatched; `used` bytes consumed
    Request { used: usize, outcome: Outcome, keep_alive: bool },
    /// need more bytes
    Partial { expect_continue: bool },
    /// malformed or too large: answer `status` and close
    Bad(u16),
}

impl Server {
    pub fn new(thread: u16, lfd: RawFd, efd: RawFd, keys: &'static crate::jwt::Keys) -> io::Result<Server> {
        let ep = cvt(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?;
        let s = Server { thread, ep, lfd, conns: Vec::new(), free: Vec::new(), scratch: vec![0; SCRATCH], keys };
        s.ctl(libc::EPOLL_CTL_ADD, lfd, libc::EPOLLIN as u32, LISTENER)?;
        s.ctl(libc::EPOLL_CTL_ADD, efd, libc::EPOLLIN as u32, OUTBOX)?;
        Ok(s)
    }

    fn ctl(&self, op: i32, fd: RawFd, events: u32, data: u64) -> io::Result<()> {
        let mut ev = libc::epoll_event { events, u64: data };
        cvt(unsafe { libc::epoll_ctl(self.ep, op, fd, &mut ev) }).map(|_| ())
    }

    pub fn run(mut self) {
        let mut events = vec![libc::epoll_event { events: 0, u64: 0 }; 1024];
        let mut replies: Vec<Response> = Vec::with_capacity(1024);
        loop {
            let n = unsafe { libc::epoll_wait(self.ep, events.as_mut_ptr(), events.len() as i32, -1) };
            if n < 0 {
                if errno() == libc::EINTR {
                    continue;
                }
                panic!("epoll_wait: {}", io::Error::last_os_error());
            }
            for ev in &events[..n as usize] {
                let (bits, data) = (ev.events, ev.u64);
                match data {
                    LISTENER => self.accept(),
                    OUTBOX => {
                        reply::drain(self.thread as usize, &mut replies);
                        for r in replies.drain(..) {
                            self.deliver(r);
                        }
                    }
                    slot => {
                        let slot = slot as u32;
                        if bits & libc::EPOLLOUT as u32 != 0 {
                            self.flush(slot);
                        }
                        if bits & (libc::EPOLLIN | libc::EPOLLHUP | libc::EPOLLERR | libc::EPOLLRDHUP) as u32 != 0 {
                            self.readable(slot);
                        }
                    }
                }
            }
        }
    }

    fn accept(&mut self) {
        loop {
            let fd = unsafe {
                libc::accept4(self.lfd, std::ptr::null_mut(), std::ptr::null_mut(), libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC)
            };
            if fd < 0 {
                match errno() {
                    libc::EAGAIN => return,
                    libc::EINTR | libc::ECONNABORTED => continue,
                    _ => {
                        // EMFILE and friends: back off this round, the listener stays readable
                        eprintln!("accept: {}", io::Error::last_os_error());
                        return;
                    }
                }
            }
            let one: libc::c_int = 1;
            unsafe { libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &one as *const _ as *const libc::c_void, 4) };
            let slot = match self.free.pop() {
                Some(s) => s,
                None => {
                    self.conns.push(Conn::default());
                    (self.conns.len() - 1) as u32
                }
            };
            let c = &mut self.conns[slot as usize];
            let generation = c.generation;
            *c = Conn { fd, generation, ..Conn::default() };
            if self.ctl(libc::EPOLL_CTL_ADD, fd, (libc::EPOLLIN | libc::EPOLLRDHUP) as u32, slot as u64).is_err() {
                self.close(slot);
            }
        }
    }

    fn close(&mut self, slot: u32) {
        let c = &mut self.conns[slot as usize];
        if c.fd < 0 {
            return;
        }
        unsafe { libc::close(c.fd) };
        let generation = c.generation.wrapping_add(1);
        *c = Conn { fd: -1, generation, ..Conn::default() };
        self.free.push(slot);
    }

    fn readable(&mut self, slot: u32) {
        let mut scratch = std::mem::take(&mut self.scratch);
        loop {
            let fd = self.conns[slot as usize].fd;
            if fd < 0 {
                break;
            }
            let n = unsafe { libc::read(fd, scratch.as_mut_ptr() as *mut libc::c_void, scratch.len()) };
            if n < 0 {
                match errno() {
                    libc::EAGAIN => break,
                    libc::EINTR => continue,
                    _ => {
                        self.close(slot);
                        break;
                    }
                }
            }
            if n == 0 {
                let c = &mut self.conns[slot as usize];
                c.peer_closed = true;
                if c.busy || c.out_pos < c.out.len() {
                    let _ = self.ctl(libc::EPOLL_CTL_MOD, fd, 0, slot as u64);
                    self.after_write(slot);
                } else {
                    self.close(slot);
                }
                break;
            }
            let n = n as usize;
            let c = &mut self.conns[slot as usize];
            if c.pending.is_empty() && !c.busy {
                // the usual case: parse straight from the scratch buffer, keep only what's left over
                let used = self.parse_all(slot, &scratch[..n]);
                let c = &mut self.conns[slot as usize];
                if c.fd >= 0 && used < n {
                    c.pending.extend_from_slice(&scratch[used..n]);
                }
            } else {
                c.pending.extend_from_slice(&scratch[..n]);
                self.process_pending(slot);
            }
            if n < scratch.len() {
                break;
            }
        }
        self.scratch = scratch;
    }

    /// Parses requests out of `buf` while the connection is free; returns how many bytes were consumed.
    fn parse_all(&mut self, slot: u32, buf: &[u8]) -> usize {
        let mut at = 0;
        while at < buf.len() {
            let c = &self.conns[slot as usize];
            if c.fd < 0 || c.busy {
                break;
            }
            match self.parse_one(slot, &buf[at..]) {
                Parsed::Request { used, outcome, keep_alive } => {
                    at += used;
                    let c = &mut self.conns[slot as usize];
                    c.sent_continue = false;
                    c.close_after = !keep_alive;
                    c.busy = true;
                    if let Outcome::Now(status, body) = outcome {
                        self.respond(slot, status, &body);
                    }
                }
                Parsed::Partial { expect_continue } => {
                    let c = &mut self.conns[slot as usize];
                    if buf.len() - at > MAX_HEAD + MAX_BODY {
                        self.bad(slot, 413);
                        return buf.len();
                    }
                    if expect_continue && !c.sent_continue {
                        c.sent_continue = true;
                        self.write_raw(slot, b"HTTP/1.1 100 Continue\r\n\r\n");
                    }
                    break;
                }
                Parsed::Bad(status) => {
                    self.bad(slot, status);
                    return buf.len();
                }
            }
        }
        at
    }

    /// Parses from the connection's pending bytes (after a split read, or once a busy connection frees up).
    fn process_pending(&mut self, slot: u32) {
        let c = &mut self.conns[slot as usize];
        if c.fd < 0 || c.busy || c.pending.is_empty() {
            return;
        }
        let buf = std::mem::take(&mut c.pending);
        let used = self.parse_all(slot, &buf);
        let c = &mut self.conns[slot as usize];
        if c.fd >= 0 && used < buf.len() {
            let mut rest = buf;
            rest.drain(..used);
            c.pending = rest;
        }
    }

    fn parse_one(&mut self, slot: u32, buf: &[u8]) -> Parsed {
        let mut headers = [httparse::EMPTY_HEADER; 32];
        let mut req = httparse::Request::new(&mut headers);
        let head = match req.parse(buf) {
            Ok(httparse::Status::Complete(n)) => n,
            Ok(httparse::Status::Partial) => {
                return if buf.len() > MAX_HEAD { Parsed::Bad(431) } else { Parsed::Partial { expect_continue: false } };
            }
            Err(httparse::Error::TooManyHeaders) => return Parsed::Bad(431),
            Err(_) => return Parsed::Bad(400),
        };
        let mut keep_alive = req.version == Some(1);
        let mut length: Option<usize> = None;
        let mut chunked = false;
        let mut auth: Option<&[u8]> = None;
        let mut expect_continue = false;
        for h in req.headers.iter() {
            let name = h.name.as_bytes();
            if name.eq_ignore_ascii_case(b"content-length") {
                match std::str::from_utf8(h.value).ok().and_then(|s| s.trim().parse::<usize>().ok()) {
                    Some(n) if length.is_none_or(|l| l == n) => length = Some(n),
                    _ => return Parsed::Bad(400),
                }
            } else if name.eq_ignore_ascii_case(b"transfer-encoding") {
                if !h.value.eq_ignore_ascii_case(b"chunked") {
                    return Parsed::Bad(400);
                }
                chunked = true;
            } else if name.eq_ignore_ascii_case(b"authorization") {
                auth = Some(h.value);
            } else if name.eq_ignore_ascii_case(b"connection") {
                if h.value.eq_ignore_ascii_case(b"close") {
                    keep_alive = false;
                } else if h.value.eq_ignore_ascii_case(b"keep-alive") {
                    keep_alive = true;
                }
            } else if name.eq_ignore_ascii_case(b"expect") {
                expect_continue = h.value.eq_ignore_ascii_case(b"100-continue");
            }
        }
        if chunked && length.is_some() {
            return Parsed::Bad(400);
        }
        let decoded;
        let (body, used): (&[u8], usize) = if chunked {
            match dechunk(&buf[head..]) {
                Chunk::Done(b, n) => {
                    decoded = b;
                    (&decoded[..], head + n)
                }
                Chunk::More => return Parsed::Partial { expect_continue },
                Chunk::TooBig => return Parsed::Bad(413),
                Chunk::Bad => return Parsed::Bad(400),
            }
        } else {
            let len = length.unwrap_or(0);
            if len > MAX_BODY {
                return Parsed::Bad(413);
            }
            if buf.len() < head + len {
                return Parsed::Partial { expect_continue };
            }
            (&buf[head..head + len], head + len)
        };
        let target = req.path.unwrap_or("").as_bytes();
        let (path, query) = match memchr::memchr(b'?', target) {
            Some(i) => (&target[..i], &target[i + 1..]),
            None => (target, &b""[..]),
        };
        let c = &self.conns[slot as usize];
        let to = Addr { thread: self.thread, slot, generation: c.generation };
        let r = api::Request { method: req.method.unwrap_or("").as_bytes(), path, query, auth, body };
        let outcome = api::handle(self.keys, &r, to);
        Parsed::Request { used, outcome, keep_alive }
    }

    fn bad(&mut self, slot: u32, status: u16) {
        let c = &mut self.conns[slot as usize];
        c.close_after = true;
        c.busy = true;
        c.pending = Vec::new();
        let body = reply::error_body(match status {
            413 => "request too large",
            431 => "headers too large",
            _ => "bad request",
        });
        self.respond(slot, status, &body);
    }

    /// A response from a database thread: only for the connection (and generation) that asked.
    fn deliver(&mut self, r: Response) {
        let Some(c) = self.conns.get(r.to.slot as usize) else { return };
        if c.fd < 0 || c.generation != r.to.generation || !c.busy {
            return;
        }
        self.respond(r.to.slot, r.status, &r.body);
        self.process_pending(r.to.slot);
    }

    fn respond(&mut self, slot: u32, status: u16, body: &[u8]) {
        let c = &mut self.conns[slot as usize];
        c.busy = false;
        let mut head = [0u8; 192];
        let mut n = 0;
        let mut put = |b: &[u8]| {
            head[n..n + b.len()].copy_from_slice(b);
            n += b.len();
        };
        put(status_line(status));
        if status != 204 {
            put(b"Content-Type: application/json\r\nContent-Length: ");
            put(itoa::Buffer::new().format(body.len()).as_bytes());
            put(b"\r\n");
        }
        if c.close_after {
            put(b"Connection: close\r\n");
        }
        put(b"\r\n");
        let body = if status == 204 { &[][..] } else { body };
        if c.out_pos < c.out.len() {
            c.out.extend_from_slice(&head[..n]);
            c.out.extend_from_slice(body);
        } else {
            let iov = [
                libc::iovec { iov_base: head.as_ptr() as *mut libc::c_void, iov_len: n },
                libc::iovec { iov_base: body.as_ptr() as *mut libc::c_void, iov_len: body.len() },
            ];
            let w = unsafe { libc::writev(c.fd, iov.as_ptr(), if body.is_empty() { 1 } else { 2 }) };
            let w = if w < 0 {
                if errno() != libc::EAGAIN {
                    self.close(slot);
                    return;
                }
                0
            } else {
                w as usize
            };
            if w < n + body.len() {
                c.out.clear();
                c.out_pos = 0;
                if w < n {
                    c.out.extend_from_slice(&head[w..n]);
                    c.out.extend_from_slice(body);
                } else {
                    c.out.extend_from_slice(&body[w - n..]);
                }
            }
        }
        self.after_write(slot);
    }

    fn write_raw(&mut self, slot: u32, bytes: &[u8]) {
        let c = &mut self.conns[slot as usize];
        if c.out_pos < c.out.len() {
            c.out.extend_from_slice(bytes);
        } else {
            let w = unsafe { libc::write(c.fd, bytes.as_ptr() as *const libc::c_void, bytes.len()) };
            let w = if w < 0 { 0 } else { w as usize };
            if w < bytes.len() {
                c.out.clear();
                c.out_pos = 0;
                c.out.extend_from_slice(&bytes[w..]);
            }
        }
        self.after_write(slot);
    }

    fn flush(&mut self, slot: u32) {
        let c = &mut self.conns[slot as usize];
        if c.fd < 0 {
            return;
        }
        while c.out_pos < c.out.len() {
            let w = unsafe { libc::write(c.fd, c.out[c.out_pos..].as_ptr() as *const libc::c_void, c.out.len() - c.out_pos) };
            if w < 0 {
                if errno() == libc::EAGAIN {
                    break;
                }
                self.close(slot);
                return;
            }
            c.out_pos += w as usize;
        }
        self.after_write(slot);
    }

    /// Updates write interest; closes once a `Connection: close` (or half-closed) response has fully gone out.
    fn after_write(&mut self, slot: u32) {
        let c = &mut self.conns[slot as usize];
        if c.fd < 0 {
            return;
        }
        let pending = c.out_pos < c.out.len();
        if !pending {
            if c.out.capacity() > 0 {
                c.out = Vec::new();
            }
            c.out_pos = 0;
            if !c.busy && (c.close_after || c.peer_closed) {
                self.close(slot);
                return;
            }
        }
        if pending != c.polling_out {
            c.polling_out = pending;
            let ev = match (c.peer_closed, pending) {
                (true, true) => libc::EPOLLOUT,
                (true, false) => 0,
                (false, true) => libc::EPOLLIN | libc::EPOLLOUT | libc::EPOLLRDHUP,
                (false, false) => libc::EPOLLIN | libc::EPOLLRDHUP,
            };
            let fd = c.fd;
            let _ = self.ctl(libc::EPOLL_CTL_MOD, fd, ev as u32, slot as u64);
        }
    }
}

enum Chunk {
    Done(Vec<u8>, usize),
    More,
    TooBig,
    Bad,
}

/// A chunked body: the decoded bytes and how many input bytes (through the trailers' empty line) it used.
fn dechunk(b: &[u8]) -> Chunk {
    let mut out = Vec::new();
    let mut p = 0;
    loop {
        let Some(eol) = memchr::memmem::find(&b[p..], b"\r\n") else { return Chunk::More };
        let size = b[p..p + eol].split(|&c| c == b';').next().unwrap_or(b"");
        let Some(size) = std::str::from_utf8(size).ok().and_then(|s| usize::from_str_radix(s.trim(), 16).ok()) else {
            return Chunk::Bad;
        };
        p += eol + 2;
        if size == 0 {
            loop {
                let Some(eol) = memchr::memmem::find(&b[p..], b"\r\n") else { return Chunk::More };
                p += eol + 2;
                if eol == 0 {
                    return Chunk::Done(out, p);
                }
            }
        }
        if out.len() + size > MAX_BODY {
            return Chunk::TooBig;
        }
        if b.len() < p + size + 2 {
            return Chunk::More;
        }
        out.extend_from_slice(&b[p..p + size]);
        if &b[p + size..p + size + 2] != b"\r\n" {
            return Chunk::Bad;
        }
        p += size + 2;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunked() {
        match dechunk(b"4\r\nWiki\r\n5;x=y\r\npedia\r\n0\r\n\r\nNEXT") {
            Chunk::Done(b, n) => {
                assert_eq!(b, b"Wikipedia");
                assert_eq!(n, 28);
            }
            _ => panic!(),
        }
        assert!(matches!(dechunk(b"4\r\nWi"), Chunk::More));
        assert!(matches!(dechunk(b"zz\r\n"), Chunk::Bad));
    }
}
