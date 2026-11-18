#![allow(dead_code)]

use std::ffi::c_int;
use std::io;
use std::net::SocketAddrV4;

use crate::jwt::{b64std_decode, b64std_encode, fill_scram_nonce, hmac_sha256, pbkdf2_hmac_sha256, sha256};
use crate::sys::{
    AF_INET, EINTR, IPPROTO_TCP, MSG_NOSIGNAL, SOCK_STREAM, close, connect, recv, resolve_ipv4,
    send, set_nonblocking, set_tcp_nodelay, sockaddr_in, socket,
};

#[derive(Clone, Debug)]
pub struct DbUrl {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub dbname: String,
}

impl DbUrl {
    pub fn parse(url: &str) -> Self {
        let rest = url
            .strip_prefix("postgres://")
            .or_else(|| url.strip_prefix("postgresql://"))
            .unwrap_or(url);
        let (auth_host, dbname) = match rest.find('/') {
            Some(slash) => {
                let db = &rest[slash + 1..];
                let db = db.split('?').next().unwrap_or(db);
                (&rest[..slash], db)
            }
            None => (rest, "postgres"),
        };
        let (user_pass, host_port) = match auth_host.rfind('@') {
            Some(at) => (&auth_host[..at], &auth_host[at + 1..]),
            None => ("postgres:postgres", auth_host),
        };
        let (user, password) = match user_pass.find(':') {
            Some(colon) => (&user_pass[..colon], &user_pass[colon + 1..]),
            None => (user_pass, ""),
        };
        let (host, port) = match host_port.find(':') {
            Some(colon) => (
                &host_port[..colon],
                host_port[colon + 1..].parse::<u16>().unwrap_or(5432),
            ),
            None => (host_port, 5432),
        };
        Self {
            host: if host.is_empty() {
                "127.0.0.1".to_string()
            } else {
                host.to_string()
            },
            port,
            user: user.to_string(),
            password: password.to_string(),
            dbname: dbname.to_string(),
        }
    }
}

#[inline]
pub fn be32(p: &[u8]) -> i32 {
    i32::from_be_bytes([p[0], p[1], p[2], p[3]])
}

#[inline]
pub fn be_int(p: &[u8]) -> i64 {
    match p.len() {
        2 => i16::from_be_bytes([p[0], p[1]]) as i64,
        4 => i32::from_be_bytes([p[0], p[1], p[2], p[3]]) as i64,
        8 => i64::from_be_bytes([p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]]),
        _ => {
            let mut v = 0u64;
            for &b in p {
                v = (v << 8) | (b as u64);
            }
            v as i64
        }
    }
}

#[inline]
pub fn put32(buf: &mut Vec<u8>, v: i32) {
    buf.extend_from_slice(&v.to_be_bytes());
}

#[inline]
pub fn put64(buf: &mut Vec<u8>, v: i64) {
    buf.extend_from_slice(&v.to_be_bytes());
}

#[inline]
pub fn length_slot(buf: &mut Vec<u8>) -> usize {
    let at = buf.len();
    buf.extend_from_slice(&[0, 0, 0, 0]);
    at
}

#[inline]
pub fn set32(buf: &mut [u8], at: usize, v: i32) {
    buf[at..at + 4].copy_from_slice(&v.to_be_bytes());
}

pub fn statement_name(i: usize) -> [u8; 4] {
    [
        b's',
        b'0' + ((i / 10) as u8),
        b'0' + ((i % 10) as u8),
        0,
    ]
}

fn send_all_blocking(fd: c_int, mut data: &[u8]) -> io::Result<()> {
    while !data.is_empty() {
        let w = unsafe { send(fd, data.as_ptr().cast(), data.len(), MSG_NOSIGNAL) };
        if w < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(EINTR) {
                continue;
            }
            return Err(err);
        }
        if w == 0 {
            return Err(io::Error::new(io::ErrorKind::WriteZero, "pg send 0"));
        }
        data = &data[w as usize..];
    }
    Ok(())
}

fn recv_exact_blocking(fd: c_int, mut buf: &mut [u8]) -> io::Result<()> {
    while !buf.is_empty() {
        let r = unsafe { recv(fd, buf.as_mut_ptr().cast(), buf.len(), 0) };
        if r < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(EINTR) {
                continue;
            }
            return Err(err);
        }
        if r == 0 {
            return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "pg eof"));
        }
        buf = &mut buf[r as usize..];
    }
    Ok(())
}

fn read_pg_message(fd: c_int, payload: &mut Vec<u8>) -> io::Result<u8> {
    let mut hdr = [0u8; 5];
    recv_exact_blocking(fd, &mut hdr)?;
    let kind = hdr[0];
    let len = u32::from_be_bytes([hdr[1], hdr[2], hdr[3], hdr[4]]) as usize;
    if len < 4 {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "bad pg msg len"));
    }
    payload.resize(len - 4, 0);
    if len > 4 {
        recv_exact_blocking(fd, payload)?;
    }
    Ok(kind)
}

fn parse_scram_attr<'a>(msg: &'a str, key: char) -> Option<&'a str> {
    for part in msg.split(',') {
        let bytes = part.as_bytes();
        if bytes.len() >= 2 && bytes[0] == (key as u8) && bytes[1] == b'=' {
            return Some(&part[2..]);
        }
    }
    None
}

/// Connects to PostgreSQL over TCP, completes v3 Startup (Ok / Cleartext / SCRAM-SHA-256),
/// prepares all `statements` (`s00`, `s01`, ...) in a single pipelined round-trip, and sets
/// the socket to non-blocking mode.
pub fn pg_connect_and_prepare(
    db: &DbUrl,
    options: &str,
    statements: &[&str],
) -> io::Result<c_int> {
    let ip = resolve_ipv4(&db.host, db.port);
    let addr = SocketAddrV4::new(ip, db.port);
    let fd = unsafe { socket(AF_INET, SOCK_STREAM, IPPROTO_TCP) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    set_tcp_nodelay(fd);

    let sin = sockaddr_in {
        #[cfg(not(target_os = "linux"))]
        sin_len: std::mem::size_of::<sockaddr_in>() as u8,
        sin_family: AF_INET as _,
        sin_port: addr.port().to_be(),
        sin_addr: u32::from_ne_bytes(addr.ip().octets()),
        sin_zero: [0; 8],
    };

    if unsafe {
        connect(
            fd,
            (&sin as *const sockaddr_in).cast(),
            std::mem::size_of::<sockaddr_in>() as u32,
        )
    } < 0
    {
        let err = io::Error::last_os_error();
        unsafe { close(fd) };
        return Err(err);
    }

    let res = (|| -> io::Result<()> {
        let mut startup = Vec::with_capacity(256);
        let at = length_slot(&mut startup);
        put32(&mut startup, 196608); // protocol 3.0
        for (k, v) in [
            ("user", db.user.as_str()),
            ("database", db.dbname.as_str()),
            ("TimeZone", "UTC"),
            ("client_encoding", "UTF8"),
            ("options", options),
        ] {
            if !v.is_empty() {
                startup.extend_from_slice(k.as_bytes());
                startup.push(0);
                startup.extend_from_slice(v.as_bytes());
                startup.push(0);
            }
        }
        startup.push(0);
        let total = startup.len() as i32;
        set32(&mut startup, at, total);
        send_all_blocking(fd, &startup)?;

        let mut payload = Vec::with_capacity(256);
        let mut client_nonce = String::new();
        let mut client_first_bare = String::new();

        loop {
            let kind = read_pg_message(fd, &mut payload)?;
            match kind {
                b'R' => {
                    if payload.len() < 4 {
                        return Err(io::Error::new(io::ErrorKind::InvalidData, "short R"));
                    }
                    let auth_code = be32(&payload[..4]);
                    match auth_code {
                        0 => {} // AuthenticationOk
                        3 => {
                            // AuthenticationCleartextPassword
                            let mut msg = Vec::with_capacity(6 + db.password.len());
                            msg.push(b'p');
                            put32(&mut msg, (4 + db.password.len() + 1) as i32);
                            msg.extend_from_slice(db.password.as_bytes());
                            msg.push(0);
                            send_all_blocking(fd, &msg)?;
                        }
                        10 => {
                            // AuthenticationSASL (SCRAM-SHA-256)
                            client_nonce = fill_scram_nonce();
                            client_first_bare = format!("n=,r={client_nonce}");
                            let client_first = format!("n,,{client_first_bare}");
                            let mech = b"SCRAM-SHA-256\0";
                            let mut msg = Vec::with_capacity(64 + client_first.len());
                            msg.push(b'p');
                            let at = length_slot(&mut msg);
                            msg.extend_from_slice(mech);
                            put32(&mut msg, client_first.len() as i32);
                            msg.extend_from_slice(client_first.as_bytes());
                            let len = (msg.len() - at) as i32;
                            set32(&mut msg, at, len);
                            send_all_blocking(fd, &msg)?;
                        }
                        11 => {
                            // AuthenticationSASLContinue
                            let server_first = std::str::from_utf8(&payload[4..])
                                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "scram utf8"))?;
                            let r_nonce = parse_scram_attr(server_first, 'r')
                                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "scram r"))?;
                            let s_b64 = parse_scram_attr(server_first, 's')
                                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "scram s"))?;
                            let iter_str = parse_scram_attr(server_first, 'i')
                                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "scram i"))?;
                            let iterations: u32 = iter_str
                                .parse()
                                .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "scram iter"))?;
                            if !r_nonce.starts_with(&client_nonce) {
                                return Err(io::Error::new(
                                    io::ErrorKind::PermissionDenied,
                                    "scram nonce mismatch",
                                ));
                            }
                            let salt = b64std_decode(s_b64.as_bytes())
                                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "scram salt"))?;

                            let salted_pw =
                                pbkdf2_hmac_sha256(db.password.as_bytes(), &salt, iterations);
                            let client_key = hmac_sha256(&salted_pw, b"Client Key");
                            let stored_key = sha256(&client_key);
                            let client_final_no_proof = format!("c=biws,r={r_nonce}");
                            let auth_msg = format!(
                                "{client_first_bare},{server_first},{client_final_no_proof}"
                            );
                            let client_sig = hmac_sha256(&stored_key, auth_msg.as_bytes());
                            let mut proof = [0u8; 32];
                            for i in 0..32 {
                                proof[i] = client_key[i] ^ client_sig[i];
                            }
                            let proof_b64 = b64std_encode(&proof);
                            let client_final = format!("{client_final_no_proof},p={proof_b64}");

                            let mut msg = Vec::with_capacity(8 + client_final.len());
                            msg.push(b'p');
                            put32(&mut msg, (4 + client_final.len()) as i32);
                            msg.extend_from_slice(client_final.as_bytes());
                            send_all_blocking(fd, &msg)?;
                        }
                        12 => {} // AuthenticationSASLFinal
                        _ => {
                            return Err(io::Error::new(
                                io::ErrorKind::PermissionDenied,
                                "unsupported pg auth",
                            ));
                        }
                    }
                }
                b'S' | b'K' | b'N' => {}
                b'Z' => break,
                b'E' => {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "pg startup error",
                    ));
                }
                _ => {}
            }
        }

        // Pipeline Parse messages for all statements followed by one Sync
        if !statements.is_empty() {
            let mut batch = Vec::with_capacity(statements.len() * 256 + 16);
            for (idx, sql) in statements.iter().enumerate() {
                batch.push(b'P');
                let at = length_slot(&mut batch);
                let name = statement_name(idx);
                batch.extend_from_slice(&name);
                batch.extend_from_slice(sql.as_bytes());
                batch.push(0);
                batch.extend_from_slice(&[0, 0]); // 0 param type OIDs specified upfront
                let len = (batch.len() - at) as i32;
                set32(&mut batch, at, len);
            }
            batch.extend_from_slice(b"S\x00\x00\x00\x04");
            send_all_blocking(fd, &batch)?;

            loop {
                let kind = read_pg_message(fd, &mut payload)?;
                match kind {
                    b'1' | b'N' => {}
                    b'Z' => break,
                    b'E' => {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidInput,
                            "pg prepare error",
                        ));
                    }
                    _ => {}
                }
            }
        }
        Ok(())
    })();

    if let Err(e) = res {
        unsafe { close(fd) };
        return Err(e);
    }

    set_nonblocking(fd);
    Ok(fd)
}

/// Checks if a PostgreSQL ErrorResponse (`'E'`) payload has SQLSTATE `code` (e.g. `b"23505"`).
pub fn sqlstate_is(e: &[u8], code: &[u8]) -> bool {
    let mut i = 0usize;
    while i < e.len() && e[i] != 0 {
        let field = e[i];
        let mut j = i + 1;
        while j < e.len() && e[j] != 0 {
            j += 1;
        }
        if field == b'C' {
            return &e[i + 1..j] == code;
        }
        i = j + 1;
    }
    false
}

/// Cursor over a PostgreSQL binary `DataRow` payload (starting at the 2-byte column count).
#[derive(Clone, Copy)]
pub struct Row<'a> {
    pub p: &'a [u8],
    pub i: usize,
}

impl<'a> Row<'a> {
    #[inline]
    pub fn open(row: &'a [u8], batch_rows: bool) -> Self {
        Self {
            p: row,
            i: if batch_rows { 2 + 4 + 8 } else { 2 },
        }
    }

    /// Returns `Some(col_bytes)` or `None` if the column is SQL `NULL` (`len < 0`).
    #[inline]
    pub fn col(&mut self) -> Option<&'a [u8]> {
        if self.i + 4 > self.p.len() {
            return None;
        }
        let n = be32(&self.p[self.i..self.i + 4]);
        self.i += 4;
        if n < 0 {
            None
        } else {
            let nu = n as usize;
            let s = &self.p[self.i..self.i + nu];
            self.i += nu;
            Some(s)
        }
    }

    #[inline]
    pub fn skip(&mut self) {
        let _ = self.col();
    }

    #[inline]
    pub fn int(&mut self) -> i64 {
        match self.col() {
            Some(s) if !s.is_empty() => be_int(s),
            _ => 0,
        }
    }

    #[inline]
    pub fn is_null(&self) -> bool {
        self.i + 4 > self.p.len() || be32(&self.p[self.i..self.i + 4]) < 0
    }
}

/// Zero-copy view over a binary PostgreSQL `int8[]` array (1-dimensional, non-NULL elements: 12 bytes per element).
#[derive(Clone, Copy)]
pub struct Int8s<'a> {
    pub p: &'a [u8],
    pub count: usize,
}

impl<'a> Int8s<'a> {
    #[inline]
    pub fn from_col(col: Option<&'a [u8]>) -> Self {
        let Some(p) = col else {
            return Self { p: &[], count: 0 };
        };
        if p.len() < 20 || be32(&p[0..4]) != 1 {
            return Self { p: &[], count: 0 };
        }
        let count = be32(&p[12..16]).max(0) as usize;
        Self {
            p: &p[20..],
            count,
        }
    }

    #[inline]
    pub fn at(&self, idx: usize) -> i64 {
        let off = idx * 12 + 4;
        be_int(&self.p[off..off + 8])
    }

    #[inline]
    pub fn has(&self, v: i64) -> bool {
        for i in 0..self.count {
            if self.at(i) == v {
                return true;
            }
        }
        false
    }
}

