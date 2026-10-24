//! A small blocking PostgreSQL v3 wire-protocol client: SCRAM-SHA-256 / cleartext / md5-less auth, named prepared
//! statements, binary parameters and results, and pipelines of Bind/Execute ending in one Sync.

use std::io::{self, Read, Write};
use std::net::TcpStream;

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

pub const INT8: u32 = 20;
pub const TEXT: u32 = 25;
pub const INT8_ARRAY: u32 = 1016;
pub const TEXT_ARRAY: u32 = 1009;

#[derive(Debug)]
pub struct DbError {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for DbError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
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
            Error::Db(e) => write!(f, "db: {e}"),
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
    /// postgres://user:password@host:port/dbname
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

/// Outgoing message buffer.
#[derive(Default)]
pub struct Out {
    pub buf: Vec<u8>,
}

impl Out {
    fn begin(&mut self, tag: u8) -> usize {
        self.buf.push(tag);
        let at = self.buf.len();
        self.buf.extend_from_slice(&[0, 0, 0, 0]);
        at
    }
    fn end(&mut self, at: usize) {
        let len = (self.buf.len() - at) as u32;
        self.buf[at..at + 4].copy_from_slice(&len.to_be_bytes());
    }
    fn cstr(&mut self, s: &str) {
        self.buf.extend_from_slice(s.as_bytes());
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
        self.cstr(name);
        self.cstr(sql);
        self.i16(types.len() as i16);
        for t in types {
            self.i32(*t as i32);
        }
        self.end(at);
    }
    /// Bind to the unnamed portal with all-binary parameters and all-binary results, then Execute it.
    pub fn bind_exec(&mut self, stmt: &str, params: &[Param]) {
        let at = self.begin(b'B');
        self.buf.push(0); // unnamed portal
        self.cstr(stmt);
        self.i16(1);
        self.i16(1); // all parameters binary
        self.i16(params.len() as i16);
        for p in params {
            p.write(&mut self.buf);
        }
        self.i16(1);
        self.i16(1); // all results binary
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
    pub fn clear(&mut self) {
        self.buf.clear();
    }
}

/// A binary parameter value.
pub enum Param<'a> {
    Null,
    I64(i64),
    Text(&'a [u8]),
    /// A pre-encoded binary value (arrays).
    Raw(&'a [u8]),
}

impl Param<'_> {
    fn write(&self, buf: &mut Vec<u8>) {
        match self {
            Param::Null => buf.extend_from_slice(&(-1i32).to_be_bytes()),
            Param::I64(v) => {
                buf.extend_from_slice(&8i32.to_be_bytes());
                buf.extend_from_slice(&v.to_be_bytes());
            }
            Param::Text(s) | Param::Raw(s) => {
                buf.extend_from_slice(&(s.len() as i32).to_be_bytes());
                buf.extend_from_slice(s);
            }
        }
    }
}

/// Builds a one-dimensional binary array value.
pub struct ArrayBuf {
    pub buf: Vec<u8>,
    count: u32,
}

impl ArrayBuf {
    pub fn new(elem_oid: u32) -> ArrayBuf {
        let mut buf = Vec::with_capacity(64);
        buf.extend_from_slice(&1i32.to_be_bytes()); // ndim
        buf.extend_from_slice(&0i32.to_be_bytes()); // has nulls (ignored on input)
        buf.extend_from_slice(&elem_oid.to_be_bytes());
        buf.extend_from_slice(&0i32.to_be_bytes()); // dim length, patched
        buf.extend_from_slice(&1i32.to_be_bytes()); // lower bound
        ArrayBuf { buf, count: 0 }
    }
    pub fn i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&8i32.to_be_bytes());
        self.buf.extend_from_slice(&v.to_be_bytes());
        self.count += 1;
    }
    pub fn text(&mut self, s: &[u8]) {
        self.buf.extend_from_slice(&(s.len() as i32).to_be_bytes());
        self.buf.extend_from_slice(s);
        self.count += 1;
    }
    pub fn finish(&mut self) -> &[u8] {
        let c = self.count;
        self.buf[12..16].copy_from_slice(&c.to_be_bytes());
        &self.buf
    }
}

/// One DataRow: column values as (start, len) into the connection's receive buffer; len -1 = NULL.
#[derive(Clone, Copy)]
pub struct Col {
    pub start: u32,
    pub len: i32,
}

/// Results of one statement in a pipeline.
pub struct StmtResult {
    pub rows: Vec<Vec<Col>>,
    pub error: Option<DbError>,
}

/// The decoded output of a whole pipeline (everything up to ReadyForQuery). Column values point into `data`.
pub struct Pipeline {
    pub data: Vec<u8>,
    pub results: Vec<StmtResult>,
}

impl Pipeline {
    #[inline]
    pub fn bytes(&self, c: Col) -> Option<&[u8]> {
        if c.len < 0 { None } else { Some(&self.data[c.start as usize..c.start as usize + c.len as usize]) }
    }
    #[inline]
    pub fn i64(&self, c: Col) -> i64 {
        match self.bytes(c) {
            Some(b) if b.len() == 8 => i64::from_be_bytes(b.try_into().unwrap()),
            Some(b) if b.len() == 4 => i32::from_be_bytes(b.try_into().unwrap()) as i64,
            _ => 0,
        }
    }
}

/// Iterates the elements of a binary one-dimensional array (NULL elements are skipped).
pub fn array_elems(b: &[u8]) -> impl Iterator<Item = &[u8]> {
    let mut pos;
    let mut left;
    if b.len() < 12 {
        pos = 0;
        left = 0;
    } else {
        let ndim = i32::from_be_bytes(b[0..4].try_into().unwrap());
        if ndim == 0 {
            pos = 0;
            left = 0;
        } else {
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

pub struct Conn {
    stream: TcpStream,
    rbuf: Vec<u8>,
    rpos: usize,
    rend: usize,
    pub out: Out,
}

fn h(data: &[u8]) -> [u8; 32] {
    Sha256::digest(data).into()
}

fn hmac(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut m = HmacSha256::new_from_slice(key).unwrap();
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

impl Conn {
    pub fn connect(cfg: &Config) -> Result<Conn> {
        let stream = TcpStream::connect((cfg.host.as_str(), cfg.port))?;
        stream.set_nodelay(true)?;
        let mut c = Conn { stream, rbuf: vec![0; 64 * 1024], rpos: 0, rend: 0, out: Out::default() };
        // StartupMessage
        let mut m = Vec::new();
        m.extend_from_slice(&0i32.to_be_bytes());
        m.extend_from_slice(&196608i32.to_be_bytes());
        // Session settings only. plan_cache_mode: every statement here takes arrays of a batch's keys, and the default
        // ("auto") keeps re-planning them per execution because a custom plan looks cheaper for each array. jit: a
        // generic plan can't see LIMIT values or array sizes, its cost estimate crosses jit_above_cost, and compiling
        // costs milliseconds per execution of a sub-millisecond statement.
        for (k, v) in [
            ("user", cfg.user.as_str()),
            ("database", cfg.dbname.as_str()),
            ("client_encoding", "UTF8"),
            ("DateStyle", "ISO"),
            ("plan_cache_mode", "force_generic_plan"),
            ("jit", "off"),
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
        c.auth(cfg)?;
        Ok(c)
    }

    fn send_raw(&mut self, tag: u8, body: &[u8]) -> Result<()> {
        let mut m = Vec::with_capacity(body.len() + 5);
        m.push(tag);
        m.extend_from_slice(&((body.len() + 4) as i32).to_be_bytes());
        m.extend_from_slice(body);
        self.stream.write_all(&m)?;
        Ok(())
    }

    fn auth(&mut self, cfg: &Config) -> Result<()> {
        let mut scram: Option<(String, String)> = None; // (client_first_bare, nonce)
        let mut server_sig: Option<[u8; 32]> = None;
        loop {
            let (tag, body) = self.read_msg()?;
            let body = body.to_vec();
            match tag {
                b'R' => {
                    let kind = i32::from_be_bytes(body[0..4].try_into().unwrap());
                    match kind {
                        0 => {}
                        3 => {
                            let mut b = cfg.password.as_bytes().to_vec();
                            b.push(0);
                            self.send_raw(b'p', &b)?;
                        }
                        10 => {
                            let mechs = String::from_utf8_lossy(&body[4..]).to_string();
                            if !mechs.split('\0').any(|m| m == "SCRAM-SHA-256") {
                                return Err(Error::Protocol(format!("no supported SASL mechanism: {mechs}")));
                            }
                            let mut nb = [0u8; 18];
                            getrandom::fill(&mut nb).map_err(|e| Error::Protocol(e.to_string()))?;
                            let nonce = b64(&nb);
                            let first_bare = format!("n=,r={nonce}");
                            let first = format!("n,,{first_bare}");
                            let mut b = Vec::new();
                            b.extend_from_slice(b"SCRAM-SHA-256\0");
                            b.extend_from_slice(&(first.len() as i32).to_be_bytes());
                            b.extend_from_slice(first.as_bytes());
                            self.send_raw(b'p', &b)?;
                            scram = Some((first_bare, nonce));
                        }
                        11 => {
                            let (first_bare, nonce) = scram.clone().ok_or_else(|| Error::Protocol("sasl".into()))?;
                            let server_first = String::from_utf8_lossy(&body[4..]).to_string();
                            let mut r = None;
                            let mut s = None;
                            let mut i = None;
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
                                (Some(r), Some(s), Some(i)) if r.starts_with(&nonce) => (r, s, i),
                                _ => return Err(Error::Protocol("bad server-first".into())),
                            };
                            // SaltedPassword = Hi(password, salt, i)
                            let mut u = {
                                let mut salt1 = s.clone();
                                salt1.extend_from_slice(&1u32.to_be_bytes());
                                hmac(cfg.password.as_bytes(), &salt1)
                            };
                            let mut salted = u;
                            for _ in 1..i {
                                u = hmac(cfg.password.as_bytes(), &u);
                                for k in 0..32 {
                                    salted[k] ^= u[k];
                                }
                            }
                            let client_key = hmac(&salted, b"Client Key");
                            let stored_key = h(&client_key);
                            let without_proof = format!("c=biws,r={r}");
                            let auth_msg = format!("{first_bare},{server_first},{without_proof}");
                            let client_sig = hmac(&stored_key, auth_msg.as_bytes());
                            let mut proof = client_key;
                            for k in 0..32 {
                                proof[k] ^= client_sig[k];
                            }
                            let server_key = hmac(&salted, b"Server Key");
                            server_sig = Some(hmac(&server_key, auth_msg.as_bytes()));
                            let fin = format!("{without_proof},p={}", b64(&proof));
                            self.send_raw(b'p', fin.as_bytes())?;
                        }
                        12 => {
                            let fin = String::from_utf8_lossy(&body[4..]).to_string();
                            let v = fin.strip_prefix("v=").and_then(unb64);
                            if v.as_deref() != server_sig.as_ref().map(|s| &s[..]) {
                                return Err(Error::Protocol("server signature mismatch".into()));
                            }
                        }
                        k => return Err(Error::Protocol(format!("unsupported auth method {k}"))),
                    }
                }
                b'E' => return Err(Error::Db(parse_error(&body))),
                b'Z' => return Ok(()),
                _ => {}
            }
        }
    }

    /// Reads one message; returns (tag, body). The body borrows the receive buffer until the next read.
    fn read_msg(&mut self) -> Result<(u8, &[u8])> {
        self.fill(5)?;
        let tag = self.rbuf[self.rpos];
        let len = i32::from_be_bytes(self.rbuf[self.rpos + 1..self.rpos + 5].try_into().unwrap()) as usize;
        self.fill(1 + len)?;
        let start = self.rpos + 5;
        self.rpos += 1 + len;
        Ok((tag, &self.rbuf[start..start + len - 4]))
    }

    /// Ensures at least n unread bytes are buffered.
    fn fill(&mut self, n: usize) -> Result<()> {
        if self.rend - self.rpos >= n {
            return Ok(());
        }
        if self.rpos > 0 {
            self.rbuf.copy_within(self.rpos..self.rend, 0);
            self.rend -= self.rpos;
            self.rpos = 0;
        }
        if self.rbuf.len() < n {
            self.rbuf.resize(n.next_power_of_two(), 0);
        }
        while self.rend < n {
            let k = self.stream.read(&mut self.rbuf[self.rend..])?;
            if k == 0 {
                return Err(Error::Io(io::Error::new(io::ErrorKind::UnexpectedEof, "postgres closed the connection")));
            }
            self.rend += k;
        }
        Ok(())
    }

    /// Sends the queued messages in `out`.
    pub fn flush(&mut self) -> Result<()> {
        self.stream.write_all(&self.out.buf)?;
        self.out.clear();
        Ok(())
    }

    /// Reads results until ReadyForQuery. One StmtResult per Execute (and per Describe/Parse pair is ignored).
    /// `n_exec` = how many Execute messages were sent, so skipped statements after an error still get a slot.
    pub fn read_pipeline(&mut self, n_exec: usize) -> Result<Pipeline> {
        let mut data = Vec::with_capacity(4096);
        let mut results: Vec<StmtResult> = Vec::with_capacity(n_exec);
        let mut cur: Vec<Vec<Col>> = Vec::new();
        loop {
            let (tag, body) = self.read_msg()?;
            match tag {
                b'D' => {
                    let n = u16::from_be_bytes(body[0..2].try_into().unwrap()) as usize;
                    let mut cols = Vec::with_capacity(n);
                    let mut p = 2;
                    for _ in 0..n {
                        let len = i32::from_be_bytes(body[p..p + 4].try_into().unwrap());
                        p += 4;
                        if len < 0 {
                            cols.push(Col { start: 0, len: -1 });
                        } else {
                            let start = data.len() as u32;
                            data.extend_from_slice(&body[p..p + len as usize]);
                            p += len as usize;
                            cols.push(Col { start, len });
                        }
                    }
                    cur.push(cols);
                }
                b'C' => results.push(StmtResult { rows: std::mem::take(&mut cur), error: None }),
                b'E' => results.push(StmtResult { rows: std::mem::take(&mut cur), error: Some(parse_error(body)) }),
                b'I' => results.push(StmtResult { rows: Vec::new(), error: None }),
                b'Z' => break,
                b'1' | b'2' | b'3' | b'n' | b't' | b'T' | b'N' | b'S' | b'A' | b's' => {}
                other => return Err(Error::Protocol(format!("unexpected message {:?}", other as char))),
            }
        }
        // Statements skipped after an error report nothing; mark them as failed too.
        while results.len() < n_exec {
            results.push(StmtResult {
                rows: Vec::new(),
                error: Some(DbError { code: "skipped".into(), message: "skipped after an earlier error".into() }),
            });
        }
        Ok(Pipeline { data, results })
    }

    /// Prepares named statements (Parse + Sync), failing on the first error.
    pub fn prepare_all(&mut self, stmts: &[(&str, &str, &[u32])]) -> Result<()> {
        for (name, sql, types) in stmts {
            self.out.parse(name, sql, types);
        }
        self.out.sync();
        self.flush()?;
        loop {
            let (tag, body) = self.read_msg()?;
            match tag {
                b'E' => {
                    let e = parse_error(body);
                    // drain to ReadyForQuery
                    loop {
                        let (t, _) = self.read_msg()?;
                        if t == b'Z' {
                            break;
                        }
                    }
                    return Err(Error::Db(e));
                }
                b'Z' => return Ok(()),
                _ => {}
            }
        }
    }
}

fn parse_error(body: &[u8]) -> DbError {
    let mut code = String::new();
    let mut message = String::new();
    for field in body.split(|&b| b == 0) {
        if field.is_empty() {
            continue;
        }
        let v = String::from_utf8_lossy(&field[1..]).into_owned();
        match field[0] {
            b'C' => code = v,
            b'M' => message = v,
            _ => {}
        }
    }
    DbError { code, message }
}
