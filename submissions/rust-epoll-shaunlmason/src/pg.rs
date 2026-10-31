//! Blocking PostgreSQL v3 wire-protocol client: SCRAM-SHA-256 login, named prepared statements, binary parameters and
//! results, and pipelines of Bind/Execute closed by one Sync.
//!
//! A pipeline's results are not copied out: rows are `(start, len)` spans into the receive buffer, which the pipeline
//! takes over until it is dropped, and every row's columns sit in one flat vector.

use std::io::{self, Read, Write};
use std::net::TcpStream;

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

pub const INT8: u32 = 20;
pub const TEXT: u32 = 25;
pub const INT8_ARRAY: u32 = 1016;
pub const TEXT_ARRAY: u32 = 1009;

#[derive(Debug)]
pub struct DbError {
    pub code: String,
    pub message: String,
}

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    Db(DbError),
    Protocol(String),
}

impl From<io::Error> for Error {
    fn from(e: io::Error) -> Self {
        Error::Io(e)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Io(e) => write!(f, "io: {e}"),
            Error::Db(e) => write!(f, "db {}: {}", e.code, e.message),
            Error::Protocol(s) => write!(f, "protocol: {s}"),
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub struct Config {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub dbname: String,
}

fn pct_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl Config {
    /// `postgres://user:password@host:port/dbname`
    pub fn parse(url: &str) -> Option<Config> {
        let rest = url.strip_prefix("postgres://").or_else(|| url.strip_prefix("postgresql://"))?;
        let (auth, hostpart) = rest.rsplit_once('@')?;
        let (user, password) = auth.split_once(':').unwrap_or((auth, ""));
        let (hostport, db) = hostpart.split_once('/').unwrap_or((hostpart, ""));
        let db = db.split('?').next().unwrap_or("");
        let (host, port) = match hostport.rsplit_once(':') {
            Some((h, p)) => (h, p.parse().ok()?),
            None => (hostport, 5432),
        };
        Some(Config {
            host: host.to_string(),
            port,
            user: pct_decode(user),
            password: pct_decode(password),
            dbname: pct_decode(if db.is_empty() { user } else { db }),
        })
    }
}

// ------------------------------------------------------------------------------------------------------------------
// outgoing

/// A binary parameter value.
pub enum Param<'a> {
    Null,
    I64(i64),
    Text(&'a [u8]),
    /// An already-encoded binary value (arrays).
    Raw(&'a [u8]),
}

impl<'a> Param<'a> {
    pub fn opt(v: Option<&'a [u8]>) -> Param<'a> {
        v.map_or(Param::Null, Param::Text)
    }
}

#[derive(Default)]
pub struct Out {
    pub buf: Vec<u8>,
}

impl Out {
    fn begin(&mut self, tag: u8) -> usize {
        self.buf.push(tag);
        let at = self.buf.len();
        self.buf.extend_from_slice(&[0; 4]);
        at
    }
    fn end(&mut self, at: usize) {
        let len = (self.buf.len() - at) as u32;
        self.buf[at..at + 4].copy_from_slice(&len.to_be_bytes());
    }
    fn cstr(&mut self, s: &[u8]) {
        self.buf.extend_from_slice(s);
        self.buf.push(0);
    }
    fn i16(&mut self, v: i16) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }
    fn i32(&mut self, v: i32) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn parse(&mut self, name: &str, sql: &str, types: &[u32]) {
        let at = self.begin(b'P');
        self.cstr(name.as_bytes());
        self.cstr(sql.as_bytes());
        self.i16(types.len() as i16);
        for &t in types {
            self.i32(t as i32);
        }
        self.end(at);
    }

    /// Bind the named statement to the unnamed portal (binary in and out), then Execute it.
    pub fn exec(&mut self, stmt: &str, params: &[Param]) {
        let at = self.begin(b'B');
        self.buf.push(0);
        self.cstr(stmt.as_bytes());
        self.i16(1);
        self.i16(1);
        self.i16(params.len() as i16);
        for p in params {
            match p {
                Param::Null => self.i32(-1),
                Param::I64(v) => {
                    self.i32(8);
                    self.buf.extend_from_slice(&v.to_be_bytes());
                }
                Param::Text(s) | Param::Raw(s) => {
                    self.i32(s.len() as i32);
                    self.buf.extend_from_slice(s);
                }
            }
        }
        self.i16(1);
        self.i16(1);
        self.end(at);
        let at = self.begin(b'E');
        self.buf.push(0);
        self.i32(0);
        self.end(at);
    }

    pub fn sync(&mut self) {
        let at = self.begin(b'S');
        self.end(at);
    }
}

/// A one-dimensional binary array parameter.
pub struct Array {
    buf: Vec<u8>,
    n: u32,
}

impl Array {
    pub fn new(elem: u32) -> Array {
        let mut buf = Vec::with_capacity(64);
        buf.extend_from_slice(&1i32.to_be_bytes());
        buf.extend_from_slice(&0i32.to_be_bytes());
        buf.extend_from_slice(&elem.to_be_bytes());
        buf.extend_from_slice(&0i32.to_be_bytes());
        buf.extend_from_slice(&1i32.to_be_bytes());
        Array { buf, n: 0 }
    }
    pub fn i64s(v: impl IntoIterator<Item = i64>) -> Vec<u8> {
        let mut a = Array::new(INT8);
        for x in v {
            a.i64(x);
        }
        a.done()
    }
    pub fn texts<'a>(v: impl IntoIterator<Item = &'a [u8]>) -> Vec<u8> {
        let mut a = Array::new(TEXT);
        for x in v {
            a.text(x);
        }
        a.done()
    }
    pub fn i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&8i32.to_be_bytes());
        self.buf.extend_from_slice(&v.to_be_bytes());
        self.n += 1;
    }
    pub fn text(&mut self, s: &[u8]) {
        self.buf.extend_from_slice(&(s.len() as i32).to_be_bytes());
        self.buf.extend_from_slice(s);
        self.n += 1;
    }
    pub fn done(mut self) -> Vec<u8> {
        let n = self.n;
        self.buf[12..16].copy_from_slice(&n.to_be_bytes());
        self.buf
    }
}

// ------------------------------------------------------------------------------------------------------------------
// results

/// A column value: a span of the pipeline's buffer, `len < 0` for NULL.
#[derive(Clone, Copy)]
pub struct Col {
    pub start: u32,
    pub len: i32,
}

/// One statement's rows: `ncols` columns per row, all rows' columns in `cols`.
pub struct Res {
    pub ncols: usize,
    pub cols: Vec<Col>,
    pub error: Option<DbError>,
}

impl Res {
    pub fn rows(&self) -> impl Iterator<Item = &[Col]> {
        self.cols.chunks(self.ncols.max(1))
    }
    pub fn len(&self) -> usize {
        if self.ncols == 0 { 0 } else { self.cols.len() / self.ncols }
    }
    pub fn row(&self, i: usize) -> &[Col] {
        &self.cols[i * self.ncols..(i + 1) * self.ncols]
    }
}

/// Everything one Sync returned. Column spans point into `data`.
pub struct Pipeline {
    pub data: Vec<u8>,
    pub res: Vec<Res>,
}

impl Pipeline {
    #[inline]
    pub fn get(&self, c: Col) -> Option<&[u8]> {
        if c.len < 0 { None } else { Some(&self.data[c.start as usize..c.start as usize + c.len as usize]) }
    }
    #[inline]
    pub fn bytes(&self, c: Col) -> &[u8] {
        self.get(c).unwrap_or(&[])
    }
    #[inline]
    pub fn i64(&self, c: Col) -> i64 {
        match self.get(c) {
            Some(b) if b.len() == 8 => i64::from_be_bytes(b.try_into().unwrap()),
            Some(b) if b.len() == 4 => i32::from_be_bytes(b.try_into().unwrap()) as i64,
            _ => 0,
        }
    }
    #[inline]
    pub fn null(&self, c: Col) -> bool {
        c.len < 0
    }
}

/// The elements of a binary one-dimensional array (NULL elements skipped).
pub fn array_elems(b: &[u8]) -> impl Iterator<Item = &[u8]> {
    let (mut pos, mut left) = (0usize, 0usize);
    if b.len() >= 12 {
        let ndim = i32::from_be_bytes(b[0..4].try_into().unwrap());
        if ndim > 0 && b.len() >= 20 {
            left = i32::from_be_bytes(b[12..16].try_into().unwrap()).max(0) as usize;
            pos = 12 + 8 * ndim as usize;
        }
    }
    std::iter::from_fn(move || {
        while left > 0 {
            left -= 1;
            let n = i32::from_be_bytes(b.get(pos..pos + 4)?.try_into().ok()?);
            pos += 4;
            if n < 0 {
                continue;
            }
            let v = b.get(pos..pos + n as usize)?;
            pos += n as usize;
            return Some(v);
        }
        None
    })
}

// ------------------------------------------------------------------------------------------------------------------
// connection

pub struct Conn {
    stream: TcpStream,
    buf: Vec<u8>,
    pos: usize,
    end: usize,
    pub out: Out,
}

type HmacSha256 = Hmac<Sha256>;

fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut m = HmacSha256::new_from_slice(key).expect("hmac key");
    m.update(data);
    m.finalize().into_bytes().into()
}

fn b64(data: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(data)
}

fn unb64(s: &str) -> Option<Vec<u8>> {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.decode(s).ok()
}

const RBUF: usize = 256 * 1024;

impl Conn {
    pub fn connect(cfg: &Config) -> Result<Conn> {
        let stream = TcpStream::connect((cfg.host.as_str(), cfg.port))?;
        stream.set_nodelay(true)?;
        let mut c = Conn { stream, buf: vec![0; RBUF], pos: 0, end: 0, out: Out::default() };
        let mut m = Vec::with_capacity(256);
        m.extend_from_slice(&[0; 4]);
        m.extend_from_slice(&196608i32.to_be_bytes());
        // Session settings only (startup parameters on our own connections):
        // - plan_cache_mode: the batch statements take arrays; under "auto" they are re-planned on every execution.
        // - jit: a generic plan can't see LIMIT values or array sizes, crosses jit_above_cost and compiles per run.
        // - parallel workers: per-statement worker startup costs more than these sub-millisecond index walks.
        // - memoize: a generic plan puts Memoize over the users join, which misses on nearly every probe.
        for (k, v) in [
            ("user", cfg.user.as_str()),
            ("database", cfg.dbname.as_str()),
            ("client_encoding", "UTF8"),
            ("DateStyle", "ISO"),
            ("TimeZone", "UTC"),
            ("plan_cache_mode", "force_generic_plan"),
            ("jit", "off"),
            ("max_parallel_workers_per_gather", "0"),
            ("enable_memoize", "off"),
        ] {
            m.extend_from_slice(k.as_bytes());
            m.push(0);
            m.extend_from_slice(v.as_bytes());
            m.push(0);
        }
        m.push(0);
        let len = m.len() as i32;
        m[0..4].copy_from_slice(&len.to_be_bytes());
        c.stream.write_all(&m)?;
        c.login(cfg)?;
        Ok(c)
    }

    fn send(&mut self, tag: u8, body: &[u8]) -> Result<()> {
        let mut m = Vec::with_capacity(body.len() + 5);
        m.push(tag);
        m.extend_from_slice(&((body.len() + 4) as i32).to_be_bytes());
        m.extend_from_slice(body);
        self.stream.write_all(&m)?;
        Ok(())
    }

    fn login(&mut self, cfg: &Config) -> Result<()> {
        let mut first_bare = String::new();
        let mut nonce = String::new();
        let mut want_sig: Option<[u8; 32]> = None;
        loop {
            let (tag, body) = self.msg()?;
            let body = body.to_vec();
            match tag {
                b'R' => match i32::from_be_bytes(body[0..4].try_into().unwrap()) {
                    0 => {}
                    3 => {
                        let mut b = cfg.password.as_bytes().to_vec();
                        b.push(0);
                        self.send(b'p', &b)?;
                    }
                    10 => {
                        let mechs = String::from_utf8_lossy(&body[4..]).into_owned();
                        if !mechs.split('\0').any(|m| m == "SCRAM-SHA-256") {
                            return Err(Error::Protocol(format!("no supported SASL mechanism in {mechs:?}")));
                        }
                        let mut nb = [0u8; 18];
                        getrandom::fill(&mut nb).map_err(|e| Error::Protocol(e.to_string()))?;
                        nonce = b64(&nb);
                        first_bare = format!("n=,r={nonce}");
                        let first = format!("n,,{first_bare}");
                        let mut b = b"SCRAM-SHA-256\0".to_vec();
                        b.extend_from_slice(&(first.len() as i32).to_be_bytes());
                        b.extend_from_slice(first.as_bytes());
                        self.send(b'p', &b)?;
                    }
                    11 => {
                        let server_first = String::from_utf8_lossy(&body[4..]).into_owned();
                        let (mut r, mut s, mut i) = (None, None, None);
                        for part in server_first.split(',') {
                            if let Some(v) = part.strip_prefix("r=") {
                                r = Some(v.to_string());
                            } else if let Some(v) = part.strip_prefix("s=") {
                                s = unb64(v);
                            } else if let Some(v) = part.strip_prefix("i=") {
                                i = v.parse::<u32>().ok();
                            }
                        }
                        let (r, s, i) = match (r, s, i) {
                            (Some(r), Some(s), Some(i)) if r.starts_with(&nonce) && i > 0 => (r, s, i),
                            _ => return Err(Error::Protocol("bad SCRAM server-first message".into())),
                        };
                        let pw = cfg.password.as_bytes();
                        let mut salt1 = s.clone();
                        salt1.extend_from_slice(&1u32.to_be_bytes());
                        let mut u = hmac(pw, &salt1);
                        let mut salted = u;
                        for _ in 1..i {
                            u = hmac(pw, &u);
                            for k in 0..32 {
                                salted[k] ^= u[k];
                            }
                        }
                        let client_key = hmac(&salted, b"Client Key");
                        let stored_key: [u8; 32] = Sha256::digest(client_key).into();
                        let without_proof = format!("c=biws,r={r}");
                        let auth = format!("{first_bare},{server_first},{without_proof}");
                        let client_sig = hmac(&stored_key, auth.as_bytes());
                        let mut proof = client_key;
                        for k in 0..32 {
                            proof[k] ^= client_sig[k];
                        }
                        want_sig = Some(hmac(&hmac(&salted, b"Server Key"), auth.as_bytes()));
                        self.send(b'p', format!("{without_proof},p={}", b64(&proof)).as_bytes())?;
                    }
                    12 => {
                        let fin = String::from_utf8_lossy(&body[4..]).into_owned();
                        let got = fin.strip_prefix("v=").and_then(unb64);
                        if got.as_deref() != want_sig.as_ref().map(|s| &s[..]) {
                            return Err(Error::Protocol("SCRAM server signature mismatch".into()));
                        }
                    }
                    k => return Err(Error::Protocol(format!("unsupported auth method {k}"))),
                },
                b'E' => return Err(Error::Db(db_error(&body))),
                b'Z' => return Ok(()),
                _ => {}
            }
        }
    }

    /// The next message (tag, body); the body borrows the buffer until the next read.
    fn msg(&mut self) -> Result<(u8, &[u8])> {
        self.need(5)?;
        let tag = self.buf[self.pos];
        let len = u32::from_be_bytes(self.buf[self.pos + 1..self.pos + 5].try_into().unwrap()) as usize;
        self.need(1 + len)?;
        let start = self.pos + 5;
        self.pos += 1 + len;
        Ok((tag, &self.buf[start..start + len - 4]))
    }

    /// At least `n` unread bytes buffered from `pos`. Within a pipeline `pos` never moves backwards, so earlier
    /// column spans stay valid: the buffer only grows.
    fn need(&mut self, n: usize) -> Result<()> {
        if self.end - self.pos >= n {
            return Ok(());
        }
        if self.buf.len() < self.pos + n {
            let want = (self.pos + n).next_power_of_two().max(self.buf.len() * 2);
            self.buf.resize(want, 0);
        }
        while self.end - self.pos < n {
            let k = self.stream.read(&mut self.buf[self.end..])?;
            if k == 0 {
                return Err(Error::Io(io::Error::new(io::ErrorKind::UnexpectedEof, "postgres closed the connection")));
            }
            self.end += k;
        }
        Ok(())
    }

    pub fn flush(&mut self) -> Result<()> {
        let r = self.stream.write_all(&self.out.buf);
        self.out.buf.clear();
        r.map_err(Error::Io)
    }

    /// Reads to ReadyForQuery: one `Res` per Execute sent (`n`); statements skipped after an error count as failed.
    pub fn results(&mut self, n: usize) -> Result<Pipeline> {
        // Restart the buffer at any leftover bytes so all spans of this pipeline are offsets into one buffer.
        if self.pos > 0 {
            self.buf.copy_within(self.pos..self.end, 0);
            self.end -= self.pos;
            self.pos = 0;
        }
        let mut res: Vec<Res> = Vec::with_capacity(n);
        let mut cols: Vec<Col> = Vec::new();
        let mut ncols = 0usize;
        loop {
            let (tag, len) = {
                let (tag, body) = self.msg()?;
                (tag, body.len())
            };
            let start = (self.pos - len) as u32;
            match tag {
                b'D' => {
                    let b = &self.buf[start as usize..start as usize + len];
                    let n = u16::from_be_bytes([b[0], b[1]]) as usize;
                    ncols = n;
                    let mut p = 2usize;
                    for _ in 0..n {
                        let l = i32::from_be_bytes(b[p..p + 4].try_into().unwrap());
                        p += 4;
                        cols.push(Col { start: start + p as u32, len: l });
                        if l > 0 {
                            p += l as usize;
                        }
                    }
                }
                b'C' | b'I' => {
                    res.push(Res { ncols, cols: std::mem::take(&mut cols), error: None });
                    ncols = 0;
                }
                b'E' => {
                    let e = db_error(&self.buf[start as usize..start as usize + len]);
                    res.push(Res { ncols, cols: std::mem::take(&mut cols), error: Some(e) });
                    ncols = 0;
                }
                b'Z' => break,
                b'1' | b'2' | b'3' | b'n' | b't' | b'T' | b'N' | b'S' | b'A' | b's' => {}
                other => return Err(Error::Protocol(format!("unexpected message {:?}", other as char))),
            }
        }
        while res.len() < n {
            res.push(Res {
                ncols: 0,
                cols: Vec::new(),
                error: Some(DbError { code: "skipped".into(), message: "skipped after an earlier error".into() }),
            });
        }
        // Hand the filled buffer to the pipeline and keep reading into a fresh one (leftovers moved across).
        let mut data = std::mem::replace(&mut self.buf, vec![0; RBUF.max(self.end - self.pos)]);
        let left = self.end - self.pos;
        self.buf[..left].copy_from_slice(&data[self.pos..self.end]);
        data.truncate(self.pos);
        self.pos = 0;
        self.end = left;
        Ok(Pipeline { data, res })
    }

    /// Sends the queued messages and reads `n` results.
    pub fn run(&mut self, n: usize) -> Result<Pipeline> {
        self.out.sync();
        self.flush()?;
        self.results(n)
    }

    /// Parses named statements, failing on the first error.
    pub fn prepare(&mut self, stmts: &[(&str, &str, &[u32])]) -> Result<()> {
        for (name, sql, types) in stmts {
            self.out.parse(name, sql, types);
        }
        self.out.sync();
        self.flush()?;
        let mut err = None;
        loop {
            let (tag, body) = self.msg()?;
            match tag {
                b'E' if err.is_none() => err = Some(db_error(body)),
                b'Z' => break,
                _ => {}
            }
        }
        match err {
            Some(e) => Err(Error::Db(e)),
            None => Ok(()),
        }
    }
}

fn db_error(body: &[u8]) -> DbError {
    let mut e = DbError { code: String::new(), message: String::new() };
    for field in body.split(|&b| b == 0) {
        if let Some((&k, v)) = field.split_first() {
            match k {
                b'C' => e.code = String::from_utf8_lossy(v).into_owned(),
                b'M' => e.message = String::from_utf8_lossy(v).into_owned(),
                _ => {}
            }
        }
    }
    e
}
