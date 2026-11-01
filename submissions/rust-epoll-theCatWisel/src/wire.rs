use std::io::{self, Read, Write};
use std::net::TcpStream;

use crate::auth;
use crate::codec;

pub const OID_INT8: u32 = 20;
pub const OID_INT4: u32 = 23;
pub const OID_TEXT: u32 = 25;
pub const OID_INT4_ARR: u32 = 1007;
pub const OID_INT8_ARR: u32 = 1016;
pub const OID_TEXT_ARR: u32 = 1009;

#[derive(Debug)]
pub struct SqlStateErr {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for SqlStateErr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

#[derive(Debug)]
pub enum PgError {
    Io(io::Error),
    Server(SqlStateErr),
    Wire(String),
}

impl From<io::Error> for PgError {
    fn from(e: io::Error) -> Self {
        PgError::Io(e)
    }
}

impl std::fmt::Display for PgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PgError::Io(e) => write!(f, "io: {e}"),
            PgError::Server(e) => write!(f, "db: {e}"),
            PgError::Wire(s) => write!(f, "wire: {s}"),
        }
    }
}

pub type PgResult<T> = std::result::Result<T, PgError>;

pub struct DbEndpoint {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
}

fn decode_url_part(s: &str) -> String {
    let raw = s.as_bytes();
    let mut out = Vec::with_capacity(raw.len());
    let mut i = 0;
    while i < raw.len() {
        if raw[i] == b'%' && i + 2 < raw.len() {
            if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(raw[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

impl DbEndpoint {
    pub fn parse(url: &str) -> Option<Self> {
        let rest = url
            .strip_prefix("postgres://")
            .or_else(|| url.strip_prefix("postgresql://"))?;
        let (creds, target) = rest.rsplit_once('@')?;
        let (user, pass) = creds.split_once(':').unwrap_or((creds, ""));
        let (addr, db_part) = target.split_once('/').unwrap_or((target, ""));
        let db = db_part.split('?').next().unwrap_or("");
        let (host, port) = match addr.rsplit_once(':') {
            Some((h, p)) => (h, p.parse().ok()?),
            None => (addr, 5432),
        };
        Some(DbEndpoint {
            host: host.to_string(),
            port,
            user: decode_url_part(user),
            password: decode_url_part(pass),
            database: decode_url_part(if db.is_empty() { user } else { db }),
        })
    }
}

#[derive(Default)]
pub struct TxBuf {
    pub buf: Vec<u8>,
}

impl TxBuf {
    #[inline]
    fn start_msg(&mut self, tag: u8) -> usize {
        self.buf.push(tag);
        let len_pos = self.buf.len();
        self.buf.extend_from_slice(&[0, 0, 0, 0]);
        len_pos
    }

    #[inline]
    fn finish_msg(&mut self, len_pos: usize) {
        let msg_len = (self.buf.len() - len_pos) as u32;
        self.buf[len_pos..len_pos + 4].copy_from_slice(&msg_len.to_be_bytes());
    }

    #[inline]
    fn put_cstr(&mut self, s: &str) {
        self.buf.extend_from_slice(s.as_bytes());
        self.buf.push(0);
    }

    #[inline]
    fn put_i16(&mut self, v: i16) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    #[inline]
    fn put_i32(&mut self, v: i32) {
        self.buf.extend_from_slice(&v.to_be_bytes());
    }

    pub fn write_parse(&mut self, name: &str, sql: &str, param_oids: &[u32]) {
        let pos = self.start_msg(b'P');
        self.put_cstr(name);
        self.put_cstr(sql);
        self.put_i16(param_oids.len() as i16);
        for &oid in param_oids {
            self.put_i32(oid as i32);
        }
        self.finish_msg(pos);
    }

    pub fn bind_and_exec(&mut self, stmt_name: &str, params: &[BindParam]) {
        let pos = self.start_msg(b'B');
        self.buf.push(0); // unnamed portal
        self.put_cstr(stmt_name);
        self.put_i16(1);
        self.put_i16(1); // binary format for all parameters
        self.put_i16(params.len() as i16);
        for p in params {
            p.encode(&mut self.buf);
        }
        self.put_i16(1);
        self.put_i16(1); // binary format for all result columns
        self.finish_msg(pos);

        let epos = self.start_msg(b'E');
        self.buf.push(0);
        self.put_i32(0);
        self.finish_msg(epos);
    }

    pub fn write_sync(&mut self) {
        let pos = self.start_msg(b'S');
        self.finish_msg(pos);
    }

    pub fn clear(&mut self) {
        self.buf.clear();
        if self.buf.capacity() > 1024 * 1024 {
            self.buf.shrink_to(128 * 1024);
        }
    }
}

pub enum BindParam<'a> {
    Null,
    I64(i64),
    Text(&'a [u8]),
    Raw(&'a [u8]),
    I64Slice(&'a [i64]),
    I32Slice(&'a [i32]),
    TextSlice(&'a [String]),
}

#[inline]
fn write_array_header(dst: &mut Vec<u8>, byte_len: usize, elem_oid: u32, count: usize) {
    dst.reserve(4 + byte_len);
    dst.extend_from_slice(&(byte_len as i32).to_be_bytes());
    dst.extend_from_slice(&1i32.to_be_bytes()); // 1 dimension
    dst.extend_from_slice(&0i32.to_be_bytes()); // flags
    dst.extend_from_slice(&elem_oid.to_be_bytes());
    dst.extend_from_slice(&(count as i32).to_be_bytes());
    dst.extend_from_slice(&1i32.to_be_bytes()); // 1-based lower bound
}

impl BindParam<'_> {
    #[inline]
    fn encode(&self, dst: &mut Vec<u8>) {
        match self {
            BindParam::Null => dst.extend_from_slice(&(-1i32).to_be_bytes()),
            BindParam::I64(v) => {
                dst.extend_from_slice(&8i32.to_be_bytes());
                dst.extend_from_slice(&v.to_be_bytes());
            }
            BindParam::Text(s) | BindParam::Raw(s) => {
                dst.extend_from_slice(&(s.len() as i32).to_be_bytes());
                dst.extend_from_slice(s);
            }
            BindParam::I64Slice(items) => {
                write_array_header(dst, 20 + items.len() * 12, OID_INT8, items.len());
                for &v in *items {
                    dst.extend_from_slice(&8i32.to_be_bytes());
                    dst.extend_from_slice(&v.to_be_bytes());
                }
            }
            BindParam::I32Slice(items) => {
                write_array_header(dst, 20 + items.len() * 8, OID_INT4, items.len());
                for &v in *items {
                    dst.extend_from_slice(&4i32.to_be_bytes());
                    dst.extend_from_slice(&v.to_be_bytes());
                }
            }
            BindParam::TextSlice(items) => {
                let payload: usize = items.iter().map(|s| 4 + s.len()).sum();
                write_array_header(dst, 20 + payload, OID_TEXT, items.len());
                for s in *items {
                    dst.extend_from_slice(&(s.len() as i32).to_be_bytes());
                    dst.extend_from_slice(s.as_bytes());
                }
            }
        }
    }
}

pub struct ArrayEncoder {
    pub buf: Vec<u8>,
    len: u32,
}

impl ArrayEncoder {
    pub fn with_capacity(elem_oid: u32, cap_items: usize) -> Self {
        let mut enc = ArrayEncoder {
            buf: Vec::with_capacity(20 + cap_items * 12),
            len: 0,
        };
        enc.reset(elem_oid, cap_items);
        enc
    }

    #[inline]
    pub fn reset(&mut self, elem_oid: u32, cap_items: usize) {
        self.buf.clear();
        self.buf.reserve(20 + cap_items * 12);
        self.buf.extend_from_slice(&1i32.to_be_bytes());
        self.buf.extend_from_slice(&0i32.to_be_bytes());
        self.buf.extend_from_slice(&elem_oid.to_be_bytes());
        self.buf.extend_from_slice(&0i32.to_be_bytes());
        self.buf.extend_from_slice(&1i32.to_be_bytes());
        self.len = 0;
    }

    #[inline]
    pub fn push_i64(&mut self, v: i64) {
        self.buf.extend_from_slice(&8i32.to_be_bytes());
        self.buf.extend_from_slice(&v.to_be_bytes());
        self.len += 1;
    }

    #[inline]
    pub fn push_bytes(&mut self, s: &[u8]) {
        self.buf.extend_from_slice(&(s.len() as i32).to_be_bytes());
        self.buf.extend_from_slice(s);
        self.len += 1;
    }

    #[inline]
    pub fn finish(&mut self) -> &[u8] {
        self.buf[12..16].copy_from_slice(&self.len.to_be_bytes());
        &self.buf
    }
}

#[derive(Clone, Copy)]
pub struct Cell {
    pub offset: u32,
    pub len: i32,
}

#[derive(Clone, Copy)]
pub struct RowSpan {
    pub start: u32,
    pub count: u16,
}

pub struct ExecOutcome {
    pub row_start: u32,
    pub row_count: u32,
    pub error: Option<SqlStateErr>,
}

// Reusable buffer holding all decoded DataRow payloads for one pipelined round trip.
pub struct PipelineBuf {
    pub data: Vec<u8>,
    pub cols: Vec<Cell>,
    pub rows: Vec<RowSpan>,
    pub results: Vec<ExecOutcome>,
}

impl PipelineBuf {
    pub fn with_capacity() -> Self {
        PipelineBuf {
            data: Vec::with_capacity(128 * 1024),
            cols: Vec::with_capacity(4096),
            rows: Vec::with_capacity(1024),
            results: Vec::with_capacity(32),
        }
    }

    pub fn clear(&mut self) {
        self.data.clear();
        if self.data.capacity() > 4 * 1024 * 1024 {
            self.data.shrink_to(512 * 1024);
        }
        self.cols.clear();
        self.rows.clear();
        self.results.clear();
    }

    #[inline]
    pub fn result_rows(&self, res_idx: usize) -> &[RowSpan] {
        let r = &self.results[res_idx];
        &self.rows[r.row_start as usize..(r.row_start + r.row_count) as usize]
    }

    #[inline]
    pub fn row(&self, span: RowSpan) -> &[Cell] {
        &self.cols[span.start as usize..span.start as usize + span.count as usize]
    }

    #[inline]
    pub fn bytes(&self, c: Cell) -> Option<&[u8]> {
        if c.len < 0 {
            None
        } else {
            Some(&self.data[c.offset as usize..c.offset as usize + c.len as usize])
        }
    }

    #[inline]
    pub fn i64(&self, c: Cell) -> i64 {
        match self.bytes(c) {
            Some(b) if b.len() == 8 => i64::from_be_bytes(b.try_into().unwrap()),
            Some(b) if b.len() == 4 => i32::from_be_bytes(b.try_into().unwrap()) as i64,
            _ => 0,
        }
    }
}

pub fn iter_binary_array(raw: &[u8]) -> impl Iterator<Item = &[u8]> {
    let (mut pos, mut rem) = if raw.len() < 12 {
        (0, 0)
    } else {
        let ndim = i32::from_be_bytes(raw[0..4].try_into().unwrap());
        if ndim <= 0 {
            (0, 0)
        } else {
            let count = i32::from_be_bytes(raw[12..16].try_into().unwrap()).max(0) as usize;
            (12 + 8 * ndim as usize, count)
        }
    };
    std::iter::from_fn(move || {
        while rem > 0 {
            rem -= 1;
            let len = i32::from_be_bytes(raw.get(pos..pos + 4)?.try_into().ok()?);
            pos += 4;
            if len < 0 {
                continue;
            }
            let slice = raw.get(pos..pos + len as usize)?;
            pos += len as usize;
            return Some(slice);
        }
        None
    })
}

pub struct PgConn {
    stream: TcpStream,
    rx: Vec<u8>,
    rpos: usize,
    rend: usize,
    pub tx: TxBuf,
}

fn sha256_digest(input: &[u8]) -> [u8; 32] {
    auth::sha256_digest(input)
}

fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    auth::hmac_sha256_oneshot(key, data)
}

fn b64_std_enc(data: &[u8]) -> String {
    codec::b64std_encode(data)
}

fn b64_std_dec(s: &str) -> Option<Vec<u8>> {
    codec::b64std_decode(s)
}

impl PgConn {
    pub fn connect(ep: &DbEndpoint) -> PgResult<Self> {
        let stream = TcpStream::connect((ep.host.as_str(), ep.port))?;
        stream.set_nodelay(true)?;
        let mut conn = PgConn {
            stream,
            rx: vec![0; 64 * 1024],
            rpos: 0,
            rend: 0,
            tx: TxBuf::default(),
        };

        let mut startup = Vec::with_capacity(256);
        startup.extend_from_slice(&0i32.to_be_bytes());
        startup.extend_from_slice(&196_608i32.to_be_bytes());
        for (k, v) in [
            ("user", ep.user.as_str()),
            ("database", ep.database.as_str()),
            ("client_encoding", "UTF8"),
            ("DateStyle", "ISO"),
            ("plan_cache_mode", "force_generic_plan"),
            ("jit", "off"),
            ("max_parallel_workers_per_gather", "0"),
            ("work_mem", "32MB"),
            ("random_page_cost", "1.1"),
            ("effective_io_concurrency", "200"),
        ] {
            startup.extend_from_slice(k.as_bytes());
            startup.push(0);
            startup.extend_from_slice(v.as_bytes());
            startup.push(0);
        }
        startup.push(0);
        let total_len = startup.len() as i32;
        startup[0..4].copy_from_slice(&total_len.to_be_bytes());
        conn.stream.write_all(&startup)?;
        conn.authenticate(ep)?;
        Ok(conn)
    }

    fn write_packet(&mut self, tag: u8, payload: &[u8]) -> PgResult<()> {
        let mut pkt = Vec::with_capacity(payload.len() + 5);
        pkt.push(tag);
        pkt.extend_from_slice(&((payload.len() + 4) as i32).to_be_bytes());
        pkt.extend_from_slice(payload);
        self.stream.write_all(&pkt)?;
        Ok(())
    }

    fn authenticate(&mut self, ep: &DbEndpoint) -> PgResult<()> {
        let mut scram_state: Option<(String, String)> = None;
        let mut expected_srv_sig: Option<[u8; 32]> = None;
        loop {
            let (tag, body_ref) = self.next_frame()?;
            let body = body_ref.to_vec();
            match tag {
                b'R' => {
                    let method = i32::from_be_bytes(body[0..4].try_into().unwrap());
                    match method {
                        0 => {}
                        3 => {
                            let mut pw = ep.password.as_bytes().to_vec();
                            pw.push(0);
                            self.write_packet(b'p', &pw)?;
                        }
                        10 => {
                            let mechs = String::from_utf8_lossy(&body[4..]).to_string();
                            if !mechs.split('\0').any(|m| m == "SCRAM-SHA-256") {
                                return Err(PgError::Wire(format!("unsupported SASL mechanisms: {mechs}")));
                            }
                            let mut raw_nonce = [0u8; 18];
                            if !codec::fill_random(&mut raw_nonce) {
                                return Err(PgError::Wire("getrandom failed".into()));
                            }
                            let nonce = b64_std_enc(&raw_nonce);
                            let bare = format!("n=,r={nonce}");
                            let first = format!("n,,{bare}");
                            let mut msg = Vec::new();
                            msg.extend_from_slice(b"SCRAM-SHA-256\0");
                            msg.extend_from_slice(&(first.len() as i32).to_be_bytes());
                            msg.extend_from_slice(first.as_bytes());
                            self.write_packet(b'p', &msg)?;
                            scram_state = Some((bare, nonce));
                        }
                        11 => {
                            let (bare, nonce) = scram_state.clone().ok_or_else(|| PgError::Wire("SASL state".into()))?;
                            let srv_first = String::from_utf8_lossy(&body[4..]).to_string();
                            let mut r_tok = None;
                            let mut salt = None;
                            let mut iters = None;
                            for part in srv_first.split(',') {
                                if let Some(v) = part.strip_prefix("r=") {
                                    r_tok = Some(v.to_string());
                                } else if let Some(v) = part.strip_prefix("s=") {
                                    salt = b64_std_dec(v);
                                } else if let Some(v) = part.strip_prefix("i=") {
                                    iters = v.parse::<u32>().ok();
                                }
                            }
                            let (r_tok, salt, iters) = match (r_tok, salt, iters) {
                                (Some(r), Some(s), Some(i)) if r.starts_with(&nonce) => (r, s, i),
                                _ => return Err(PgError::Wire("invalid SCRAM server-first".into())),
                            };
                            let mut u = {
                                let mut s1 = salt.clone();
                                s1.extend_from_slice(&1u32.to_be_bytes());
                                hmac_sha256(ep.password.as_bytes(), &s1)
                            };
                            let mut salted_pw = u;
                            for _ in 1..iters {
                                u = hmac_sha256(ep.password.as_bytes(), &u);
                                for b in 0..32 {
                                    salted_pw[b] ^= u[b];
                                }
                            }
                            let client_key = hmac_sha256(&salted_pw, b"Client Key");
                            let stored_key = sha256_digest(&client_key);
                            let no_proof = format!("c=biws,r={r_tok}");
                            let auth_msg = format!("{bare},{srv_first},{no_proof}");
                            let client_sig = hmac_sha256(&stored_key, auth_msg.as_bytes());
                            let mut proof = client_key;
                            for b in 0..32 {
                                proof[b] ^= client_sig[b];
                            }
                            let server_key = hmac_sha256(&salted_pw, b"Server Key");
                            expected_srv_sig = Some(hmac_sha256(&server_key, auth_msg.as_bytes()));
                            let final_msg = format!("{no_proof},p={}", b64_std_enc(&proof));
                            self.write_packet(b'p', final_msg.as_bytes())?;
                        }
                        12 => {
                            let srv_final = String::from_utf8_lossy(&body[4..]).to_string();
                            let verifier = srv_final.strip_prefix("v=").and_then(b64_std_dec);
                            if verifier.as_deref() != expected_srv_sig.as_ref().map(|s| &s[..]) {
                                return Err(PgError::Wire("SCRAM server signature mismatch".into()));
                            }
                        }
                        other => return Err(PgError::Wire(format!("unsupported auth code {other}"))),
                    }
                }
                b'E' => return Err(PgError::Server(decode_error(&body))),
                b'Z' => return Ok(()),
                _ => {}
            }
        }
    }

    #[inline]
    fn next_frame(&mut self) -> PgResult<(u8, &[u8])> {
        self.ensure_bytes(5)?;
        let tag = self.rx[self.rpos];
        let len = i32::from_be_bytes(self.rx[self.rpos + 1..self.rpos + 5].try_into().unwrap()) as usize;
        self.ensure_bytes(1 + len)?;
        let payload_start = self.rpos + 5;
        self.rpos += 1 + len;
        Ok((tag, &self.rx[payload_start..payload_start + len - 4]))
    }

    #[inline]
    fn ensure_bytes(&mut self, needed: usize) -> PgResult<()> {
        if self.rend - self.rpos >= needed {
            return Ok(());
        }
        if self.rpos == self.rend {
            self.rpos = 0;
            self.rend = 0;
        } else if self.rpos > 0 {
            self.rx.copy_within(self.rpos..self.rend, 0);
            self.rend -= self.rpos;
            self.rpos = 0;
        }
        if self.rx.len() < needed {
            self.rx.resize(needed.next_power_of_two(), 0);
        }
        while self.rend < needed {
            let n = self.stream.read(&mut self.rx[self.rend..])?;
            if n == 0 {
                return Err(PgError::Io(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "postgres connection closed",
                )));
            }
            self.rend += n;
        }
        Ok(())
    }

    pub fn flush(&mut self) -> PgResult<()> {
        self.stream.write_all(&self.tx.buf)?;
        self.tx.clear();
        Ok(())
    }

    pub fn read_pipeline_into(&mut self, expected_execs: usize, out: &mut PipelineBuf) -> PgResult<()> {
        out.clear();
        let mut row_start = 0u32;
        loop {
            let (tag, body) = self.next_frame()?;
            match tag {
                b'D' => {
                    let ncols = u16::from_be_bytes(body[0..2].try_into().unwrap());
                    let col_start = out.cols.len() as u32;
                    let mut p = 2;
                    for _ in 0..ncols {
                        let len = i32::from_be_bytes(body[p..p + 4].try_into().unwrap());
                        p += 4;
                        if len < 0 {
                            out.cols.push(Cell { offset: 0, len: -1 });
                        } else {
                            let offset = out.data.len() as u32;
                            out.data.extend_from_slice(&body[p..p + len as usize]);
                            p += len as usize;
                            out.cols.push(Cell { offset, len });
                        }
                    }
                    out.rows.push(RowSpan {
                        start: col_start,
                        count: ncols,
                    });
                }
                b'C' => {
                    let total = out.rows.len() as u32;
                    out.results.push(ExecOutcome {
                        row_start,
                        row_count: total - row_start,
                        error: None,
                    });
                    row_start = total;
                }
                b'E' => {
                    let total = out.rows.len() as u32;
                    out.results.push(ExecOutcome {
                        row_start,
                        row_count: total - row_start,
                        error: Some(decode_error(body)),
                    });
                    row_start = total;
                }
                b'I' => out.results.push(ExecOutcome {
                    row_start,
                    row_count: 0,
                    error: None,
                }),
                b'Z' => break,
                b'1' | b'2' | b'3' | b'n' | b't' | b'T' | b'N' | b'S' | b'A' | b's' => {}
                other => return Err(PgError::Wire(format!("unexpected frame {:?}", other as char))),
            }
        }
        while out.results.len() < expected_execs {
            out.results.push(ExecOutcome {
                row_start,
                row_count: 0,
                error: Some(SqlStateErr {
                    code: "skipped".into(),
                    message: "aborted by earlier pipeline error".into(),
                }),
            });
        }
        Ok(())
    }

    pub fn prepare_batch(&mut self, stmts: &[(&str, &str, &[u32])]) -> PgResult<()> {
        for &(name, sql, oids) in stmts {
            self.tx.write_parse(name, sql, oids);
        }
        self.tx.write_sync();
        self.flush()?;
        loop {
            let (tag, body) = self.next_frame()?;
            match tag {
                b'E' => {
                    let err = decode_error(body);
                    loop {
                        let (t, _) = self.next_frame()?;
                        if t == b'Z' {
                            break;
                        }
                    }
                    return Err(PgError::Server(err));
                }
                b'Z' => return Ok(()),
                _ => {}
            }
        }
    }
}

fn decode_error(body: &[u8]) -> SqlStateErr {
    let mut code = String::new();
    let mut message = String::new();
    for field in body.split(|&b| b == 0) {
        if field.is_empty() {
            continue;
        }
        let text = String::from_utf8_lossy(&field[1..]).into_owned();
        match field[0] {
            b'C' => code = text,
            b'M' => message = text,
            _ => {}
        }
    }
    SqlStateErr { code, message }
}
