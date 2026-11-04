//! Postgres wire protocol (v3) pieces:
//!  * blocking startup: TCP connect, SCRAM-SHA-256 / cleartext auth, session SETs, prepare all statements
//!  * non-blocking pipelining: Bind/Execute/Sync encoding into a buffer, response scanning
//!
//! After startup the socket is handed to the io_uring worker; this module never does socket I/O again.

use std::collections::VecDeque;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::num::NonZeroU32;
use std::os::unix::io::IntoRawFd;
use std::sync::atomic::{AtomicI32, Ordering};

use base64::{engine::general_purpose::STANDARD, Engine as _};
use ring::rand::{SecureRandom, SystemRandom};
use ring::{digest, hmac, pbkdf2};

use crate::sql;

// ---------------------------------------------------------------------------- configuration

pub struct PgConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub dbname: String,
    pub plan_cache_mode: String,
}

fn pct(s: &str) -> String {
    let d = crate::http::pct_decode(s.as_bytes(), false);
    String::from_utf8_lossy(&d).into_owned()
}

/// postgres://user:pass@host:port/db?options  (TCP only: the box's pg_hba uses peer auth on the unix socket)
pub fn parse_url(url: &str, plan_cache_mode: &str) -> PgConfig {
    let mut rest = url;
    if let Some(i) = rest.find("://") {
        rest = &rest[i + 3..];
    }
    let (userinfo, hostpart) = match rest.rfind('@') {
        Some(i) => (&rest[..i], &rest[i + 1..]),
        None => ("", rest),
    };
    let (user, password) = match userinfo.find(':') {
        Some(i) => (&userinfo[..i], &userinfo[i + 1..]),
        None => (userinfo, ""),
    };
    let (hostport, dbq) = match hostpart.find('/') {
        Some(i) => (&hostpart[..i], &hostpart[i + 1..]),
        None => (hostpart, ""),
    };
    let dbname = dbq.split('?').next().unwrap_or("");
    let (host, port) = match hostport.rfind(':') {
        Some(i) => (&hostport[..i], hostport[i + 1..].parse::<u16>().unwrap_or(5432)),
        None => (hostport, 5432u16),
    };
    PgConfig {
        host: if host.is_empty() { "127.0.0.1".to_string() } else { host.to_string() },
        port,
        user: if user.is_empty() { "conduit".to_string() } else { pct(user) },
        password: pct(password),
        dbname: if dbname.is_empty() { "conduit".to_string() } else { pct(dbname) },
        plan_cache_mode: plan_cache_mode.to_string(),
    }
}

// ---------------------------------------------------------------------------- socket registry

const MAX_TRACKED: usize = 1024;
const FD_INIT: AtomicI32 = AtomicI32::new(-1);
/// Every Postgres socket we own. A process killed while io_uring still has requests pending on a
/// socket does not release it until the ring has been torn down, so Postgres keeps counting the
/// connection for a while. The SIGTERM/SIGINT handler uses this table to `shutdown(2)` them at once.
static PG_FDS: [AtomicI32; MAX_TRACKED] = [FD_INIT; MAX_TRACKED];

fn track_fd(fd: i32) {
    for slot in PG_FDS.iter() {
        if slot
            .compare_exchange(-1, fd, Ordering::AcqRel, Ordering::Relaxed)
            .is_ok()
        {
            return;
        }
    }
}

/// Async-signal-safe: only atomic loads and shutdown(2).
pub fn shutdown_all() {
    for slot in PG_FDS.iter() {
        let fd = slot.load(Ordering::Relaxed);
        if fd >= 0 {
            unsafe {
                libc::shutdown(fd, libc::SHUT_RDWR);
            }
        }
    }
}

// ---------------------------------------------------------------------------- connection state

/// One pipelined Postgres connection owned by one io worker.
pub struct PgConn {
    pub fd: i32,
    /// Bytes currently being sent (must not be touched while `sending`).
    pub tx_active: Vec<u8>,
    /// Requests encoded since the last flush.
    pub tx_pending: Vec<u8>,
    pub tx_sent: usize,
    pub sending: bool,
    pub rx: Vec<u8>,
    /// Start of the first byte not yet frame-parsed.
    pub rx_pos: usize,
    /// Start of the first message of the request currently being received.
    pub req_start: usize,
    pub recv_active: bool,
    /// (client conn index, generation) of every request in the pipeline, oldest first.
    pub inflight: VecDeque<(u32, u32)>,
    pub list_prepared: Vec<bool>,
}

impl PgConn {
    pub fn new(fd: i32) -> PgConn {
        PgConn {
            fd,
            tx_active: Vec::with_capacity(64 * 1024),
            tx_pending: Vec::with_capacity(64 * 1024),
            tx_sent: 0,
            sending: false,
            rx: Vec::with_capacity(256 * 1024),
            rx_pos: 0,
            req_start: 0,
            recv_active: false,
            inflight: VecDeque::with_capacity(256),
            list_prepared: vec![false; sql::LIST_KINDS * sql::LIMIT_SLOTS],
        }
    }
}

// ---------------------------------------------------------------------------- message encoding

#[inline]
pub fn msg_begin(tx: &mut Vec<u8>, tag: u8) -> usize {
    let s = tx.len();
    tx.push(tag);
    tx.extend_from_slice(&[0, 0, 0, 0]);
    s
}

#[inline]
pub fn msg_end(tx: &mut Vec<u8>, s: usize) {
    let len = (tx.len() - s - 1) as u32;
    tx[s + 1..s + 5].copy_from_slice(&len.to_be_bytes());
}

/// Parse: `name` must already be NUL-terminated.
pub fn parse_msg(tx: &mut Vec<u8>, name: &[u8], sql_text: &str, oids: &[u32]) {
    let s = msg_begin(tx, b'P');
    tx.extend_from_slice(name);
    tx.extend_from_slice(sql_text.as_bytes());
    tx.push(0);
    tx.extend_from_slice(&(oids.len() as u16).to_be_bytes());
    for o in oids {
        tx.extend_from_slice(&o.to_be_bytes());
    }
    msg_end(tx, s);
}

/// Starts a Bind for the unnamed portal: all parameters binary, all results binary.
/// `name` must already be NUL-terminated. Follow with `nparams` p_* calls and then `bind_end`.
#[inline]
pub fn bind_begin(tx: &mut Vec<u8>, name: &[u8], nparams: u16) -> usize {
    let s = msg_begin(tx, b'B');
    tx.push(0); // portal ""
    tx.extend_from_slice(name);
    tx.extend_from_slice(&1u16.to_be_bytes()); // one parameter format code ...
    tx.extend_from_slice(&1u16.to_be_bytes()); // ... binary, applied to every parameter
    tx.extend_from_slice(&nparams.to_be_bytes());
    s
}

/// Finishes the Bind and appends Execute (unnamed portal, no row limit).
#[inline]
pub fn bind_end(tx: &mut Vec<u8>, s: usize) {
    tx.extend_from_slice(&1u16.to_be_bytes()); // one result format code ...
    tx.extend_from_slice(&1u16.to_be_bytes()); // ... binary
    msg_end(tx, s);
    tx.extend_from_slice(&[b'E', 0, 0, 0, 9, 0, 0, 0, 0, 0]);
}

#[inline]
pub fn sync(tx: &mut Vec<u8>) {
    tx.extend_from_slice(&[b'S', 0, 0, 0, 4]);
}

#[inline]
pub fn p_i64(tx: &mut Vec<u8>, v: i64) {
    tx.extend_from_slice(&8i32.to_be_bytes());
    tx.extend_from_slice(&v.to_be_bytes());
}

#[inline]
pub fn p_text(tx: &mut Vec<u8>, v: &[u8]) {
    tx.extend_from_slice(&(v.len() as i32).to_be_bytes());
    tx.extend_from_slice(v);
}

#[inline]
pub fn p_null(tx: &mut Vec<u8>) {
    tx.extend_from_slice(&(-1i32).to_be_bytes());
}

#[inline]
pub fn p_opt_text(tx: &mut Vec<u8>, v: Option<&str>) {
    match v {
        Some(s) => p_text(tx, s.as_bytes()),
        None => p_null(tx),
    }
}

/// Binary text[] (one dimension, no NULL elements).
pub fn p_text_array(tx: &mut Vec<u8>, items: &[String]) {
    let mut total: usize = 20;
    for it in items {
        total += 4 + it.len();
    }
    tx.extend_from_slice(&(total as i32).to_be_bytes());
    tx.extend_from_slice(&1i32.to_be_bytes()); // ndim
    tx.extend_from_slice(&0i32.to_be_bytes()); // has nulls
    tx.extend_from_slice(&25i32.to_be_bytes()); // element type: text
    tx.extend_from_slice(&(items.len() as i32).to_be_bytes()); // dimension size
    tx.extend_from_slice(&1i32.to_be_bytes()); // lower bound
    for it in items {
        tx.extend_from_slice(&(it.len() as i32).to_be_bytes());
        tx.extend_from_slice(it.as_bytes());
    }
}

// ---------------------------------------------------------------------------- response scanning

/// Frames of one pipelined request (everything up to and including its ReadyForQuery).
/// `rows` holds (offset, len) of every DataRow payload inside the scanned slice;
/// `bounds[k]` is the number of rows seen when statement k completed.
#[derive(Default)]
pub struct Scan {
    pub rows: Vec<(u32, u32)>,
    pub bounds: Vec<u32>,
    pub has_err: bool,
    pub err_code: [u8; 5],
    pub err_text: String,
}

impl Scan {

    pub fn run(&mut self, buf: &[u8]) {
        self.rows.clear();
        self.bounds.clear();
        self.has_err = false;
        self.err_text.clear();
        let mut pos = 0usize;
        while pos + 5 <= buf.len() {
            let tag = buf[pos];
            let len = u32::from_be_bytes([buf[pos + 1], buf[pos + 2], buf[pos + 3], buf[pos + 4]]) as usize;
            let end = pos + 1 + len;
            if end > buf.len() {
                break;
            }
            match tag {
                b'D' => self.rows.push(((pos + 5) as u32, (end - pos - 5) as u32)),
                b'C' => self.bounds.push(self.rows.len() as u32),
                b'E' => {
                    self.has_err = true;
                    self.err_code = *b"XXXXX";
                    let mut i = pos + 5;
                    while i < end && buf[i] != 0 {
                        let t = buf[i];
                        i += 1;
                        let s0 = i;
                        while i < end && buf[i] != 0 {
                            i += 1;
                        }
                        if t == b'C' && i - s0 == 5 {
                            self.err_code.copy_from_slice(&buf[s0..i]);
                        }
                        i += 1;
                    }
                    self.err_text = error_text(&buf[pos + 5..end]);
                }
                _ => {}
            }
            pos = end;
        }
    }

    /// DataRows produced by statement `k` of the batch (empty if it never ran).
    pub fn stmt_rows(&self, k: usize) -> &[(u32, u32)] {
        if k >= self.bounds.len() {
            return &[];
        }
        let start = if k == 0 { 0 } else { self.bounds[k - 1] as usize };
        let end = self.bounds[k] as usize;
        &self.rows[start..end]
    }
}

/// Column reader for one binary DataRow payload.
pub struct RowReader<'a> {
    d: &'a [u8],
    p: usize,
}

impl<'a> RowReader<'a> {
    pub fn new(rx: &'a [u8], r: (u32, u32)) -> RowReader<'a> {
        let s = r.0 as usize;
        let e = s + r.1 as usize;
        RowReader { d: &rx[s..e], p: 2 } // skip the i16 column count
    }

    /// Next column; None means SQL NULL.
    pub fn field(&mut self) -> Option<&'a [u8]> {
        if self.p + 4 > self.d.len() {
            return None;
        }
        let len = i32::from_be_bytes([self.d[self.p], self.d[self.p + 1], self.d[self.p + 2], self.d[self.p + 3]]);
        self.p += 4;
        if len < 0 {
            return None;
        }
        let l = len as usize;
        if self.p + l > self.d.len() {
            return None;
        }
        let s = &self.d[self.p..self.p + l];
        self.p += l;
        Some(s)
    }

    /// Next column, NULL treated as empty.
    pub fn bytes(&mut self) -> &'a [u8] {
        match self.field() {
            Some(s) => s,
            None => &[],
        }
    }

    pub fn int8(&mut self) -> i64 {
        match self.field() {
            Some(s) if s.len() == 8 => i64::from_be_bytes([s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]]),
            _ => 0,
        }
    }

    pub fn boolean(&mut self) -> bool {
        match self.field() {
            Some(s) if !s.is_empty() => s[0] != 0,
            _ => false,
        }
    }
}

/// Human readable text of an ErrorResponse payload.
pub fn error_text(payload: &[u8]) -> String {
    let mut code = String::new();
    let mut msg = String::new();
    let mut pos = String::new();
    let mut i = 0usize;
    while i < payload.len() && payload[i] != 0 {
        let t = payload[i];
        i += 1;
        let start = i;
        while i < payload.len() && payload[i] != 0 {
            i += 1;
        }
        let val = String::from_utf8_lossy(&payload[start..i]).into_owned();
        i += 1;
        match t {
            b'C' => code = val,
            b'M' => msg = val,
            b'P' => pos = val,
            _ => {}
        }
    }
    if pos.is_empty() {
        format!("{}: {}", code, msg)
    } else {
        format!("{}: {} (position {})", code, msg, pos)
    }
}

// ---------------------------------------------------------------------------- blocking startup

fn proto(msg: &str) -> io::Error {
    io::Error::new(io::ErrorKind::Other, msg.to_string())
}

fn read_msg(s: &mut TcpStream) -> io::Result<(u8, Vec<u8>)> {
    let mut hdr = [0u8; 5];
    s.read_exact(&mut hdr)?;
    let len = u32::from_be_bytes([hdr[1], hdr[2], hdr[3], hdr[4]]) as usize;
    if len < 4 {
        return Err(proto("malformed message length"));
    }
    let mut payload = vec![0u8; len - 4];
    s.read_exact(&mut payload)?;
    Ok((hdr[0], payload))
}

fn contains(hay: &[u8], needle: &[u8]) -> bool {
    hay.windows(needle.len()).any(|w| w == needle)
}

struct Scram {
    client_first_bare: String,
    nonce: String,
    server_sig: Vec<u8>,
}

impl Scram {
    fn start() -> io::Result<(Scram, Vec<u8>)> {
        let rng = SystemRandom::new();
        let mut raw = [0u8; 18];
        rng.fill(&mut raw).map_err(|_| proto("random generator failed"))?;
        let mut nonce = String::with_capacity(36);
        for b in raw.iter() {
            nonce.push_str(&format!("{:02x}", b));
        }
        let bare = format!("n=,r={}", nonce);
        let first = format!("n,,{}", bare).into_bytes();
        Ok((
            Scram {
                client_first_bare: bare,
                nonce,
                server_sig: Vec::new(),
            },
            first,
        ))
    }

    fn client_final(&mut self, server_first: &str, password: &str) -> io::Result<Vec<u8>> {
        let mut r: Option<&str> = None;
        let mut salt_b64: Option<&str> = None;
        let mut iter: Option<&str> = None;
        for part in server_first.split(',') {
            if let Some(v) = part.strip_prefix("r=") {
                r = Some(v);
            } else if let Some(v) = part.strip_prefix("s=") {
                salt_b64 = Some(v);
            } else if let Some(v) = part.strip_prefix("i=") {
                iter = Some(v);
            }
        }
        let r = r.ok_or_else(|| proto("SCRAM: missing nonce"))?;
        let salt_b64 = salt_b64.ok_or_else(|| proto("SCRAM: missing salt"))?;
        let iter = iter.ok_or_else(|| proto("SCRAM: missing iteration count"))?;
        if !r.starts_with(self.nonce.as_str()) {
            return Err(proto("SCRAM: server nonce does not extend client nonce"));
        }
        let salt = STANDARD
            .decode(salt_b64)
            .map_err(|_| proto("SCRAM: bad salt encoding"))?;
        let iterations: u32 = iter.parse().map_err(|_| proto("SCRAM: bad iteration count"))?;
        let iterations = NonZeroU32::new(iterations).ok_or_else(|| proto("SCRAM: zero iterations"))?;

        let mut salted = [0u8; 32];
        pbkdf2::derive(
            pbkdf2::PBKDF2_HMAC_SHA256,
            iterations,
            &salt,
            password.as_bytes(),
            &mut salted,
        );
        let salted_key = hmac::Key::new(hmac::HMAC_SHA256, &salted);
        let client_key_tag = hmac::sign(&salted_key, b"Client Key");
        let client_key: &[u8] = client_key_tag.as_ref();
        let stored_key_d = digest::digest(&digest::SHA256, client_key);
        let stored_key: &[u8] = stored_key_d.as_ref();

        let client_final_no_proof = format!("c=biws,r={}", r);
        let auth_message = format!(
            "{},{},{}",
            self.client_first_bare, server_first, client_final_no_proof
        );
        let stored = hmac::Key::new(hmac::HMAC_SHA256, stored_key);
        let client_sig_tag = hmac::sign(&stored, auth_message.as_bytes());
        let client_sig: &[u8] = client_sig_tag.as_ref();
        let mut proof = [0u8; 32];
        for i in 0..32 {
            proof[i] = client_key[i] ^ client_sig[i];
        }

        let server_key_tag = hmac::sign(&salted_key, b"Server Key");
        let server_key: &[u8] = server_key_tag.as_ref();
        let skey = hmac::Key::new(hmac::HMAC_SHA256, server_key);
        let server_sig_tag = hmac::sign(&skey, auth_message.as_bytes());
        let server_sig: &[u8] = server_sig_tag.as_ref();
        self.server_sig = server_sig.to_vec();

        Ok(format!("{},p={}", client_final_no_proof, STANDARD.encode(proof)).into_bytes())
    }

    fn verify(&self, server_final: &str) -> io::Result<()> {
        let v = server_final
            .trim()
            .strip_prefix("v=")
            .ok_or_else(|| proto("SCRAM: bad server-final message"))?;
        let got = STANDARD
            .decode(v)
            .map_err(|_| proto("SCRAM: bad server signature encoding"))?;
        if got != self.server_sig {
            return Err(proto("SCRAM: server signature mismatch"));
        }
        Ok(())
    }
}

fn startup(s: &mut TcpStream, cfg: &PgConfig) -> io::Result<()> {
    let mut m: Vec<u8> = Vec::with_capacity(128);
    m.extend_from_slice(&[0, 0, 0, 0]);
    m.extend_from_slice(&196_608u32.to_be_bytes()); // protocol 3.0
    let params: [(&str, &str); 4] = [
        ("user", cfg.user.as_str()),
        ("database", cfg.dbname.as_str()),
        ("application_name", "conduit"),
        ("client_encoding", "UTF8"),
    ];
    for (k, v) in params.iter() {
        m.extend_from_slice(k.as_bytes());
        m.push(0);
        m.extend_from_slice(v.as_bytes());
        m.push(0);
    }
    m.push(0);
    let len = m.len() as u32;
    m[0..4].copy_from_slice(&len.to_be_bytes());
    s.write_all(&m)?;

    let mut scram: Option<Scram> = None;
    loop {
        let (tag, payload) = read_msg(s)?;
        match tag {
            b'R' => {
                if payload.len() < 4 {
                    return Err(proto("short authentication message"));
                }
                let code = i32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                match code {
                    0 => {}
                    3 => {
                        let mut out = Vec::with_capacity(cfg.password.len() + 8);
                        let b = msg_begin(&mut out, b'p');
                        out.extend_from_slice(cfg.password.as_bytes());
                        out.push(0);
                        msg_end(&mut out, b);
                        s.write_all(&out)?;
                    }
                    10 => {
                        if !contains(&payload[4..], b"SCRAM-SHA-256") {
                            return Err(proto("server offers no SCRAM-SHA-256"));
                        }
                        let (st, first) = Scram::start()?;
                        let mut out = Vec::with_capacity(64 + first.len());
                        let b = msg_begin(&mut out, b'p');
                        out.extend_from_slice(b"SCRAM-SHA-256\0");
                        out.extend_from_slice(&(first.len() as i32).to_be_bytes());
                        out.extend_from_slice(&first);
                        msg_end(&mut out, b);
                        s.write_all(&out)?;
                        scram = Some(st);
                    }
                    11 => {
                        let st = match scram.as_mut() {
                            Some(st) => st,
                            None => return Err(proto("unexpected SASLContinue")),
                        };
                        let server_first = String::from_utf8_lossy(&payload[4..]).into_owned();
                        let fin = st.client_final(&server_first, &cfg.password)?;
                        let mut out = Vec::with_capacity(32 + fin.len());
                        let b = msg_begin(&mut out, b'p');
                        out.extend_from_slice(&fin);
                        msg_end(&mut out, b);
                        s.write_all(&out)?;
                    }
                    12 => {
                        let st = match scram.as_ref() {
                            Some(st) => st,
                            None => return Err(proto("unexpected SASLFinal")),
                        };
                        let server_final = String::from_utf8_lossy(&payload[4..]).into_owned();
                        st.verify(&server_final)?;
                    }
                    5 => return Err(proto("server requested md5 authentication (unsupported)")),
                    other => {
                        return Err(proto(&format!("unsupported authentication request {}", other)))
                    }
                }
            }
            b'E' => {
                return Err(proto(&format!("startup failed: {}", error_text(&payload))));
            }
            b'Z' => return Ok(()),
            _ => {} // ParameterStatus, BackendKeyData, NoticeResponse
        }
    }
}

fn simple_query(s: &mut TcpStream, sql_text: &str) -> io::Result<()> {
    let mut m = Vec::with_capacity(sql_text.len() + 8);
    let b = msg_begin(&mut m, b'Q');
    m.extend_from_slice(sql_text.as_bytes());
    m.push(0);
    msg_end(&mut m, b);
    s.write_all(&m)?;
    loop {
        let (tag, payload) = read_msg(s)?;
        match tag {
            b'E' => {
                return Err(proto(&format!("{} -> {}", sql_text, error_text(&payload))));
            }
            b'Z' => return Ok(()),
            _ => {}
        }
    }
}

/// Parses every static statement (each followed by its own Sync, so one bad statement is reported
/// by index instead of cascading).
fn prepare_all(s: &mut TcpStream, stmts: &[(String, Vec<u32>)]) -> io::Result<()> {
    let mut buf: Vec<u8> = Vec::with_capacity(32 * 1024);
    for (i, (sql_text, oids)) in stmts.iter().enumerate() {
        parse_msg(&mut buf, sql::name(i), sql_text, oids);
        sync(&mut buf);
    }
    s.write_all(&buf)?;
    let mut idx = 0usize;
    let mut failures: Vec<String> = Vec::new();
    while idx < stmts.len() {
        let (tag, payload) = read_msg(s)?;
        match tag {
            b'E' => {
                let sql_text = &stmts[idx].0;
                let shown: String = sql_text.chars().take(120).collect();
                failures.push(format!("statement #{} [{}...]: {}", idx, shown, error_text(&payload)));
            }
            b'Z' => idx += 1,
            _ => {}
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(proto(&format!("PREPARE FAILED:\n{}", failures.join("\n"))))
    }
}

/// Connects, authenticates, applies session settings and prepares all statements. Blocking.
/// Returns a connection whose socket is non-blocking and ready for io_uring.
pub fn connect(cfg: &PgConfig, stmts: &[(String, Vec<u32>)]) -> io::Result<PgConn> {
    let mut s = TcpStream::connect((cfg.host.as_str(), cfg.port))?;
    s.set_nodelay(true)?;
    startup(&mut s, cfg)?;
    let set = format!(
        "SET jit = off; SET plan_cache_mode = {}; SET max_parallel_workers_per_gather = 0",
        cfg.plan_cache_mode
    );
    simple_query(&mut s, &set)?;
    prepare_all(&mut s, stmts)?;
    s.set_nonblocking(true)?;
    let fd = s.into_raw_fd();
    track_fd(fd);
    Ok(PgConn::new(fd))
}
