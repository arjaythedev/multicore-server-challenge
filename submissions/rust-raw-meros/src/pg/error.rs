//! Error types of the Postgres client.
//!
//! [`PgError`] is what every fallible call returns. Only `Io`, `Protocol` and `Auth` raised while talking to the
//! server poison a [`super::Connection`]; a [`ServerError`] is an ordinary answer and leaves it usable.

use std::fmt;
use std::io;

/// SQLSTATE of a unique constraint violation.
pub const SQLSTATE_UNIQUE_VIOLATION: [u8; 5] = *b"23505";

/// Fallback SQLSTATE ("internal error") for an ErrorResponse that carries none.
const SQLSTATE_UNKNOWN: [u8; 5] = *b"XX000";

/// An ErrorResponse sent by the server: the 5-byte SQLSTATE and the human readable message.
///
/// Other fields (detail, hint, position, constraint name ...) are dropped on purpose; nothing in this server
/// reads them.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerError {
    pub sqlstate: [u8; 5],
    pub message: String,
}

impl ServerError {
    /// SQLSTATE as text (`"23505"`); `"?????"` if the server sent non-UTF-8 bytes there.
    pub fn sqlstate_str(&self) -> &str {
        std::str::from_utf8(&self.sqlstate).unwrap_or("?????")
    }

    pub fn is_unique_violation(&self) -> bool {
        self.sqlstate == SQLSTATE_UNIQUE_VIOLATION
    }

    /// Builds the error from the `C` (code) and `M` (message) fields; a missing code becomes `XX000`.
    pub(super) fn from_fields(code: Option<&[u8]>, message: Option<&[u8]>) -> Self {
        let sqlstate = match code {
            Some(c) => <[u8; 5]>::try_from(c).unwrap_or(SQLSTATE_UNKNOWN),
            None => SQLSTATE_UNKNOWN,
        };
        let message = message
            .map(|m| String::from_utf8_lossy(m).into_owned())
            .unwrap_or_default();
        ServerError { sqlstate, message }
    }
}

impl fmt::Display for ServerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{} {}", self.sqlstate_str(), self.message)
    }
}

#[derive(Debug)]
pub enum PgError {
    /// Socket failure (connect, read, write, unexpected EOF).
    Io(io::Error),
    /// The peer (or the caller) broke the wire protocol or a value could not be decoded.
    Protocol(String),
    /// The server answered with an ErrorResponse.
    Server(ServerError),
    /// Authentication failed or uses an unsupported method.
    Auth(String),
    /// The connection saw an I/O or protocol error earlier and must be replaced.
    Poisoned,
}

impl PgError {
    pub(super) fn protocol(msg: impl Into<String>) -> Self {
        PgError::Protocol(msg.into())
    }

    /// True if the connection can no longer be trusted to be in sync with the server.
    pub(super) fn breaks_connection(&self) -> bool {
        !matches!(self, PgError::Server(_))
    }
}

impl fmt::Display for PgError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            PgError::Io(e) => write!(f, "postgres i/o error: {e}"),
            PgError::Protocol(m) => write!(f, "postgres protocol error: {m}"),
            PgError::Server(e) => write!(f, "postgres error {e}"),
            PgError::Auth(m) => write!(f, "postgres authentication failed: {m}"),
            PgError::Poisoned => f.write_str("postgres connection is poisoned"),
        }
    }
}

impl std::error::Error for PgError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            PgError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for PgError {
    fn from(e: io::Error) -> Self {
        PgError::Io(e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_error_display_and_helpers() {
        let e = ServerError::from_fields(Some(b"23505"), Some(b"duplicate key"));
        assert!(e.is_unique_violation());
        assert_eq!(e.to_string(), "23505 duplicate key");
    }

    #[test]
    fn missing_or_odd_sqlstate_falls_back() {
        assert_eq!(ServerError::from_fields(None, None).sqlstate, *b"XX000");
        assert_eq!(
            ServerError::from_fields(Some(b"12"), None).sqlstate,
            *b"XX000"
        );
    }

    #[test]
    fn only_server_errors_keep_the_connection() {
        assert!(!PgError::Server(ServerError::from_fields(None, None)).breaks_connection());
        assert!(PgError::protocol("x").breaks_connection());
        assert!(PgError::Auth("x".into()).breaks_connection());
    }
}
