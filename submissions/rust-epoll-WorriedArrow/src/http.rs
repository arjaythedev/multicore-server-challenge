//! HTTP/1.1 over raw epoll. One thread per listener (SO_REUSEPORT); a connection is owned by one thread for its
//! whole life. Idle connections hold no buffers: reads go through a per-thread scratch buffer and only a partial
//! request is copied into the connection.

use std::io;
use std::os::fd::RawFd;

use crate::api::{self, Outcome};
use crate::reply::{self, ReplyTo};

const LISTENER: u64 = u64::MAX;
const OUTBOX: u64 = u64::MAX - 1;
const MAX_HEAD: usize = 64 * 1024;
const MAX_BODY: usize = 1024 * 1024;

struct Conn {
    fd: RawFd,
    generation: u32,
    /// unparsed input (a partial request, or pipelined requests waiting for the one in flight)
    inbuf: Vec<u8>,
    /// unsent output
    outbuf: Vec<u8>,
    out_pos: usize,
    busy: bool,
    close_after: bool,
    peer_closed: bool,
    want_out: bool,
    sent_continue: bool,
}

pub struct Server {
    thread: u16,
    ep: RawFd,
    lfd: RawFd,
    efd: RawFd,
    conns: Vec<Conn>,
    free: Vec<u32>,
    scratch: Vec<u8>,
    keys: &'static crate::jwt::Keys,
}

fn cvt(r: i32) -> io::Result<i32> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

/// A non-blocking SO_REUSEPORT listener on HOST:PORT. An IPv6 HOST ("::") listens dual-stack.
pub fn listener(host: &str, port: u16) -> io::Result<RawFd> {
    let ip: std::net::IpAddr = host.parse().map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "HOST must be an IP address"))?;
    unsafe {
        let family = if ip.is_ipv4() { libc::AF_INET } else { libc::AF_INET6 };
        let fd = cvt(libc::socket(family, libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC, 0))?;
        let one: libc::c_int = 1;
        let zero: libc::c_int = 0;
        for opt in [libc::SO_REUSEADDR, libc::SO_REUSEPORT] {
            cvt(libc::setsockopt(fd, libc::SOL_SOCKET, opt, &one as *const _ as *const libc::c_void, 4))?;
        }
        match ip {
            std::net::IpAddr::V4(v4) => {
                let addr = libc::sockaddr_in {
                    sin_family: libc::AF_INET as u16,
                    sin_port: port.to_be(),
                    sin_addr: libc::in_addr { s_addr: u32::from_ne_bytes(v4.octets()) },
                    sin_zero: [0; 8],
                };
                cvt(libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in>() as u32))?;
            }
            std::net::IpAddr::V6(v6) => {
                cvt(libc::setsockopt(fd, libc::IPPROTO_IPV6, libc::IPV6_V6ONLY, &zero as *const _ as *const libc::c_void, 4))?;
                let addr = libc::sockaddr_in6 {
                    sin6_family: libc::AF_INET6 as u16,
                    sin6_port: port.to_be(),
                    sin6_flowinfo: 0,
                    sin6_addr: libc::in6_addr { s6_addr: v6.octets() },
                    sin6_scope_id: 0,
                };
                cvt(libc::bind(fd, &addr as *const _ as *const libc::sockaddr, std::mem::size_of::<libc::sockaddr_in6>() as u32))?;
            }
        }
        cvt(libc::listen(fd, 65535))?;
        Ok(fd)
    }
}

fn status_text(s: u16) -> &'static str {
    match s {
        100 => "100 Continue",
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        413 => "413 Payload Too Large",
        422 => "422 Unprocessable Entity",
        431 => "431 Request Header Fields Too Large",
        _ => "500 Internal Server Error",
    }
}

impl Server {
    pub fn new(thread: u16, lfd: RawFd, keys: &'static crate::jwt::Keys) -> io::Result<Server> {
        let ep = cvt(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?;
        let efd = reply::outbox(thread as usize).efd;
        let s = Server { thread, ep, lfd, efd, conns: Vec::new(), free: Vec::new(), scratch: vec![0; 256 * 1024], keys };
        s.ctl(libc::EPOLL_CTL_ADD, lfd, libc::EPOLLIN as u32, LISTENER)?;
        s.ctl(libc::EPOLL_CTL_ADD, efd, libc::EPOLLIN as u32, OUTBOX)?;
        Ok(s)
    }

    fn ctl(&self, op: i32, fd: RawFd, events: u32, data: u64) -> io::Result<()> {
        let mut ev = libc::epoll_event { events, u64: data };
        cvt(unsafe { libc::epoll_ctl(self.ep, op, fd, &mut ev) })?;
        Ok(())
    }

    pub fn run(mut self) {
        let mut events: Vec<libc::epoll_event> = vec![libc::epoll_event { events: 0, u64: 0 }; 1024];
        loop {
            let n = unsafe { libc::epoll_wait(self.ep, events.as_mut_ptr(), events.len() as i32, -1) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                panic!("epoll_wait: {e}");
            }
            for i in 0..n as usize {
                let ev = events[i];
                match ev.u64 {
                    LISTENER => self.accept(),
                    OUTBOX => self.drain_outbox(),
                    slot => {
                        let slot = slot as u32;
                        if ev.events & (libc::EPOLLOUT as u32) != 0 {
                            self.flush(slot);
                        }
                        if ev.events & (libc::EPOLLIN as u32 | libc::EPOLLHUP as u32 | libc::EPOLLERR as u32 | libc::EPOLLRDHUP as u32) != 0 {
                            self.on_readable(slot);
                        }
                    }
                }
            }
        }
    }

    fn accept(&mut self) {
        loop {
            let fd = unsafe { libc::accept4(self.lfd, std::ptr::null_mut(), std::ptr::null_mut(), libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC) };
            if fd < 0 {
                let e = io::Error::last_os_error();
                match e.raw_os_error() {
                    Some(libc::EAGAIN) => return,
                    Some(libc::EINTR) | Some(libc::ECONNABORTED) => continue,
                    _ => {
                        eprintln!("accept: {e}");
                        return;
                    }
                }
            }
            let one: libc::c_int = 1;
            unsafe {
                libc::setsockopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, &one as *const _ as *const libc::c_void, 4);
            }
            let slot = match self.free.pop() {
                Some(s) => {
                    let c = &mut self.conns[s as usize];
                    c.fd = fd;
                    c.busy = false;
                    c.close_after = false;
                    c.peer_closed = false;
                    c.want_out = false;
                    c.sent_continue = false;
                    c.out_pos = 0;
                    s
                }
                None => {
                    self.conns.push(Conn {
                        fd,
                        generation: 0,
                        inbuf: Vec::new(),
                        outbuf: Vec::new(),
                        out_pos: 0,
                        busy: false,
                        close_after: false,
                        peer_closed: false,
                        want_out: false,
                        sent_continue: false,
                    });
                    (self.conns.len() - 1) as u32
                }
            };
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
        unsafe {
            libc::close(c.fd);
        }
        c.fd = -1;
        c.generation = c.generation.wrapping_add(1);
        c.inbuf = Vec::new();
        c.outbuf = Vec::new();
        c.out_pos = 0;
        c.busy = false;
        self.free.push(slot);
    }

    fn on_readable(&mut self, slot: u32) {
        loop {
            let fd = self.conns[slot as usize].fd;
            if fd < 0 {
                return;
            }
            let n = unsafe { libc::read(fd, self.scratch.as_mut_ptr() as *mut libc::c_void, self.scratch.len()) };
            if n < 0 {
                let e = io::Error::last_os_error();
                match e.raw_os_error() {
                    Some(libc::EAGAIN) => break,
                    Some(libc::EINTR) => continue,
                    _ => {
                        self.close(slot);
                        return;
                    }
                }
            }
            if n == 0 {
                let c = &mut self.conns[slot as usize];
                c.peer_closed = true;
                if !c.busy {
                    self.close(slot);
                } else {
                    // stop polling input; close once the in-flight response is done
                    let _ = self.ctl(libc::EPOLL_CTL_MOD, fd, 0, slot as u64);
                }
                return;
            }
            let n = n as usize;
            let c = &mut self.conns[slot as usize];
            c.inbuf.extend_from_slice(&self.scratch[..n]);
            if n < self.scratch.len() {
                break;
            }
        }
        self.process(slot);
    }

    /// Parses and dispatches as many requests as possible (one at a time per connection).
    fn process(&mut self, slot: u32) {
        loop {
            let c = &mut self.conns[slot as usize];
            if c.fd < 0 || c.busy || c.inbuf.is_empty() {
                if c.fd >= 0 && c.inbuf.capacity() > 0 && c.inbuf.is_empty() {
                    c.inbuf = Vec::new();
                }
                return;
            }
            let mut headers = [httparse::EMPTY_HEADER; 32];
            let mut req = httparse::Request::new(&mut headers);
            let head_len = match req.parse(&c.inbuf) {
                Ok(httparse::Status::Complete(n)) => n,
                Ok(httparse::Status::Partial) => {
                    if c.inbuf.len() > MAX_HEAD {
                        self.fail(slot, 431);
                    }
                    return;
                }
                Err(_) => {
                    self.fail(slot, 400);
                    return;
                }
            };
            let http10 = req.version == Some(0);
            let mut content_length: Option<usize> = None;
            let mut chunked = false;
            let mut auth: Option<(usize, usize)> = None;
            let mut keep_alive = !http10;
            let mut expect_continue = false;
            let base = c.inbuf.as_ptr() as usize;
            for h in req.headers.iter() {
                let name = h.name.as_bytes();
                if name.eq_ignore_ascii_case(b"content-length") {
                    match std::str::from_utf8(h.value).ok().and_then(|s| s.trim().parse().ok()) {
                        Some(n) => content_length = Some(n),
                        None => {
                            self.fail(slot, 400);
                            return;
                        }
                    }
                } else if name.eq_ignore_ascii_case(b"transfer-encoding") {
                    chunked = h.value.eq_ignore_ascii_case(b"chunked");
                    if !chunked {
                        self.fail(slot, 400);
                        return;
                    }
                } else if name.eq_ignore_ascii_case(b"authorization") {
                    let start = h.value.as_ptr() as usize - base;
                    auth = Some((start, h.value.len()));
                } else if name.eq_ignore_ascii_case(b"connection") {
                    let v = h.value;
                    if v.eq_ignore_ascii_case(b"close") {
                        keep_alive = false;
                    } else if v.eq_ignore_ascii_case(b"keep-alive") {
                        keep_alive = true;
                    }
                } else if name.eq_ignore_ascii_case(b"expect") {
                    expect_continue = h.value.eq_ignore_ascii_case(b"100-continue");
                }
            }
            if chunked && content_length.is_some() {
                self.fail(slot, 400);
                return;
            }
            let method = req.method.unwrap_or("").as_bytes();
            let target = req.path.unwrap_or("").as_bytes();
            let mstart = method.as_ptr() as usize - base;
            let mlen = method.len();
            let tstart = target.as_ptr() as usize - base;
            let tlen = target.len();
            // body
            let (body_range, consumed): ((usize, usize), usize);
            let decoded: Option<Vec<u8>>;
            if chunked {
                match dechunk(&c.inbuf[head_len..]) {
                    Chunk::Done(body, used) => {
                        if body.len() > MAX_BODY {
                            self.fail(slot, 413);
                            return;
                        }
                        body_range = (0, body.len());
                        decoded = Some(body);
                        consumed = head_len + used;
                    }
                    Chunk::More => {
                        if c.inbuf.len() - head_len > MAX_BODY + 64 * 1024 {
                            self.fail(slot, 413);
                            return;
                        }
                        if expect_continue && !c.sent_continue {
                            c.sent_continue = true;
                            self.raw_send(slot, b"HTTP/1.1 100 Continue\r\n\r\n");
                        }
                        return;
                    }
                    Chunk::Bad => {
                        self.fail(slot, 400);
                        return;
                    }
                }
            } else {
                let cl = content_length.unwrap_or(0);
                if cl > MAX_BODY {
                    self.fail(slot, 413);
                    return;
                }
                if c.inbuf.len() < head_len + cl {
                    if expect_continue && !c.sent_continue {
                        c.sent_continue = true;
                        self.raw_send(slot, b"HTTP/1.1 100 Continue\r\n\r\n");
                    }
                    return;
                }
                body_range = (head_len, cl);
                decoded = None;
                consumed = head_len + cl;
            }
            let c = &mut self.conns[slot as usize];
            c.sent_continue = false;
            c.close_after = !keep_alive;
            c.busy = true;
            let to = ReplyTo { thread: self.thread, slot, generation: c.generation };
            let buf = &c.inbuf;
            let target = &buf[tstart..tstart + tlen];
            let (path, query) = match memchr::memchr(b'?', target) {
                Some(i) => (&target[..i], &target[i + 1..]),
                None => (target, &b""[..]),
            };
            let body: &[u8] = match &decoded {
                Some(d) => &d[body_range.0..body_range.0 + body_range.1],
                None => &buf[body_range.0..body_range.0 + body_range.1],
            };
            let r = api::Request {
                method: &buf[mstart..mstart + mlen],
                path,
                query,
                auth: auth.map(|(s, l)| &buf[s..s + l]),
                body,
            };
            let outcome = api::handle(self.keys, &r, to);
            let c = &mut self.conns[slot as usize];
            c.inbuf.drain(..consumed);
            match outcome {
                Outcome::Now(status, body) => self.respond(slot, status, &body),
                Outcome::Queued => return,
            }
        }
    }

    fn fail(&mut self, slot: u32, status: u16) {
        let c = &mut self.conns[slot as usize];
        c.close_after = true;
        c.busy = true;
        c.inbuf.clear();
        let body = reply::error_body(status_text(status));
        self.respond(slot, status, &body);
    }

    fn drain_outbox(&mut self) {
        let mut v: u64 = 0;
        unsafe {
            libc::read(self.efd, &mut v as *mut u64 as *mut libc::c_void, 8);
        }
        let batch = std::mem::take(&mut *reply::outbox(self.thread as usize).queue.lock().unwrap());
        let mut touched: Vec<u32> = Vec::with_capacity(batch.len());
        for r in batch {
            let c = &self.conns[r.to.slot as usize];
            if c.fd < 0 || c.generation != r.to.generation || !c.busy {
                continue;
            }
            self.respond(r.to.slot, r.status, &r.body);
            touched.push(r.to.slot);
        }
        for slot in touched {
            self.process(slot);
        }
    }

    fn respond(&mut self, slot: u32, status: u16, body: &[u8]) {
        let c = &mut self.conns[slot as usize];
        c.busy = false;
        let mut head = [0u8; 160];
        let mut w = &mut head[..];
        use std::io::Write as _;
        if status == 204 {
            let _ = write!(w, "HTTP/1.1 {}\r\n{}\r\n", status_text(status), if c.close_after { "Connection: close\r\n" } else { "" });
        } else {
            let _ = write!(
                w,
                "HTTP/1.1 {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{}\r\n",
                status_text(status),
                body.len(),
                if c.close_after { "Connection: close\r\n" } else { "" }
            );
        }
        let hl = 160 - w.len();
        let fd = c.fd;
        if c.outbuf.len() > c.out_pos {
            c.outbuf.extend_from_slice(&head[..hl]);
            c.outbuf.extend_from_slice(body);
        } else {
            // try a direct vectored write
            let iov = [
                libc::iovec { iov_base: head.as_ptr() as *mut libc::c_void, iov_len: hl },
                libc::iovec { iov_base: body.as_ptr() as *mut libc::c_void, iov_len: body.len() },
            ];
            let total = hl + body.len();
            let n = unsafe { libc::writev(fd, iov.as_ptr(), if body.is_empty() { 1 } else { 2 }) };
            let n = if n < 0 {
                let e = io::Error::last_os_error();
                if e.raw_os_error() == Some(libc::EAGAIN) {
                    0
                } else {
                    self.close(slot);
                    return;
                }
            } else {
                n as usize
            };
            if n < total {
                c.outbuf.clear();
                c.out_pos = 0;
                if n < hl {
                    c.outbuf.extend_from_slice(&head[n..hl]);
                    c.outbuf.extend_from_slice(body);
                } else {
                    c.outbuf.extend_from_slice(&body[n - hl..]);
                }
            }
        }
        self.after_write(slot);
    }

    fn raw_send(&mut self, slot: u32, bytes: &[u8]) {
        let c = &mut self.conns[slot as usize];
        if c.outbuf.len() > c.out_pos {
            c.outbuf.extend_from_slice(bytes);
        } else {
            let n = unsafe { libc::write(c.fd, bytes.as_ptr() as *const libc::c_void, bytes.len()) };
            let n = if n < 0 { 0 } else { n as usize };
            if n < bytes.len() {
                c.outbuf.clear();
                c.out_pos = 0;
                c.outbuf.extend_from_slice(&bytes[n..]);
            }
        }
        self.after_write(slot);
    }

    fn flush(&mut self, slot: u32) {
        let c = &mut self.conns[slot as usize];
        if c.fd < 0 {
            return;
        }
        while c.out_pos < c.outbuf.len() {
            let n = unsafe { libc::write(c.fd, c.outbuf[c.out_pos..].as_ptr() as *const libc::c_void, c.outbuf.len() - c.out_pos) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.raw_os_error() == Some(libc::EAGAIN) {
                    break;
                }
                self.close(slot);
                return;
            }
            c.out_pos += n as usize;
        }
        self.after_write(slot);
    }

    /// Updates epoll interest and closes when a `Connection: close` response has fully gone out.
    fn after_write(&mut self, slot: u32) {
        let c = &mut self.conns[slot as usize];
        if c.fd < 0 {
            return;
        }
        let pending = c.out_pos < c.outbuf.len();
        if !pending {
            if c.outbuf.capacity() > 0 {
                c.outbuf = Vec::new();
            }
            c.out_pos = 0;
            if !c.busy && (c.close_after || c.peer_closed) {
                // only after the response, never while a request is in flight
                self.close(slot);
                return;
            }
        }
        if pending != c.want_out {
            c.want_out = pending;
            let ev = if pending { libc::EPOLLIN | libc::EPOLLOUT | libc::EPOLLRDHUP } else { libc::EPOLLIN | libc::EPOLLRDHUP };
            let ev = if c.peer_closed { if pending { libc::EPOLLOUT } else { 0 } } else { ev };
            let fd = c.fd;
            let _ = self.ctl(libc::EPOLL_CTL_MOD, fd, ev as u32, slot as u64);
        }
    }
}

enum Chunk {
    Done(Vec<u8>, usize),
    More,
    Bad,
}

/// Decodes a chunked body; returns the body and how many bytes (including the final CRLF / trailers) it used.
fn dechunk(b: &[u8]) -> Chunk {
    let mut out = Vec::new();
    let mut p = 0;
    loop {
        let Some(eol) = memchr::memmem::find(&b[p..], b"\r\n") else { return Chunk::More };
        let line = &b[p..p + eol];
        let size_part = line.split(|&c| c == b';').next().unwrap_or(b"");
        let Ok(s) = std::str::from_utf8(size_part) else { return Chunk::Bad };
        let Ok(size) = usize::from_str_radix(s.trim(), 16) else { return Chunk::Bad };
        p += eol + 2;
        if size == 0 {
            // trailers until an empty line
            loop {
                let Some(eol) = memchr::memmem::find(&b[p..], b"\r\n") else { return Chunk::More };
                p += eol + 2;
                if eol == 0 {
                    return Chunk::Done(out, p);
                }
            }
        }
        if size > MAX_BODY || out.len() + size > MAX_BODY {
            return Chunk::Done(vec![0; MAX_BODY + 1], p);
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
