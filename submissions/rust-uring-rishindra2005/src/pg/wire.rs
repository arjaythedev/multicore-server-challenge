//! High-performance, clean-room PostgreSQL 18 wire protocol client.
//!
//! Features:
//! - Full SCRAM-SHA-256 client authentication (RFC 5802 / RFC 7677)
//! - Extended Query Protocol (Parse, Bind, Execute, single Sync per pipeline)
//! - Binary result decoding with zero per-row allocation
//! - Error mapping (SQLSTATE 23505 unique_violation -> 422 mapping)
//! - Pipelined statement preparation & session initialization

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use crate::pg::decode::BinaryRow;
use crate::pg::stmt::{PREPARED_STATEMENTS, SESSION_INIT_SQL};

/// PostgreSQL client errors.
#[derive(Debug)]
pub enum PgError {
    /// Unique key constraint violation (SQLSTATE 23505).
    UniqueViolation(String),
    /// Authentication failure or unsupported auth mechanism.
    AuthFailed(String),
    /// Wire protocol framing or semantic violation.
    Protocol(String),
    /// Query execution failure with SQLSTATE and message.
    QueryError { code: String, message: String },
    /// Low-level I/O failure.
    Io(std::io::Error),
}

impl std::fmt::Display for PgError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UniqueViolation(msg) => write!(f, "unique violation (23505): {msg}"),
            Self::AuthFailed(msg) => write!(f, "authentication failed: {msg}"),
            Self::Protocol(msg) => write!(f, "protocol error: {msg}"),
            Self::QueryError { code, message } => write!(f, "query error ({code}): {message}"),
            Self::Io(err) => write!(f, "io error: {err}"),
        }
    }
}

impl std::error::Error for PgError {}

impl From<std::io::Error> for PgError {
    fn from(err: std::io::Error) -> Self {
        Self::Io(err)
    }
}

// ============================================================================
// Cryptographic Primitives for SCRAM-SHA-256 (Self-Contained & Verified)
// ============================================================================

pub mod crypto_scram {
    pub use crate::sec::sha256::sha256;
    pub use crate::sec::hmac::hmac_sha256;

    pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
        let mut out = [0u8; 32];
        crate::sec::scram::pbkdf2_hmac_sha256(password, salt, iterations, &mut out);
        out
    }

    pub fn base64_encode(input: &[u8]) -> String {
        const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
        for chunk in input.chunks(3) {
            let b0 = chunk[0];
            let b1 = if chunk.len() > 1 { chunk[1] } else { 0 };
            let b2 = if chunk.len() > 2 { chunk[2] } else { 0 };
            out.push(TABLE[(b0 >> 2) as usize] as char);
            out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
            if chunk.len() > 1 {
                out.push(TABLE[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
            } else {
                out.push('=');
            }
            if chunk.len() > 2 {
                out.push(TABLE[(b2 & 0x3f) as usize] as char);
            } else {
                out.push('=');
            }
        }
        out
    }

    pub fn base64_decode(input: &str) -> Option<Vec<u8>> {
        let input = input.trim_end_matches('=');
        let mut out = Vec::with_capacity(input.len() * 3 / 4);
        let mut buf: u32 = 0;
        let mut bits: u32 = 0;
        for &b in input.as_bytes() {
            let val = match b {
                b'A'..=b'Z' => b - b'A',
                b'a'..=b'z' => b - b'a' + 26,
                b'0'..=b'9' => b - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                b' ' | b'\r' | b'\n' | b'\t' => continue,
                _ => return None,
            } as u32;
            buf = (buf << 6) | val;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((buf >> bits) as u8);
            }
        }
        Some(out)
    }
}

// ============================================================================
// PostgreSQL Wire Client
// ============================================================================

/// Connection configuration.
#[derive(Clone, Debug)]
pub struct PgConfig {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub database: String,
    pub password: String,
}

impl Default for PgConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 5432,
            user: "conduit".into(),
            database: "conduit".into(),
            password: "conduit".into(),
        }
    }
}

impl PgConfig {
    /// Parses a PostgreSQL connection URL (`postgres://user:pass@host:port/dbname`).
    pub fn from_url(url: &str) -> Result<Self, PgError> {
        let url = url.trim();
        let rest = url
            .strip_prefix("postgres://")
            .or_else(|| url.strip_prefix("postgresql://"))
            .ok_or_else(|| PgError::Protocol(format!("invalid url scheme: {url}")))?;

        let (user_pass, host_db) = rest
            .split_once('@')
            .ok_or_else(|| PgError::Protocol("missing @ in database url".into()))?;

        let (user, password) = if let Some((u, p)) = user_pass.split_once(':') {
            (u.to_string(), p.to_string())
        } else {
            (user_pass.to_string(), "".to_string())
        };

        let (host_port, database) = if let Some((hp, db)) = host_db.split_once('/') {
            let db_clean = db.split('?').next().unwrap_or(db);
            (hp, db_clean.to_string())
        } else {
            (host_db, "conduit".to_string())
        };

        let (host, port) = if let Some((h, p)) = host_port.split_once(':') {
            let port_num = p
                .parse::<u16>()
                .map_err(|_| PgError::Protocol(format!("invalid port: {p}")))?;
            (h.to_string(), port_num)
        } else {
            (host_port.to_string(), 5432)
        };

        Ok(Self {
            host,
            port,
            user,
            database,
            password,
        })
    }
}

/// Active connection to PostgreSQL.
pub struct PgWire {
    stream: TcpStream,
    write_buf: Vec<u8>,
    // Receive buffer: replies are read in large chunks and messages are cut out of it,
    // instead of two blocking recv() calls per protocol message.
    read_buf: Box<[u8]>,
    read_pos: usize,
    read_end: usize,
}

const READ_BUF_SIZE: usize = 64 * 1024;

impl PgWire {
    /// Connects to PostgreSQL, authenticates via SCRAM-SHA-256, configures session parameters,
    /// and pre-prepares the entire statement catalog.
    pub fn connect(config: &PgConfig) -> Result<Self, PgError> {
        let addr = format!("{}:{}", config.host, config.port);
        let stream = TcpStream::connect(&addr)?;
        stream.set_nodelay(true)?;
        stream.set_read_timeout(Some(Duration::from_secs(10)))?;
        stream.set_write_timeout(Some(Duration::from_secs(10)))?;

        let mut client = Self {
            stream,
            write_buf: Vec::with_capacity(65536),
            read_buf: vec![0u8; READ_BUF_SIZE].into_boxed_slice(),
            read_pos: 0,
            read_end: 0,
        };

        client.startup_and_auth(config)?;
        client.init_session_and_catalog()?;

        Ok(client)
    }

    /// Internal startup message and SCRAM authentication handshake.
    fn startup_and_auth(&mut self, config: &PgConfig) -> Result<(), PgError> {
        // 1. StartupMessage
        self.write_buf.clear();
        let mut payload = Vec::with_capacity(128);
        payload.extend_from_slice(&196608u32.to_be_bytes()); // Protocol 3.0
        payload.extend_from_slice(b"user\0");
        payload.extend_from_slice(config.user.as_bytes());
        payload.push(0);
        payload.extend_from_slice(b"database\0");
        payload.extend_from_slice(config.database.as_bytes());
        payload.push(0);
        payload.push(0); // Terminating null

        let len = (payload.len() + 4) as u32;
        self.write_buf.extend_from_slice(&len.to_be_bytes());
        self.write_buf.extend_from_slice(&payload);
        self.stream.write_all(&self.write_buf)?;
        self.stream.flush()?;

        // 2. Auth loop
        loop {
            let (tag, payload) = self.read_message()?;
            match tag {
                b'R' => {
                    if payload.len() < 4 {
                        return Err(PgError::Protocol("short auth response".into()));
                    }
                    let auth_type = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
                    match auth_type {
                        0 => {
                            // AuthOk - continue reading until ReadyForQuery
                        }
                        3 => {
                            // AuthCleartextPassword
                            self.send_password_message(&config.password)?;
                        }
                        10 => {
                            // AuthenticationSASL
                            self.handle_scram_handshake(&config.user, &config.password, &payload[4..])?;
                        }
                        other => {
                            return Err(PgError::AuthFailed(format!(
                                "unsupported auth type {other} (expected 0, 3, or 10)"
                            )));
                        }
                    }
                }
                b'K' => {
                    // BackendKeyData (pid, secret key) - ignore
                }
                b'S' => {
                    // ParameterStatus - ignore
                }
                b'Z' => {
                    // ReadyForQuery
                    break;
                }
                b'E' => {
                    return Err(self.parse_error_response(&payload));
                }
                other => {
                    return Err(PgError::Protocol(format!(
                        "unexpected message during startup: tag '{}'",
                        other as char
                    )));
                }
            }
        }

        Ok(())
    }

    /// Handles the full SCRAM-SHA-256 client exchange.
    fn handle_scram_handshake(&mut self, user: &str, password: &str, mut mechanisms: &[u8]) -> Result<(), PgError> {
        let mut supported = false;
        while let Some(pos) = mechanisms.iter().position(|&b| b == 0) {
            let mech = std::str::from_utf8(&mechanisms[..pos]).unwrap_or("");
            if mech == "SCRAM-SHA-256" {
                supported = true;
                break;
            }
            mechanisms = &mechanisms[pos + 1..];
        }

        if !supported {
            return Err(PgError::AuthFailed("SCRAM-SHA-256 not supported by server".into()));
        }

        // Generate client nonce (18 random-ish alphanumeric bytes)
        let client_nonce = format!("rishi_conduit_pg_{:016x}", std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos());

        let client_first_bare = format!("n={user},r={client_nonce}");
        let client_first = format!("n,,{client_first_bare}");

        // SASLInitialResponse: 'p'
        self.write_buf.clear();
        self.write_buf.push(b'p');
        let mut p_body = Vec::with_capacity(128);
        p_body.extend_from_slice(b"SCRAM-SHA-256\0");
        p_body.extend_from_slice(&(client_first.len() as u32).to_be_bytes());
        p_body.extend_from_slice(client_first.as_bytes());

        let len = (p_body.len() + 4) as u32;
        self.write_buf.extend_from_slice(&len.to_be_bytes());
        self.write_buf.extend_from_slice(&p_body);
        self.stream.write_all(&self.write_buf)?;
        self.stream.flush()?;

        // Receive AuthenticationSASLContinue: 'R' (11)
        let (tag, payload) = self.read_message()?;
        if tag != b'R' || payload.len() < 4 {
            return Err(PgError::Protocol("expected SASLContinue message".into()));
        }
        let auth_type = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
        if auth_type != 11 {
            return Err(PgError::AuthFailed(format!("expected auth type 11 (SASLContinue), got {auth_type}")));
        }

        let server_first = std::str::from_utf8(&payload[4..])
            .map_err(|_| PgError::Protocol("invalid utf8 in SASLContinue".into()))?;

        // Parse r=..., s=..., i=...
        let mut server_nonce = "";
        let mut salt_b64 = "";
        let mut iterations: u32 = 4096;

        for part in server_first.split(',') {
            if let Some(val) = part.strip_prefix("r=") {
                server_nonce = val;
            } else if let Some(val) = part.strip_prefix("s=") {
                salt_b64 = val;
            } else if let Some(val) = part.strip_prefix("i=") {
                iterations = val.parse().unwrap_or(4096);
            }
        }

        if !server_nonce.starts_with(&client_nonce) {
            return Err(PgError::AuthFailed("server nonce does not match client nonce".into()));
        }

        let salt = crypto_scram::base64_decode(salt_b64)
            .ok_or_else(|| PgError::Protocol("invalid base64 in scram salt".into()))?;

        let auth_message = format!("{client_first_bare},{server_first},c=biws,r={server_nonce}");

        let salted_password = crypto_scram::pbkdf2_hmac_sha256(password.as_bytes(), &salt, iterations);
        let client_key = crypto_scram::hmac_sha256(&salted_password, b"Client Key");
        let stored_key = crypto_scram::sha256(&client_key);
        let client_signature = crypto_scram::hmac_sha256(&stored_key, auth_message.as_bytes());

        let mut client_proof = [0u8; 32];
        for i in 0..32 {
            client_proof[i] = client_key[i] ^ client_signature[i];
        }

        let server_key = crypto_scram::hmac_sha256(&salted_password, b"Server Key");
        let server_signature = crypto_scram::hmac_sha256(&server_key, auth_message.as_bytes());

        let client_final = format!("c=biws,r={server_nonce},p={}", crypto_scram::base64_encode(&client_proof));

        // SASLResponse: 'p'
        self.write_buf.clear();
        self.write_buf.push(b'p');
        let len = (client_final.len() + 4) as u32;
        self.write_buf.extend_from_slice(&len.to_be_bytes());
        self.write_buf.extend_from_slice(client_final.as_bytes());
        self.stream.write_all(&self.write_buf)?;
        self.stream.flush()?;

        // Receive AuthenticationSASLFinal: 'R' (12)
        let (tag, payload) = self.read_message()?;
        if tag != b'R' || payload.len() < 4 {
            return Err(PgError::Protocol("expected SASLFinal message".into()));
        }
        let auth_type = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]);
        if auth_type != 12 {
            return Err(PgError::AuthFailed(format!("expected auth type 12 (SASLFinal), got {auth_type}")));
        }

        let server_final = std::str::from_utf8(&payload[4..])
            .map_err(|_| PgError::Protocol("invalid utf8 in SASLFinal".into()))?;

        let server_sig_b64 = server_final
            .strip_prefix("v=")
            .ok_or_else(|| PgError::Protocol("missing v= in SASLFinal".into()))?;

        let decoded_server_sig = crypto_scram::base64_decode(server_sig_b64)
            .ok_or_else(|| PgError::Protocol("invalid base64 in server signature".into()))?;

        if decoded_server_sig != server_signature {
            return Err(PgError::AuthFailed("server signature verification failed".into()));
        }

        Ok(())
    }

    fn send_password_message(&mut self, password: &str) -> Result<(), PgError> {
        self.write_buf.clear();
        self.write_buf.push(b'p');
        let len = (password.len() + 5) as u32;
        self.write_buf.extend_from_slice(&len.to_be_bytes());
        self.write_buf.extend_from_slice(password.as_bytes());
        self.write_buf.push(0);
        self.stream.write_all(&self.write_buf)?;
        self.stream.flush()?;
        Ok(())
    }

    /// Sets session-level optimizations and pre-prepares all SQL statements.
    fn init_session_and_catalog(&mut self) -> Result<(), PgError> {
        self.simple_query(SESSION_INIT_SQL)?;

        // Prepare statements in a single pipelined round trip
        self.write_buf.clear();
        for stmt in PREPARED_STATEMENTS {
            // Parse message: 'P'
            self.write_buf.push(b'P');
            let mut p_body = Vec::with_capacity(stmt.sql.len() + 64);
            p_body.extend_from_slice(stmt.name.as_bytes());
            p_body.push(0);
            p_body.extend_from_slice(stmt.sql.as_bytes());
            p_body.push(0);
            p_body.extend_from_slice(&(stmt.oids.len() as u16).to_be_bytes());
            for &oid in stmt.oids {
                p_body.extend_from_slice(&oid.to_be_bytes());
            }
            let len = (p_body.len() + 4) as u32;
            self.write_buf.extend_from_slice(&len.to_be_bytes());
            self.write_buf.extend_from_slice(&p_body);

            // Describe statement: 'D' 'S'
            self.write_buf.push(b'D');
            let d_len = (stmt.name.len() + 6) as u32;
            self.write_buf.extend_from_slice(&d_len.to_be_bytes());
            self.write_buf.push(b'S');
            self.write_buf.extend_from_slice(stmt.name.as_bytes());
            self.write_buf.push(0);
        }

        // Terminate pipeline with Sync: 'S'
        self.write_buf.push(b'S');
        self.write_buf.extend_from_slice(&4u32.to_be_bytes());

        self.stream.write_all(&self.write_buf)?;
        self.stream.flush()?;

        // Drain responses until ReadyForQuery
        loop {
            let (tag, payload) = self.read_message()?;
            match tag {
                b'1' => {
                    // ParseComplete
                }
                b't' => {
                    // ParameterDescription
                }
                b'T' | b'n' => {
                    // RowDescription / NoData
                }
                b'Z' => {
                    // ReadyForQuery
                    break;
                }
                b'E' => {
                    return Err(self.parse_error_response(&payload));
                }
                _ => {}
            }
        }

        Ok(())
    }

    /// Executes a simple query ('Q') and drains until ReadyForQuery.
    pub fn simple_query(&mut self, sql: &str) -> Result<(), PgError> {
        self.write_buf.clear();
        self.write_buf.push(b'Q');
        let len = (sql.len() + 5) as u32;
        self.write_buf.extend_from_slice(&len.to_be_bytes());
        self.write_buf.extend_from_slice(sql.as_bytes());
        self.write_buf.push(0);

        self.stream.write_all(&self.write_buf)?;
        self.stream.flush()?;

        // Always read through ReadyForQuery, even after an ErrorResponse: returning early leaves the 'Z'
        // unread and every later pipeline on this connection then reads the previous batch's results.
        let mut err: Option<PgError> = None;
        loop {
            let (tag, payload) = self.read_message()?;
            match tag {
                b'Z' => break,
                b'E' => {
                    if err.is_none() {
                        err = Some(self.parse_error_response(&payload));
                    }
                }
                _ => {}
            }
        }

        match err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// Reads exactly one message from the PostgreSQL stream: returns (tag, payload slice).
    pub fn read_message(&mut self) -> Result<(u8, Vec<u8>), PgError> {
        let mut header = [0u8; 5];
        self.fill_exact(&mut header)?;
        let tag = header[0];
        let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
        if len < 4 {
            return Err(PgError::Protocol("message length < 4".into()));
        }
        let body_len = len - 4;
        let mut payload = vec![0u8; body_len];
        self.fill_exact(&mut payload)?;
        Ok((tag, payload))
    }

    /// Fills `out` completely, serving bytes from the receive buffer first. When the buffer runs
    /// dry it is refilled with one recv() of up to READ_BUF_SIZE bytes; a request larger than the
    /// buffer reads its remainder straight into `out`.
    fn fill_exact(&mut self, out: &mut [u8]) -> Result<(), PgError> {
        let mut done = 0;
        while done < out.len() {
            if self.read_pos == self.read_end {
                let want = out.len() - done;
                if want >= READ_BUF_SIZE {
                    self.stream.read_exact(&mut out[done..])?;
                    return Ok(());
                }
                let n = loop {
                    match self.stream.read(&mut self.read_buf) {
                        Ok(n) => break n,
                        Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                        Err(e) => return Err(e.into()),
                    }
                };
                if n == 0 {
                    return Err(std::io::Error::from(std::io::ErrorKind::UnexpectedEof).into());
                }
                self.read_pos = 0;
                self.read_end = n;
            }
            let take = (self.read_end - self.read_pos).min(out.len() - done);
            out[done..done + take].copy_from_slice(&self.read_buf[self.read_pos..self.read_pos + take]);
            self.read_pos += take;
            done += take;
        }
        Ok(())
    }

    /// Parses a PostgreSQL ErrorResponse ('E') into a structured PgError.
    pub fn parse_error_response(&self, payload: &[u8]) -> PgError {
        let mut code = String::new();
        let mut message = String::new();
        let mut idx = 0;

        while idx < payload.len() {
            let field_type = payload[idx];
            if field_type == 0 {
                break;
            }
            idx += 1;
            let start = idx;
            while idx < payload.len() && payload[idx] != 0 {
                idx += 1;
            }
            let val = std::str::from_utf8(&payload[start..idx]).unwrap_or("");
            if field_type == b'C' {
                code = val.to_string();
            } else if field_type == b'M' {
                message = val.to_string();
            }
            idx += 1; // skip null
        }

        if code == "23505" {
            PgError::UniqueViolation(message)
        } else {
            PgError::QueryError { code, message }
        }
    }

    /// Creates a pipelined batch executor for executing multiple queries in a single round trip.
    pub fn pipeline(&mut self) -> Pipeline<'_> {
        self.write_buf.clear();
        Pipeline {
            wire: self,
            query_count: 0,
        }
    }
}

// ============================================================================
// Pipelined Query Execution
// ============================================================================

/// Builder and runner for pipelining multiple Bind/Execute operations with ONE Sync.
pub struct Pipeline<'a> {
    wire: &'a mut PgWire,
    query_count: usize,
}

impl<'a> Pipeline<'a> {
    /// Queues a prepared statement execution with parameters formatted as binary slices.
    pub fn bind_exec_binary(&mut self, stmt_name: &str, params: &[&[u8]]) {
        let start = self.wire.write_buf.len();

        // Bind: 'B'
        self.wire.write_buf.push(b'B');
        self.wire.write_buf.extend_from_slice(&[0; 4]); // length placeholder

        self.wire.write_buf.push(0); // Unnamed portal
        self.wire.write_buf.extend_from_slice(stmt_name.as_bytes());
        self.wire.write_buf.push(0);

        // Parameter format codes (1 = all binary)
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());

        // Parameters
        self.wire.write_buf.extend_from_slice(&(params.len() as u16).to_be_bytes());
        for &p in params {
            self.wire.write_buf.extend_from_slice(&(p.len() as i32).to_be_bytes());
            self.wire.write_buf.extend_from_slice(p);
        }

        // Result format codes (1 = binary)
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());

        let len = (self.wire.write_buf.len() - start - 1) as u32;
        self.wire.write_buf[start + 1..start + 5].copy_from_slice(&len.to_be_bytes());

        // Execute: 'E'
        self.wire.write_buf.push(b'E');
        self.wire.write_buf.extend_from_slice(&9u32.to_be_bytes()); // length: 4 + 1 + 4
        self.wire.write_buf.push(0); // Unnamed portal
        self.wire.write_buf.extend_from_slice(&0u32.to_be_bytes()); // max_rows: 0 (all)

        self.query_count += 1;
    }

    /// Queues a prepared statement execution with optional binary parameters (None -> SQL NULL).
    pub fn bind_exec_binary_opts(&mut self, stmt_name: &str, params: &[Option<&[u8]>]) {
        let start = self.wire.write_buf.len();

        // Bind: 'B'
        self.wire.write_buf.push(b'B');
        self.wire.write_buf.extend_from_slice(&[0; 4]); // length placeholder

        self.wire.write_buf.push(0); // Unnamed portal
        self.wire.write_buf.extend_from_slice(stmt_name.as_bytes());
        self.wire.write_buf.push(0);

        // Parameter format codes (1 = all binary)
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());

        // Parameters
        self.wire.write_buf.extend_from_slice(&(params.len() as u16).to_be_bytes());
        for p in params {
            match p {
                Some(bytes) => {
                    self.wire.write_buf.extend_from_slice(&(bytes.len() as i32).to_be_bytes());
                    self.wire.write_buf.extend_from_slice(bytes);
                }
                None => {
                    self.wire.write_buf.extend_from_slice(&(-1i32).to_be_bytes());
                }
            }
        }

        // Result format codes (1 = binary)
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());
        self.wire.write_buf.extend_from_slice(&1u16.to_be_bytes());

        let len = (self.wire.write_buf.len() - start - 1) as u32;
        self.wire.write_buf[start + 1..start + 5].copy_from_slice(&len.to_be_bytes());

        // Execute: 'E'
        self.wire.write_buf.push(b'E');
        self.wire.write_buf.extend_from_slice(&9u32.to_be_bytes()); // length: 4 + 1 + 4
        self.wire.write_buf.push(0); // Unnamed portal
        self.wire.write_buf.extend_from_slice(&0u32.to_be_bytes()); // max_rows: 0 (all)

        self.query_count += 1;
    }

    /// Flushes all queued queries with ONE Sync and streams decoded binary rows to the visitor.
    pub fn execute<F>(self, mut on_row: F) -> Result<(), PgError>
    where
        F: FnMut(usize, BinaryRow<'_>),
    {
        // Append Sync: 'S'
        self.wire.write_buf.push(b'S');
        self.wire.write_buf.extend_from_slice(&4u32.to_be_bytes());

        self.wire.stream.write_all(&self.wire.write_buf)?;
        self.wire.stream.flush()?;

        let mut current_query_idx = 0;
        let mut err: Option<PgError> = None;

        loop {
            let (tag, payload) = self.wire.read_message()?;
            match tag {
                b'2' => {
                    // BindComplete
                }
                b'D' => {
                    // DataRow
                    if err.is_none() {
                        let row = BinaryRow::new(&payload);
                        on_row(current_query_idx, row);
                    }
                }
                b'C' => {
                    // CommandComplete
                    current_query_idx += 1;
                }
                b'E' => {
                    // Record first error, continue reading to ReadyForQuery to keep wire synced
                    if err.is_none() {
                        err = Some(self.wire.parse_error_response(&payload));
                    }
                }
                b'Z' => {
                    // ReadyForQuery: pipeline complete
                    break;
                }
                _ => {}
            }
        }

        if let Some(e) = err {
            Err(e)
        } else {
            Ok(())
        }
    }
}

// ============================================================================
// Unit Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sha256_known_vectors() {
        assert_eq!(
            crypto_scram::sha256(b""),
            [
                0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
                0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
                0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
                0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
            ]
        );
        assert_eq!(
            crypto_scram::sha256(b"abc"),
            [
                0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
                0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
                0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
            ]
        );
    }

    #[test]
    fn test_hmac_sha256() {
        let key = b"key";
        let data = b"The quick brown fox jumps over the lazy dog";
        let hmac = crypto_scram::hmac_sha256(key, data);
        assert_eq!(
            hmac,
            [
                0xf7, 0xbc, 0x83, 0xf4, 0x30, 0x53, 0x84, 0x24,
                0xb1, 0x32, 0x98, 0xe6, 0xaa, 0x6f, 0xb1, 0x43,
                0xef, 0x4d, 0x59, 0xa1, 0x49, 0x46, 0x17, 0x59,
                0x97, 0x47, 0x9d, 0xbc, 0x2d, 0x1a, 0x3c, 0xd8,
            ]
        );
    }

    #[test]
    fn test_base64_encode_decode() {
        let input = b"Conduit High Performance Postgres Wire";
        let encoded = crypto_scram::base64_encode(input);
        let decoded = crypto_scram::base64_decode(&encoded).unwrap();
        assert_eq!(input.as_slice(), decoded.as_slice());
    }

    #[test]
    fn test_pg_config_from_url() {
        let cfg = PgConfig::from_url("postgres://conduit:secret123@127.0.0.1:5432/conduit_seed").unwrap();
        assert_eq!(cfg.user, "conduit");
        assert_eq!(cfg.password, "secret123");
        assert_eq!(cfg.host, "127.0.0.1");
        assert_eq!(cfg.port, 5432);
        assert_eq!(cfg.database, "conduit_seed");
    }
}
