//! Dedicated high-performance PostgreSQL v3 wire-protocol client.

use std::io::{Read, Write};
use std::net::TcpStream;
use super::proto::ScramClient;

pub struct PgConnectionInfo {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    pub database: String,
}

impl PgConnectionInfo {
    pub fn parse(url: &str) -> Result<Self, String> {
        let stripped = url.strip_prefix("postgres://").or_else(|| url.strip_prefix("postgresql://"))
            .ok_or("Invalid postgres URL scheme")?;

        let (auth, rest) = stripped.split_once('@').ok_or("Missing @ in postgres URL")?;
        let (user, password) = auth.split_once(':').unwrap_or((auth, ""));

        let (host_port, database) = rest.split_once('/').ok_or("Missing database name in postgres URL")?;
        let database = database.split('?').next().unwrap_or(database).to_string();

        let (host, port_str) = host_port.split_once(':').unwrap_or((host_port, "5432"));
        let port: u16 = port_str.parse().unwrap_or(5432);

        Ok(PgConnectionInfo {
            host: host.to_string(),
            port,
            user: user.to_string(),
            password: password.to_string(),
            database,
        })
    }
}

pub struct PgClient {
    stream: TcpStream,
    read_buf: Vec<u8>,
    write_buf: Vec<u8>,
}

pub struct PgRow {
    pub columns: Vec<Option<Vec<u8>>>,
}

impl PgClient {
    pub fn connect(info: &PgConnectionInfo) -> Result<Self, String> {
        let addr = format!("{}:{}", info.host, info.port);
        let stream = TcpStream::connect(&addr).map_err(|e| format!("Connect failed to {}: {}", addr, e))?;
        stream.set_nodelay(true).ok();

        let mut client = PgClient {
            stream,
            read_buf: Vec::with_capacity(65536),
            write_buf: Vec::with_capacity(65536),
        };

        client.perform_startup(info)?;
        client.set_session_optimizations()?;

        Ok(client)
    }

    fn perform_startup(&mut self, info: &PgConnectionInfo) -> Result<(), String> {
        // StartupMessage
        let mut msg = Vec::new();
        msg.extend_from_slice(&(196608i32).to_be_bytes()); // Protocol v3.0
        msg.extend_from_slice(b"user\0");
        msg.extend_from_slice(info.user.as_bytes());
        msg.push(0);
        msg.extend_from_slice(b"database\0");
        msg.extend_from_slice(info.database.as_bytes());
        msg.push(0);
        msg.extend_from_slice(b"client_encoding\0UTF8\0");
        msg.push(0);

        let total_len = (msg.len() + 4) as i32;
        self.stream.write_all(&total_len.to_be_bytes()).map_err(|e| e.to_string())?;
        self.stream.write_all(&msg).map_err(|e| e.to_string())?;

        let mut scram = ScramClient::new(&info.user, &info.password);

        loop {
            let (msg_type, payload) = self.read_message()?;
            match msg_type {
                b'R' => {
                    let auth_type = i32::from_be_bytes(payload[0..4].try_into().unwrap());
                    match auth_type {
                        0 => {} // Auth OK
                        3 => {
                            // Cleartext password
                            let mut resp = Vec::new();
                            resp.push(b'p');
                            let plen = (info.password.len() + 5) as i32;
                            resp.extend_from_slice(&plen.to_be_bytes());
                            resp.extend_from_slice(info.password.as_bytes());
                            resp.push(0);
                            self.stream.write_all(&resp).map_err(|e| e.to_string())?;
                        }
                        10 => {
                            // SASL SCRAM-SHA-256
                            let client_first = scram.client_first_message();
                            let mut resp = Vec::new();
                            resp.push(b'p');
                            let body_len = 4 + 15 + 4 + client_first.len();
                            resp.extend_from_slice(&(body_len as i32).to_be_bytes());
                            resp.extend_from_slice(b"SCRAM-SHA-256\0");
                            resp.extend_from_slice(&(client_first.len() as i32).to_be_bytes());
                            resp.extend_from_slice(client_first.as_bytes());
                            self.stream.write_all(&resp).map_err(|e| e.to_string())?;
                        }
                        11 => {
                            // SASL Continue
                            let server_first = std::str::from_utf8(&payload[4..]).map_err(|e| e.to_string())?;
                            let client_final = scram.process_server_first(server_first).map_err(|_| "SCRAM error")?;
                            let mut resp = Vec::new();
                            resp.push(b'p');
                            let body_len = 4 + client_final.len();
                            resp.extend_from_slice(&(body_len as i32).to_be_bytes());
                            resp.extend_from_slice(client_final.as_bytes());
                            self.stream.write_all(&resp).map_err(|e| e.to_string())?;
                        }
                        12 => {
                            // SASL Final
                            let server_final = std::str::from_utf8(&payload[4..]).map_err(|e| e.to_string())?;
                            scram.verify_server_final(server_final).map_err(|_| "SCRAM final verify error")?;
                        }
                        other => return Err(format!("Unsupported auth type: {}", other)),
                    }
                }
                b'K' | b'S' => {} // BackendKeyData, ParameterStatus
                b'Z' => break,   // ReadyForQuery
                b'E' => return Err(format!("Backend error during startup: {:?}", String::from_utf8_lossy(&payload))),
                _ => {}
            }
        }
        Ok(())
    }

    fn set_session_optimizations(&mut self) -> Result<(), String> {
        self.simple_query("SET plan_cache_mode = force_generic_plan; SET jit = off; SET max_parallel_workers_per_gather = 0; SET enable_seqscan = off; SET synchronous_commit = on;")
    }

    pub fn simple_query(&mut self, sql: &str) -> Result<(), String> {
        let mut msg = Vec::new();
        msg.push(b'Q');
        let len = (sql.len() + 5) as i32;
        msg.extend_from_slice(&len.to_be_bytes());
        msg.extend_from_slice(sql.as_bytes());
        msg.push(0);

        self.stream.write_all(&msg).map_err(|e| e.to_string())?;

        loop {
            let (mtype, payload) = self.read_message()?;
            match mtype {
                b'Z' => break,
                b'E' => return Err(format!("Query failed: {:?}", String::from_utf8_lossy(&payload))),
                _ => {}
            }
        }
        Ok(())
    }

    pub fn prepare(&mut self, name: &str, query: &str, oids: &[i32]) -> Result<(), String> {
        self.write_buf.clear();

        // 'P' Parse
        self.write_buf.push(b'P');
        let parse_len_pos = self.write_buf.len();
        self.write_buf.extend_from_slice(&[0; 4]);
        self.write_buf.extend_from_slice(name.as_bytes());
        self.write_buf.push(0);
        self.write_buf.extend_from_slice(query.as_bytes());
        self.write_buf.push(0);
        self.write_buf.extend_from_slice(&(oids.len() as i16).to_be_bytes());
        for &oid in oids {
            self.write_buf.extend_from_slice(&oid.to_be_bytes());
        }
        let parse_len = (self.write_buf.len() - parse_len_pos) as i32;
        self.write_buf[parse_len_pos..parse_len_pos + 4].copy_from_slice(&parse_len.to_be_bytes());

        // 'S' Sync
        self.write_buf.push(b'S');
        self.write_buf.extend_from_slice(&(4i32).to_be_bytes());

        self.stream.write_all(&self.write_buf).map_err(|e| e.to_string())?;

        loop {
            let (mtype, payload) = self.read_message()?;
            match mtype {
                b'1' => {} // ParseComplete
                b'Z' => break,
                b'E' => return Err(format!("Prepare error for {}: {:?}", name, String::from_utf8_lossy(&payload))),
                _ => {}
            }
        }
        Ok(())
    }

    /// Executes a prepared query with binary parameters, returning row results.
    pub fn execute_prepared(&mut self, stmt_name: &str, params: &[&[u8]]) -> Result<Vec<PgRow>, String> {
        self.write_buf.clear();

        // 'B' Bind
        self.write_buf.push(b'B');
        let bind_len_pos = self.write_buf.len();
        self.write_buf.extend_from_slice(&[0; 4]);
        self.write_buf.push(0); // empty portal name
        self.write_buf.extend_from_slice(stmt_name.as_bytes());
        self.write_buf.push(0);

        // Parameter formats: all binary (1)
        self.write_buf.extend_from_slice(&(1i16).to_be_bytes());
        self.write_buf.extend_from_slice(&(1i16).to_be_bytes());

        // Parameter values
        self.write_buf.extend_from_slice(&(params.len() as i16).to_be_bytes());
        for p in params {
            self.write_buf.extend_from_slice(&(p.len() as i32).to_be_bytes());
            self.write_buf.extend_from_slice(p);
        }

        // Result formats: binary (1)
        self.write_buf.extend_from_slice(&(1i16).to_be_bytes());
        self.write_buf.extend_from_slice(&(1i16).to_be_bytes());

        let bind_len = (self.write_buf.len() - bind_len_pos) as i32;
        self.write_buf[bind_len_pos..bind_len_pos + 4].copy_from_slice(&bind_len.to_be_bytes());

        // 'E' Execute
        self.write_buf.push(b'E');
        self.write_buf.extend_from_slice(&(9i32).to_be_bytes());
        self.write_buf.push(0); // empty portal
        self.write_buf.extend_from_slice(&(0i32).to_be_bytes()); // max_rows = 0 (all)

        // 'S' Sync
        self.write_buf.push(b'S');
        self.write_buf.extend_from_slice(&(4i32).to_be_bytes());

        self.stream.write_all(&self.write_buf).map_err(|e| e.to_string())?;

        let mut rows = Vec::new();
        loop {
            let (mtype, payload) = self.read_message()?;
            match mtype {
                b'2' => {} // BindComplete
                b'D' => {
                    // DataRow
                    if payload.len() >= 2 {
                        let num_cols = i16::from_be_bytes(payload[0..2].try_into().unwrap()) as usize;
                        let mut offset = 2;
                        let mut cols = Vec::with_capacity(num_cols);
                        for _ in 0..num_cols {
                            if offset + 4 <= payload.len() {
                                let col_len = i32::from_be_bytes(payload[offset..offset + 4].try_into().unwrap());
                                offset += 4;
                                if col_len < 0 {
                                    cols.push(None);
                                } else {
                                    let ulen = col_len as usize;
                                    let end = offset + ulen;
                                    cols.push(Some(payload[offset..end].to_vec()));
                                    offset = end;
                                }
                            }
                        }
                        rows.push(PgRow { columns: cols });
                    }
                }
                b'C' => {} // CommandComplete
                b'Z' => break,
                b'E' => return Err(format!("Execution error: {:?}", String::from_utf8_lossy(&payload))),
                _ => {}
            }
        }
        Ok(rows)
    }

    fn read_message(&mut self) -> Result<(u8, Vec<u8>), String> {
        let mut header = [0u8; 5];
        self.stream.read_exact(&mut header).map_err(|e| e.to_string())?;
        let msg_type = header[0];
        let len = i32::from_be_bytes(header[1..5].try_into().unwrap()) as usize;
        let payload_len = len - 4;

        let mut payload = vec![0u8; payload_len];
        if payload_len > 0 {
            self.stream.read_exact(&mut payload).map_err(|e| e.to_string())?;
        }
        Ok((msg_type, payload))
    }
}
