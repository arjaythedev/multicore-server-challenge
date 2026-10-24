use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::os::fd::{AsRawFd, RawFd};

use ring::{digest, hmac, pbkdf2, rand::SecureRandom};

use crate::json;

pub const INT8: u32 = 20;
pub const TEXT: u32 = 25;
pub const TEXT_ARRAY: u32 = 1009;
pub const INT8_ARRAY: u32 = 1016;

pub struct PgConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
    pub options: String,
}

impl PgConfig {
    pub fn from_url(url: &str, options: String) -> Option<PgConfig> {
        let rest = url
            .strip_prefix("postgres://")
            .or_else(|| url.strip_prefix("postgresql://"))?;
        let (auth, rest) = rest.rsplit_once('@').unwrap_or(("", rest));
        let (user, password) = auth.split_once(':').unwrap_or((auth, ""));
        let (hostport, database) = rest.split_once('/').unwrap_or((rest, ""));
        let database = database.split('?').next().unwrap_or("");
        let (host, port) = match hostport.rsplit_once(':') {
            Some((h, p)) => (h, p.parse().ok()?),
            None => (hostport, 5432),
        };
        Some(PgConfig {
            host: if host.is_empty() {
                "127.0.0.1".into()
            } else {
                host.into()
            },
            port,
            user: pct_decode(user),
            password: pct_decode(password),
            database: pct_decode(database),
            options,
        })
    }
}

fn pct_decode(s: &str) -> String {
    let mut out = Vec::new();
    crate::http::pct_decode_into(s.as_bytes(), false, &mut out);
    String::from_utf8_lossy(&out).into_owned()
}

#[derive(Debug, Clone)]
pub struct PgError {
    pub code: [u8; 5],
    pub message: String,
}

impl PgError {
    pub fn is(&self, code: &str) -> bool {
        self.code == code.as_bytes()
    }
}

#[derive(Default)]
pub struct PgResult {
    data: Vec<u8>,
    rows: Vec<(u16, u32, u32)>,
    stmt: u16,
    pub err: Option<PgError>,
}

impl PgResult {
    pub fn failed(message: &str) -> PgResult {
        PgResult {
            err: Some(PgError {
                code: *b"08006",
                message: message.into(),
            }),
            ..PgResult::default()
        }
    }

    pub fn slice(&self, start: u16, n: u16) -> PgResult {
        let mut out = PgResult::default();
        for &(stmt, a, b) in &self.rows {
            if stmt >= start && stmt < start + n {
                let at = out.data.len() as u32;
                out.data
                    .extend_from_slice(&self.data[a as usize..b as usize]);
                out.rows.push((stmt - start, at, out.data.len() as u32));
            }
        }
        out
    }

    pub fn split_by_ordinal(&self, n: usize) -> Vec<PgResult> {
        let mut out: Vec<PgResult> = (0..n).map(|_| PgResult::default()).collect();
        for &(_, a, b) in &self.rows {
            let row = &self.data[a as usize..b as usize];
            let len = i32::from_be_bytes(row[2..6].try_into().unwrap()) as usize;
            let ord = i64::from_be_bytes(row[6..6 + len].try_into().unwrap()) as usize;
            let Some(dst) = out.get_mut(ord.wrapping_sub(1)) else {
                continue;
            };
            let at = dst.data.len() as u32;
            dst.data.extend_from_slice(&row[0..2]);
            dst.data.extend_from_slice(&row[6 + len..]);
            dst.rows.push((0, at, dst.data.len() as u32));
        }
        out
    }

    pub fn rows(&self, stmt: u16) -> impl Iterator<Item = Row<'_>> {
        self.rows.iter().filter(move |r| r.0 == stmt).map(|r| Row {
            b: &self.data[r.1 as usize..r.2 as usize],
            p: 2,
        })
    }

    pub fn error_only(&self) -> PgResult {
        PgResult {
            err: self.err.clone(),
            ..PgResult::default()
        }
    }

    pub fn is(&self, code: &str) -> bool {
        self.err.as_ref().is_some_and(|e| e.is(code))
    }

    pub fn first(&self, stmt: u16) -> Option<Row<'_>> {
        self.rows(stmt).next()
    }
}

pub struct Row<'a> {
    b: &'a [u8],
    p: usize,
}

impl<'a> Row<'a> {
    pub fn field(&mut self) -> Option<&'a [u8]> {
        let len = i32::from_be_bytes(self.b[self.p..self.p + 4].try_into().unwrap());
        self.p += 4;
        if len < 0 {
            return None;
        }
        let s = &self.b[self.p..self.p + len as usize];
        self.p += len as usize;
        Some(s)
    }

    pub fn next_is_null(&self) -> bool {
        self.b[self.p..self.p + 4] == [0xff; 4]
    }

    pub fn i64(&mut self) -> i64 {
        match self.field() {
            Some(f) if f.len() == 8 => i64::from_be_bytes(f.try_into().unwrap()),
            Some(f) if f.len() == 4 => i64::from(i32::from_be_bytes(f.try_into().unwrap())),
            _ => 0,
        }
    }

    pub fn boolean(&mut self) -> bool {
        matches!(self.field(), Some([1]))
    }

    pub fn text(&mut self) -> &'a [u8] {
        self.field().unwrap_or(b"")
    }

    pub fn opt_text(&mut self) -> Option<&'a [u8]> {
        self.field()
    }

    pub fn text_array(&mut self, out: &mut Vec<&'a [u8]>) {
        out.clear();
        let Some(a) = self.field() else {
            return;
        };
        let ndim = i32::from_be_bytes(a[0..4].try_into().unwrap());
        if ndim == 0 {
            return;
        }
        let n = i32::from_be_bytes(a[12..16].try_into().unwrap()) as usize;
        let mut p = 20;
        for _ in 0..n {
            let len = i32::from_be_bytes(a[p..p + 4].try_into().unwrap());
            p += 4;
            if len >= 0 {
                out.push(&a[p..p + len as usize]);
                p += len as usize;
            }
        }
    }
}

pub enum P<'a> {
    I64(i64),
    Text(&'a [u8]),
    OptText(Option<&'a [u8]>),
    TextArray(&'a [Vec<u8>]),
    I64Array(&'a [i64]),
}

fn put_i16(w: &mut Vec<u8>, v: i16) {
    w.extend_from_slice(&v.to_be_bytes());
}

fn put_i32(w: &mut Vec<u8>, v: i32) {
    w.extend_from_slice(&v.to_be_bytes());
}

fn begin_msg(w: &mut Vec<u8>, tag: u8) -> usize {
    w.push(tag);
    let at = w.len();
    put_i32(w, 0);
    at
}

fn end_msg(w: &mut [u8], at: usize) {
    let len = (w.len() - at) as i32;
    w[at..at + 4].copy_from_slice(&len.to_be_bytes());
}

pub fn bind_exec(w: &mut Vec<u8>, stmt: usize, params: &[P]) {
    let at = begin_msg(w, b'B');
    w.push(0);
    w.push(b's');
    json::int(w, stmt as i64);
    w.push(0);
    put_i16(w, 1);
    put_i16(w, 1);
    put_i16(w, params.len() as i16);
    for p in params {
        match p {
            P::I64(v) => {
                put_i32(w, 8);
                w.extend_from_slice(&v.to_be_bytes());
            }
            P::Text(s) | P::OptText(Some(s)) => {
                put_i32(w, s.len() as i32);
                w.extend_from_slice(s);
            }
            P::OptText(None) => put_i32(w, -1),
            P::TextArray(items) => {
                let at = array_header(w, TEXT, items.len());
                for it in items.iter() {
                    put_i32(w, it.len() as i32);
                    w.extend_from_slice(it);
                }
                end_param(w, at);
            }
            P::I64Array(items) => {
                let at = array_header(w, INT8, items.len());
                for it in items.iter() {
                    put_i32(w, 8);
                    w.extend_from_slice(&it.to_be_bytes());
                }
                end_param(w, at);
            }
        }
    }
    put_i16(w, 1);
    put_i16(w, 1);
    end_msg(w, at);
    let at = begin_msg(w, b'E');
    w.push(0);
    put_i32(w, 0);
    end_msg(w, at);
}

fn array_header(w: &mut Vec<u8>, elem: u32, n: usize) -> usize {
    let at = w.len();
    put_i32(w, 0);
    put_i32(w, 1);
    put_i32(w, 0);
    put_i32(w, elem as i32);
    put_i32(w, n as i32);
    put_i32(w, 1);
    at
}

fn end_param(w: &mut [u8], at: usize) {
    let len = (w.len() - at - 4) as i32;
    w[at..at + 4].copy_from_slice(&len.to_be_bytes());
}

const SYNC: [u8; 5] = [b'S', 0, 0, 0, 4];

pub struct PgConn<J> {
    stream: TcpStream,
    pub fd: RawFd,
    rbuf: Vec<u8>,
    rpos: usize,
    wbuf: Vec<u8>,
    wpos: usize,
    pub inflight: VecDeque<(J, PgResult)>,
    pub broken: bool,
}

fn read_msg(s: &mut TcpStream) -> io::Result<(u8, Vec<u8>)> {
    let mut head = [0u8; 5];
    s.read_exact(&mut head)?;
    let len = i32::from_be_bytes(head[1..5].try_into().unwrap()) as usize;
    let mut body = vec![0u8; len - 4];
    s.read_exact(&mut body)?;
    Ok((head[0], body))
}

fn parse_error(body: &[u8]) -> PgError {
    let mut err = PgError {
        code: *b"XX000",
        message: String::new(),
    };
    for field in body.split(|&c| c == 0) {
        match field.first() {
            Some(b'C') if field.len() == 6 => err.code.copy_from_slice(&field[1..6]),
            Some(b'M') => err.message = String::from_utf8_lossy(&field[1..]).into_owned(),
            _ => {}
        }
    }
    err
}

fn other(msg: impl Into<String>) -> io::Error {
    io::Error::other(msg.into())
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> Vec<u8> {
    hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, key), data)
        .as_ref()
        .to_vec()
}

fn scram(s: &mut TcpStream, password: &str) -> io::Result<()> {
    let mut raw = [0u8; 18];
    ring::rand::SystemRandom::new()
        .fill(&mut raw)
        .map_err(|_| other("rng"))?;
    let mut nonce = Vec::new();
    json::b64_encode(&mut nonce, &raw);
    let nonce = String::from_utf8(nonce).unwrap();
    let client_first_bare = format!("n=,r={nonce}");
    let client_first = format!("n,,{client_first_bare}");
    let mut w = Vec::new();
    let at = begin_msg(&mut w, b'p');
    w.extend_from_slice(b"SCRAM-SHA-256\0");
    put_i32(&mut w, client_first.len() as i32);
    w.extend_from_slice(client_first.as_bytes());
    end_msg(&mut w, at);
    s.write_all(&w)?;

    let (tag, body) = read_msg(s)?;
    if tag == b'E' {
        return Err(other(parse_error(&body).message));
    }
    let server_first = String::from_utf8_lossy(&body[4..]).into_owned();
    let mut r = "";
    let mut salt = Vec::new();
    let mut iters = 0u32;
    for part in server_first.split(',') {
        if let Some(v) = part.strip_prefix("r=") {
            r = v;
        } else if let Some(v) = part.strip_prefix("s=") {
            json::b64_decode(v.as_bytes(), &mut salt);
        } else if let Some(v) = part.strip_prefix("i=") {
            iters = v.parse().unwrap_or(0);
        }
    }
    if !r.starts_with(&nonce) || iters == 0 {
        return Err(other("bad SCRAM server-first message"));
    }
    let mut salted = [0u8; 32];
    pbkdf2::derive(
        pbkdf2::PBKDF2_HMAC_SHA256,
        std::num::NonZeroU32::new(iters).unwrap(),
        &salt,
        password.as_bytes(),
        &mut salted,
    );
    let client_key = hmac_sha256(&salted, b"Client Key");
    let stored_key = digest::digest(&digest::SHA256, &client_key);
    let without_proof = format!("c=biws,r={r}");
    let auth_message = format!("{client_first_bare},{server_first},{without_proof}");
    let signature = hmac_sha256(stored_key.as_ref(), auth_message.as_bytes());
    let proof: Vec<u8> = client_key
        .iter()
        .zip(&signature)
        .map(|(a, b)| a ^ b)
        .collect();
    let mut fin = without_proof.into_bytes();
    fin.extend_from_slice(b",p=");
    json::b64_encode(&mut fin, &proof);
    let mut w = Vec::new();
    let at = begin_msg(&mut w, b'p');
    w.extend_from_slice(&fin);
    end_msg(&mut w, at);
    s.write_all(&w)
}

fn startup(cfg: &PgConfig) -> io::Result<TcpStream> {
    let mut s = TcpStream::connect((cfg.host.as_str(), cfg.port))?;
    s.set_nodelay(true)?;
    let mut w = Vec::new();
    put_i32(&mut w, 0);
    put_i32(&mut w, 196608);
    for (k, v) in [
        ("user", cfg.user.as_str()),
        ("database", cfg.database.as_str()),
        ("options", cfg.options.as_str()),
        ("application_name", "conduit"),
    ] {
        w.extend_from_slice(k.as_bytes());
        w.push(0);
        w.extend_from_slice(v.as_bytes());
        w.push(0);
    }
    w.push(0);
    let len = w.len() as i32;
    w[0..4].copy_from_slice(&len.to_be_bytes());
    s.write_all(&w)?;
    loop {
        let (tag, body) = read_msg(&mut s)?;
        match tag {
            b'R' => match i32::from_be_bytes(body[0..4].try_into().unwrap()) {
                0 | 12 => {}
                3 => {
                    let mut w = Vec::new();
                    let at = begin_msg(&mut w, b'p');
                    w.extend_from_slice(cfg.password.as_bytes());
                    w.push(0);
                    end_msg(&mut w, at);
                    s.write_all(&w)?;
                }
                10 => scram(&mut s, &cfg.password)?,
                n => return Err(other(format!("unsupported auth method {n}"))),
            },
            b'E' => return Err(other(parse_error(&body).message)),
            b'Z' => return Ok(s),
            _ => {}
        }
    }
}

fn query_text(s: &mut TcpStream, sql: &str) -> io::Result<Vec<String>> {
    let mut w = Vec::new();
    let at = begin_msg(&mut w, b'Q');
    w.extend_from_slice(sql.as_bytes());
    w.push(0);
    end_msg(&mut w, at);
    s.write_all(&w)?;
    let mut out = Vec::new();
    let mut err = None;
    loop {
        let (tag, body) = read_msg(s)?;
        match tag {
            b'D' => {
                let len = i32::from_be_bytes(body[2..6].try_into().unwrap());
                if len >= 0 {
                    out.push(String::from_utf8_lossy(&body[6..6 + len as usize]).into_owned());
                }
            }
            b'E' => err = Some(parse_error(&body)),
            b'Z' => break,
            _ => {}
        }
    }
    match err {
        Some(e) => Err(other(e.message)),
        None => Ok(out),
    }
}

pub fn probe_collation(cfg: &PgConfig) -> io::Result<String> {
    let mut s = startup(cfg)?;
    let rows = query_text(
        &mut s,
        "SELECT datcollate FROM pg_database WHERE datname = current_database()",
    )?;
    Ok(rows.into_iter().next().unwrap_or_default())
}

impl<J> PgConn<J> {
    pub fn connect(cfg: &PgConfig, statements: &[(String, Vec<u32>)]) -> io::Result<PgConn<J>> {
        let mut s = startup(cfg)?;
        let mut w = Vec::new();
        for (i, (sql, types)) in statements.iter().enumerate() {
            let at = begin_msg(&mut w, b'P');
            w.push(b's');
            json::int(&mut w, i as i64);
            w.push(0);
            w.extend_from_slice(sql.as_bytes());
            w.push(0);
            put_i16(&mut w, types.len() as i16);
            for &t in types {
                put_i32(&mut w, t as i32);
            }
            end_msg(&mut w, at);
        }
        w.extend_from_slice(&SYNC);
        s.write_all(&w)?;
        let mut parsed = 0;
        loop {
            let (tag, body) = read_msg(&mut s)?;
            match tag {
                b'1' => parsed += 1,
                b'E' => {
                    let e = parse_error(&body);
                    return Err(other(format!(
                        "prepare s{parsed}: {} ({})\n{}",
                        e.message,
                        String::from_utf8_lossy(&e.code),
                        statements[parsed].0
                    )));
                }
                b'Z' => break,
                _ => {}
            }
        }
        s.set_nonblocking(true)?;
        Ok(PgConn {
            fd: s.as_raw_fd(),
            stream: s,
            rbuf: Vec::with_capacity(64 * 1024),
            rpos: 0,
            wbuf: Vec::with_capacity(16 * 1024),
            wpos: 0,
            inflight: VecDeque::new(),
            broken: false,
        })
    }

    pub fn send(&mut self, msgs: &[u8], job: J) {
        self.wbuf.extend_from_slice(msgs);
        self.wbuf.extend_from_slice(&SYNC);
        self.inflight.push_back((job, PgResult::default()));
    }

    pub fn wants_flush(&self) -> bool {
        self.wpos < self.wbuf.len()
    }

    pub fn flush(&mut self) {
        while self.wpos < self.wbuf.len() {
            match self.stream.write(&self.wbuf[self.wpos..]) {
                Ok(0) => {
                    self.broken = true;
                    return;
                }
                Ok(n) => self.wpos += n,
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => return,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    self.broken = true;
                    return;
                }
            }
        }
        self.wbuf.clear();
        self.wpos = 0;
    }

    pub fn on_readable(&mut self, done: &mut Vec<(J, PgResult)>) {
        loop {
            if self.rbuf.capacity() - self.rbuf.len() < 16 * 1024 {
                self.rbuf.reserve(64 * 1024);
            }
            let len = self.rbuf.len();
            let spare = self.rbuf.capacity() - len;
            let n = unsafe {
                libc::read(
                    self.fd,
                    self.rbuf.as_mut_ptr().add(len) as *mut libc::c_void,
                    spare,
                )
            };
            if n > 0 {
                unsafe { self.rbuf.set_len(len + n as usize) };
                continue;
            }
            if n == 0 {
                self.broken = true;
                break;
            }
            let e = io::Error::last_os_error();
            match e.kind() {
                io::ErrorKind::WouldBlock => break,
                io::ErrorKind::Interrupted => continue,
                _ => {
                    self.broken = true;
                    break;
                }
            }
        }
        self.parse(done);
        if self.broken {
            for (job, _) in self.inflight.drain(..) {
                done.push((job, PgResult::failed("postgres connection lost")));
            }
        }
    }

    fn parse(&mut self, done: &mut Vec<(J, PgResult)>) {
        let buf = &self.rbuf;
        let mut p = self.rpos;
        while buf.len() - p >= 5 {
            let len = i32::from_be_bytes(buf[p + 1..p + 5].try_into().unwrap()) as usize;
            if buf.len() - p < len + 1 {
                break;
            }
            let tag = buf[p];
            let body = &buf[p + 5..p + 1 + len];
            match tag {
                b'D' => {
                    if let Some((_, res)) = self.inflight.front_mut() {
                        let start = res.data.len() as u32;
                        res.data.extend_from_slice(body);
                        res.rows.push((res.stmt, start, res.data.len() as u32));
                    }
                }
                b'C' | b'I' => {
                    if let Some((_, res)) = self.inflight.front_mut() {
                        res.stmt += 1;
                    }
                }
                b'E' => {
                    if let Some((_, res)) = self.inflight.front_mut() {
                        res.err = Some(parse_error(body));
                    }
                }
                b'Z' => {
                    if let Some(item) = self.inflight.pop_front() {
                        done.push(item);
                    }
                }
                _ => {}
            }
            p += len + 1;
        }
        if p == self.rbuf.len() {
            self.rbuf.clear();
            self.rpos = 0;
        } else if p > 32 * 1024 {
            self.rbuf.drain(..p);
            self.rpos = 0;
        } else {
            self.rpos = p;
        }
    }
}
