//! Allocation-free JSON writers for responses, plus tiny helpers for request bodies.

use serde_json::{Map, Value};

const HEX: &[u8; 16] = b"0123456789abcdef";

static ESC: [bool; 256] = build_esc();

const fn build_esc() -> [bool; 256] {
    let mut t = [false; 256];
    let mut i = 0;
    while i < 32 {
        t[i] = true;
        i += 1;
    }
    t[b'"' as usize] = true;
    t[b'\\' as usize] = true;
    t
}

/// Writes `s` as a JSON string (with quotes). `s` must be valid UTF-8 (it always comes from Postgres
/// or from a validated request).
pub fn push_str(out: &mut Vec<u8>, s: &[u8]) {
    out.push(b'"');
    let mut start = 0usize;
    let mut i = 0usize;
    while i < s.len() {
        let b = s[i];
        if ESC[b as usize] {
            out.extend_from_slice(&s[start..i]);
            match b {
                b'"' => out.extend_from_slice(b"\\\""),
                b'\\' => out.extend_from_slice(b"\\\\"),
                b'\n' => out.extend_from_slice(b"\\n"),
                b'\r' => out.extend_from_slice(b"\\r"),
                b'\t' => out.extend_from_slice(b"\\t"),
                _ => {
                    out.extend_from_slice(b"\\u00");
                    out.push(HEX[(b >> 4) as usize]);
                    out.push(HEX[(b & 15) as usize]);
                }
            }
            start = i + 1;
        }
        i += 1;
    }
    out.extend_from_slice(&s[start..]);
    out.push(b'"');
}

/// `null` for SQL NULL, otherwise a JSON string.
pub fn push_opt_str(out: &mut Vec<u8>, s: Option<&[u8]>) {
    match s {
        Some(v) => push_str(out, v),
        None => out.extend_from_slice(b"null"),
    }
}

pub fn push_u64(out: &mut Vec<u8>, mut n: u64) {
    if n == 0 {
        out.push(b'0');
        return;
    }
    let mut buf = [0u8; 20];
    let mut i = 20usize;
    while n > 0 {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
    }
    out.extend_from_slice(&buf[i..]);
}

pub fn push_i64(out: &mut Vec<u8>, v: i64) {
    if v < 0 {
        out.push(b'-');
    }
    push_u64(out, v.unsigned_abs());
}

pub fn push_bool(out: &mut Vec<u8>, v: bool) {
    if v {
        out.extend_from_slice(b"true");
    } else {
        out.extend_from_slice(b"false");
    }
}

#[inline]
fn put2(out: &mut Vec<u8>, v: u32) {
    out.push(b'0' + (v / 10) as u8);
    out.push(b'0' + (v % 10) as u8);
}

/// Year/month/day for a day count relative to 1970-01-01 (Howard Hinnant's civil_from_days).
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Writes a Postgres binary `timestamptz` (microseconds since 2000-01-01 UTC) as an RFC 3339 string
/// with exactly three fractional digits, truncated (not rounded): `"2025-01-01T02:05:45.678Z"`.
pub fn push_ts(out: &mut Vec<u8>, micros: i64) {
    let secs = micros.div_euclid(1_000_000);
    let ms = (micros.rem_euclid(1_000_000) / 1000) as u32;
    let days = secs.div_euclid(86_400) + 10_957; // 2000-01-01 is day 10957 after 1970-01-01
    let sod = secs.rem_euclid(86_400) as u32;
    let (y, m, d) = civil_from_days(days);
    out.push(b'"');
    let yy = if y < 0 { 0 } else { y as u32 };
    out.push(b'0' + ((yy / 1000) % 10) as u8);
    out.push(b'0' + ((yy / 100) % 10) as u8);
    out.push(b'0' + ((yy / 10) % 10) as u8);
    out.push(b'0' + (yy % 10) as u8);
    out.push(b'-');
    put2(out, m);
    out.push(b'-');
    put2(out, d);
    out.push(b'T');
    put2(out, sod / 3600);
    out.push(b':');
    put2(out, (sod % 3600) / 60);
    out.push(b':');
    put2(out, sod % 60);
    out.push(b'.');
    out.push(b'0' + (ms / 100) as u8);
    out.push(b'0' + ((ms / 10) % 10) as u8);
    out.push(b'0' + (ms % 10) as u8);
    out.push(b'Z');
    out.push(b'"');
}

/// `{"errors":{"body":["<msg>"]}}` — `msg` must not need escaping (we only pass static ASCII text).
pub fn error_body(out: &mut Vec<u8>, msg: &str) {
    out.extend_from_slice(b"{\"errors\":{\"body\":[\"");
    out.extend_from_slice(msg.as_bytes());
    out.extend_from_slice(b"\"]}}");
}

// ---------------------------------------------------------------------------- request bodies

pub fn parse_body(body: &[u8]) -> Option<Value> {
    serde_json::from_slice::<Value>(body).ok()
}

pub enum Field<'a> {
    /// Missing or `null`.
    Absent,
    Str(&'a str),
    /// Present but not a string.
    Bad,
}

pub fn field<'a>(obj: &'a Map<String, Value>, key: &str) -> Field<'a> {
    match obj.get(key) {
        None => Field::Absent,
        Some(Value::Null) => Field::Absent,
        Some(Value::String(s)) => Field::Str(s.as_str()),
        Some(_) => Field::Bad,
    }
}
