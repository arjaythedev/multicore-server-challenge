//! Postgres v3 wire format: message tags, frontend message encoders and a few backend payload parsers.
//!
//! Every encoder appends to a caller-owned `Vec<u8>` and patches the length field afterwards, so building a
//! message never allocates a temporary. Backend messages are only parsed here when they are small and rare
//! (ErrorResponse, authentication); DataRow parsing lives in `collect.rs` because it is the hot path.
//!
//! Not handled: COPY, function call, SSL/GSS negotiation, protocol versions other than 3.0.

use super::codec::{self, Param};
use super::error::{PgError, ServerError};

/// Frontend and backend message tags (single ASCII byte on the wire).
pub(super) mod tag {
    // Frontend.
    pub const PARSE: u8 = b'P';
    pub const BIND: u8 = b'B';
    pub const EXECUTE: u8 = b'E';
    pub const SYNC: u8 = b'S';
    pub const QUERY: u8 = b'Q';
    pub const PASSWORD: u8 = b'p';
    // Backend.
    pub const AUTH: u8 = b'R';
    pub const ERROR: u8 = b'E';
    pub const NOTICE: u8 = b'N';
    pub const PARAMETER_STATUS: u8 = b'S';
    pub const BACKEND_KEY_DATA: u8 = b'K';
    pub const READY_FOR_QUERY: u8 = b'Z';
    pub const PARSE_COMPLETE: u8 = b'1';
    pub const BIND_COMPLETE: u8 = b'2';
    pub const NO_DATA: u8 = b'n';
    pub const PARAMETER_DESCRIPTION: u8 = b't';
    pub const ROW_DESCRIPTION: u8 = b'T';
    pub const DATA_ROW: u8 = b'D';
    pub const COMMAND_COMPLETE: u8 = b'C';
    pub const EMPTY_QUERY: u8 = b'I';
}

/// Authentication request codes inside an `R` message.
pub(super) mod auth {
    pub const OK: i32 = 0;
    pub const CLEARTEXT_PASSWORD: i32 = 3;
    pub const SASL: i32 = 10;
    pub const SASL_CONTINUE: i32 = 11;
    pub const SASL_FINAL: i32 = 12;
}

/// Protocol version 3.0 as sent in the startup message.
const PROTOCOL_VERSION_3_0: i32 = 196_608;
/// Format code for binary values in Bind.
const FORMAT_BINARY: i16 = 1;
/// Bytes of the length field that follows a tag.
const LEN_FIELD: usize = 4;

/// Starts a tagged message. Returns the position of its length field for [`finish`].
pub(super) fn begin(out: &mut Vec<u8>, tag: u8) -> usize {
    out.push(tag);
    let len_pos = out.len();
    out.extend_from_slice(&[0; LEN_FIELD]);
    len_pos
}

/// Starts the untagged startup message.
fn begin_untagged(out: &mut Vec<u8>) -> usize {
    let len_pos = out.len();
    out.extend_from_slice(&[0; LEN_FIELD]);
    len_pos
}

/// Patches the length field (which counts itself and the body, not the tag).
pub(super) fn finish(out: &mut [u8], len_pos: usize) -> Result<(), PgError> {
    let len = i32::try_from(out.len() - len_pos)
        .map_err(|_| PgError::protocol("message larger than 2 GiB"))?;
    out[len_pos..len_pos + LEN_FIELD].copy_from_slice(&len.to_be_bytes());
    Ok(())
}

pub(super) fn put_i16(out: &mut Vec<u8>, v: i16) {
    out.extend_from_slice(&v.to_be_bytes());
}

pub(super) fn put_i32(out: &mut Vec<u8>, v: i32) {
    out.extend_from_slice(&v.to_be_bytes());
}

/// Appends a NUL-terminated string; a NUL inside `s` would corrupt the framing, so it is refused.
pub(super) fn put_cstr(out: &mut Vec<u8>, s: &[u8]) -> Result<(), PgError> {
    if s.contains(&0) {
        return Err(PgError::protocol("string contains a NUL byte"));
    }
    out.extend_from_slice(s);
    out.push(0);
    Ok(())
}

/// Startup message: protocol 3.0, `user`, `database`, UTF-8 client encoding and (if non-empty) `options`.
pub(super) fn encode_startup(
    out: &mut Vec<u8>,
    user: &str,
    database: &str,
    options: &str,
) -> Result<(), PgError> {
    let len_pos = begin_untagged(out);
    put_i32(out, PROTOCOL_VERSION_3_0);
    let mut pairs = vec![
        ("user", user),
        ("database", database),
        ("client_encoding", "UTF8"),
    ];
    if !options.is_empty() {
        pairs.push(("options", options));
    }
    for (key, value) in pairs {
        put_cstr(out, key.as_bytes())?;
        put_cstr(out, value.as_bytes())?;
    }
    out.push(0);
    finish(out, len_pos)
}

/// Cleartext `PasswordMessage`.
pub(super) fn encode_password(out: &mut Vec<u8>, password: &str) -> Result<(), PgError> {
    let len_pos = begin(out, tag::PASSWORD);
    put_cstr(out, password.as_bytes())?;
    finish(out, len_pos)
}

/// `SASLInitialResponse`: mechanism name plus the client-first message.
pub(super) fn encode_sasl_initial(
    out: &mut Vec<u8>,
    mechanism: &str,
    data: &[u8],
) -> Result<(), PgError> {
    let len_pos = begin(out, tag::PASSWORD);
    put_cstr(out, mechanism.as_bytes())?;
    put_i32(
        out,
        i32::try_from(data.len()).map_err(|_| PgError::protocol("SASL data too long"))?,
    );
    out.extend_from_slice(data);
    finish(out, len_pos)
}

/// `SASLResponse`: the raw client-final message.
pub(super) fn encode_sasl_response(out: &mut Vec<u8>, data: &[u8]) -> Result<(), PgError> {
    let len_pos = begin(out, tag::PASSWORD);
    out.extend_from_slice(data);
    finish(out, len_pos)
}

/// `Parse` of a named statement with explicit parameter type OIDs (0 would mean "infer").
pub(super) fn encode_parse(
    out: &mut Vec<u8>,
    name: &[u8],
    sql: &str,
    param_oids: &[u32],
) -> Result<(), PgError> {
    let len_pos = begin(out, tag::PARSE);
    put_cstr(out, name)?;
    put_cstr(out, sql.as_bytes())?;
    put_i16(
        out,
        i16::try_from(param_oids.len()).map_err(|_| PgError::protocol("too many parameters"))?,
    );
    for oid in param_oids {
        out.extend_from_slice(&oid.to_be_bytes());
    }
    finish(out, len_pos)
}

/// `Bind` (unnamed portal, all parameters and all result columns binary) followed by `Execute` (no row limit).
pub(super) fn encode_bind_execute(
    out: &mut Vec<u8>,
    stmt_name: &[u8],
    params: &[Param<'_>],
) -> Result<(), PgError> {
    let len_pos = begin(out, tag::BIND);
    out.push(0); // unnamed portal
    out.extend_from_slice(stmt_name);
    out.push(0);
    // One format code that applies to every parameter, then the parameter count.
    put_i16(out, 1);
    put_i16(out, FORMAT_BINARY);
    put_i16(
        out,
        i16::try_from(params.len()).map_err(|_| PgError::protocol("too many parameters"))?,
    );
    for param in params {
        codec::encode_param(out, param)?;
    }
    // One format code that applies to every result column.
    put_i16(out, 1);
    put_i16(out, FORMAT_BINARY);
    finish(out, len_pos)?;

    let len_pos = begin(out, tag::EXECUTE);
    out.push(0); // unnamed portal
    put_i32(out, 0); // max rows: unlimited
    finish(out, len_pos)
}

pub(super) fn encode_sync(out: &mut Vec<u8>) {
    out.push(tag::SYNC);
    put_i32(out, LEN_FIELD as i32);
}

/// Simple `Query` message.
pub(super) fn encode_query(out: &mut Vec<u8>, sql: &str) -> Result<(), PgError> {
    let len_pos = begin(out, tag::QUERY);
    put_cstr(out, sql.as_bytes())?;
    finish(out, len_pos)
}

/// Cursor over a backend message payload.
pub(super) struct Payload<'a> {
    rest: &'a [u8],
}

impl<'a> Payload<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Payload { rest: bytes }
    }

    pub fn rest(&self) -> &'a [u8] {
        self.rest
    }

    pub fn u8(&mut self) -> Result<u8, PgError> {
        let (&b, tail) = self.rest.split_first().ok_or_else(truncated)?;
        self.rest = tail;
        Ok(b)
    }

    pub fn i32(&mut self) -> Result<i32, PgError> {
        let (head, tail) = self.rest.split_first_chunk::<4>().ok_or_else(truncated)?;
        self.rest = tail;
        Ok(i32::from_be_bytes(*head))
    }

    /// Reads up to (and consumes) the next NUL.
    pub fn cstr(&mut self) -> Result<&'a [u8], PgError> {
        let end = self
            .rest
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(truncated)?;
        let s = &self.rest[..end];
        self.rest = &self.rest[end + 1..];
        Ok(s)
    }
}

fn truncated() -> PgError {
    PgError::protocol("truncated backend message")
}

/// Parses an ErrorResponse / NoticeResponse payload into its SQLSTATE and message.
pub(super) fn parse_error_response(payload: &[u8]) -> ServerError {
    let (mut code, mut message) = (None, None);
    let mut p = Payload::new(payload);
    // A malformed tail simply ends the field list: the error is already an error, keep what was read.
    while let Ok(field) = p.u8() {
        if field == 0 {
            break;
        }
        let Ok(value) = p.cstr() else { break };
        match field {
            b'C' => code = Some(value),
            b'M' => message = Some(value),
            _ => {}
        }
    }
    ServerError::from_fields(code, message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn be_i32(b: &[u8]) -> i32 {
        i32::from_be_bytes(b[..4].try_into().unwrap())
    }

    #[test]
    fn startup_layout() {
        let mut out = Vec::new();
        encode_startup(&mut out, "u", "d", "-c jit=off").unwrap();
        assert_eq!(be_i32(&out) as usize, out.len());
        assert_eq!(be_i32(&out[4..]), PROTOCOL_VERSION_3_0);
        assert_eq!(
            &out[8..],
            b"user\0u\0database\0d\0client_encoding\0UTF8\0options\0-c jit=off\0\0"
        );
    }

    #[test]
    fn startup_without_options_omits_the_parameter() {
        let mut out = Vec::new();
        encode_startup(&mut out, "u", "d", "").unwrap();
        assert!(!out.windows(7).any(|w| w == b"options"));
    }

    #[test]
    fn nul_in_strings_is_refused() {
        let mut out = Vec::new();
        assert!(encode_query(&mut out, "select\0 1").is_err());
        assert!(encode_startup(&mut out, "u\0", "d", "").is_err());
    }

    #[test]
    fn parse_layout() {
        let mut out = Vec::new();
        encode_parse(&mut out, b"s1", "select $1", &[20]).unwrap();
        assert_eq!(out[0], b'P');
        assert_eq!(be_i32(&out[1..]) as usize, out.len() - 1);
        assert_eq!(&out[5..], b"s1\0select $1\0\0\x01\0\0\0\x14");
    }

    #[test]
    fn bind_execute_layout() {
        let mut out = Vec::new();
        encode_bind_execute(&mut out, b"s1", &[Param::Int4(7), Param::Null]).unwrap();
        let bind_len = be_i32(&out[1..]) as usize;
        assert_eq!(out[0], b'B');
        let expected_body: &[u8] =
            b"\0s1\0\0\x01\0\x01\0\x02\0\0\0\x04\0\0\0\x07\xff\xff\xff\xff\0\x01\0\x01";
        assert_eq!(&out[5..1 + bind_len], expected_body);
        // Execute follows directly: unnamed portal, max rows 0.
        assert_eq!(&out[1 + bind_len..], b"E\0\0\0\x09\0\0\0\0\0");
    }

    #[test]
    fn sync_is_five_bytes() {
        let mut out = Vec::new();
        encode_sync(&mut out);
        assert_eq!(out, b"S\0\0\0\x04");
    }

    #[test]
    fn error_response_fields() {
        let e = parse_error_response(b"SERROR\0C23505\0Mduplicate key\0Ddetail\0\0");
        assert!(e.is_unique_violation());
        assert_eq!(e.message, "duplicate key");
    }

    #[test]
    fn truncated_error_response_does_not_panic() {
        let e = parse_error_response(b"C235");
        assert_eq!(e.sqlstate, *b"XX000");
    }

    #[test]
    fn payload_cursor() {
        let mut p = Payload::new(b"\0\0\0\x0aabc\0");
        assert_eq!(p.i32().unwrap(), 10);
        assert_eq!(p.cstr().unwrap(), b"abc");
        assert!(p.rest().is_empty());
        assert!(p.u8().is_err());
        assert!(Payload::new(b"abc").cstr().is_err());
    }
}
