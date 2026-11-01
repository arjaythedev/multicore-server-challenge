//! [`Connection`]: one blocking Postgres connection with pipelining.
//!
//! Usage on a lane thread:
//!
//! ```text
//! let stmt = conn.prepare("by_id", "select title from articles where id = $1", &[INT8])?;
//! conn.push(&stmt, &[Param::Int8(7)])?;      // buffered, no I/O
//! conn.push(&stmt, &[Param::Int8(8)])?;
//! conn.flush_and_collect(&mut results)?;      // one write, one Sync, read until ReadyForQuery
//! ```
//!
//! # Failure model
//!
//! * A [`ServerError`](super::ServerError) for one statement is data: it sits in `Results`, the statements after it are
//!   `Skipped`, and the connection stays usable.
//! * An I/O or protocol error leaves the stream in an unknown position, so the connection is **poisoned**: every
//!   later call returns [`PgError::Poisoned`] and the owner must reconnect.
//!
//! Not handled on purpose: transactions beyond what the SQL itself does, cancellation, statement caching,
//! reconnecting, connection timeouts.

use std::net::TcpStream;

use super::codec::Param;
use super::config::Config;
use super::error::{PgError, ServerError};
use super::results::Results;
use super::startup;
use super::transport::{Flow, Transport};
use super::wire::{self, tag};

/// Longest accepted statement name (Postgres limits identifiers to 63 bytes).
const MAX_STMT_NAME: usize = 63;

/// Handle to a server-side prepared statement of one connection. Cheap to copy; usable only on the connection
/// that prepared it (another connection answers with "prepared statement does not exist").
#[derive(Clone, Copy)]
pub struct Stmt {
    name: [u8; MAX_STMT_NAME],
    len: u8,
}

impl Stmt {
    fn new(name: &str) -> Result<Self, PgError> {
        let bytes = name.as_bytes();
        if bytes.is_empty() || bytes.len() > MAX_STMT_NAME || bytes.contains(&0) {
            return Err(PgError::protocol(
                "statement name must be 1..=63 bytes without NUL",
            ));
        }
        let mut buf = [0u8; MAX_STMT_NAME];
        buf[..bytes.len()].copy_from_slice(bytes);
        Ok(Stmt {
            name: buf,
            len: bytes.len() as u8,
        })
    }

    pub fn name(&self) -> &str {
        // Constructed from a `&str` and cut at its original length, so this is always valid UTF-8.
        std::str::from_utf8(&self.name[..self.len as usize]).unwrap_or_default()
    }

    fn name_bytes(&self) -> &[u8] {
        &self.name[..self.len as usize]
    }
}

impl std::fmt::Debug for Stmt {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Stmt({})", self.name())
    }
}

pub struct Connection {
    transport: Transport,
    /// Statements pushed since the last flush.
    pending: usize,
    poisoned: bool,
}

impl Connection {
    /// Connects, authenticates and returns after the first ReadyForQuery. `startup_options` is passed as the
    /// `options` startup parameter (e.g. `-c jit=off`); pass `""` for none.
    pub fn connect(cfg: &Config, startup_options: &str) -> Result<Connection, PgError> {
        let stream = TcpStream::connect((cfg.host.as_str(), cfg.port))?;
        // Pipelines are written in one call; Nagle would only delay the small final segment.
        stream.set_nodelay(true)?;
        let mut transport = Transport::new(stream);
        startup::handshake(&mut transport, cfg, startup_options)?;
        Ok(Connection {
            transport,
            pending: 0,
            poisoned: false,
        })
    }

    pub fn is_poisoned(&self) -> bool {
        self.poisoned
    }

    /// Statements pushed and not yet flushed.
    pub fn pending(&self) -> usize {
        self.pending
    }

    /// Parses `sql` as a named server-side statement (one round trip). `param_oids` pins the parameter types.
    pub fn prepare(&mut self, name: &str, sql: &str, param_oids: &[u32]) -> Result<Stmt, PgError> {
        let stmt = Stmt::new(name)?;
        self.require_idle()?;
        self.guarded(|c| {
            wire::encode_parse(&mut c.transport.out, stmt.name_bytes(), sql, param_oids)?;
            wire::encode_sync(&mut c.transport.out);
            c.round_trip()
        })
        .map(|()| stmt)
    }

    /// Runs `sql` through the simple query protocol and ignores any rows (setup statements, `SET`, DDL in tests).
    pub fn query_simple(&mut self, sql: &str) -> Result<(), PgError> {
        self.require_idle()?;
        self.guarded(|c| {
            wire::encode_query(&mut c.transport.out, sql)?;
            c.round_trip()
        })
    }

    /// Appends Bind + Execute for `stmt` to the outgoing buffer. No I/O happens until `flush_and_collect`.
    pub fn push(&mut self, stmt: &Stmt, params: &[Param<'_>]) -> Result<(), PgError> {
        self.check_usable()?;
        let mark = self.transport.out.len();
        match wire::encode_bind_execute(&mut self.transport.out, stmt.name_bytes(), params) {
            Ok(()) => {
                self.pending += 1;
                Ok(())
            }
            Err(e) => {
                // A half-written message would desynchronise the stream; drop it. The connection stays usable.
                self.transport.out.truncate(mark);
                Err(e)
            }
        }
    }

    /// Sends everything pushed so far plus a Sync with one write and reads until ReadyForQuery.
    ///
    /// `Ok(())` means the exchange completed; individual statements may still carry a server error or be skipped
    /// (see [`Results`]). `Err(Server(..))` is returned only for an error that belongs to no statement (e.g. the
    /// implicit commit at Sync failing); the connection stays usable then. Any other `Err` poisons the connection.
    pub fn flush_and_collect(&mut self, out: &mut Results) -> Result<(), PgError> {
        self.check_usable()?;
        let expected = std::mem::take(&mut self.pending);
        out.begin(expected);
        if expected == 0 {
            return Ok(());
        }
        self.guarded(|c| {
            wire::encode_sync(&mut c.transport.out);
            c.transport
                .exchange(|msg_tag, payload| out.on_message(msg_tag, payload))
        })?;
        match out.trailing_error.take() {
            Some(e) => Err(PgError::Server(e)),
            None => Ok(()),
        }
    }

    /// Drives a request already in `out` whose replies are only checked for errors (prepare, simple query).
    fn round_trip(&mut self) -> Result<(), PgError> {
        let mut first_error: Option<ServerError> = None;
        self.transport.exchange(|msg_tag, payload| {
            match msg_tag {
                tag::ERROR if first_error.is_none() => {
                    first_error = Some(wire::parse_error_response(payload))
                }
                tag::READY_FOR_QUERY => return Ok(Flow::Done),
                _ => {}
            }
            Ok(Flow::Continue)
        })?;
        first_error.map_or(Ok(()), |e| Err(PgError::Server(e)))
    }

    fn check_usable(&self) -> Result<(), PgError> {
        if self.poisoned {
            Err(PgError::Poisoned)
        } else {
            Ok(())
        }
    }

    /// Prepare and simple queries share the output buffer with the pipeline, so they may not run in the middle of one.
    fn require_idle(&self) -> Result<(), PgError> {
        self.check_usable()?;
        if self.pending != 0 {
            return Err(PgError::protocol("statements are pushed but not flushed"));
        }
        Ok(())
    }

    /// Runs `f` and poisons the connection if it fails in a way that loses stream synchronisation.
    fn guarded<T>(
        &mut self,
        f: impl FnOnce(&mut Self) -> Result<T, PgError>,
    ) -> Result<T, PgError> {
        let result = f(self);
        if let Err(e) = &result
            && e.breaks_connection()
        {
            self.poisoned = true;
        }
        result
    }
}
