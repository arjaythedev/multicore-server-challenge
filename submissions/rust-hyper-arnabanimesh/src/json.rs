//! Hand-written JSON writers. Responses are built straight into one `Vec<u8>` from borrowed row data:
//! no serde on the response path, no intermediate structs, no per-string allocations.

use tokio_postgres::types::{FromSql, Type};
use tokio_postgres::{Error, Row};

/// `timestamptz` in PostgreSQL's binary format: microseconds since 2000-01-01T00:00:00Z.
pub struct Ts(pub i64);

impl<'a> FromSql<'a> for Ts {
    fn from_sql(_ty: &Type, raw: &'a [u8]) -> Result<Ts, Box<dyn std::error::Error + Sync + Send>> {
        let b: [u8; 8] = raw.try_into().map_err(|_| "invalid timestamptz length")?;
        Ok(Ts(i64::from_be_bytes(b)))
    }

    fn accepts(ty: &Type) -> bool {
        *ty == Type::TIMESTAMPTZ || *ty == Type::TIMESTAMP
    }
}

const HEX: &[u8; 16] = b"0123456789abcdef";

/// Appends `s` as a JSON string literal (quotes included).
pub fn push_str(out: &mut Vec<u8>, s: &str) {
    out.push(b'"');
    let bytes = s.as_bytes();
    let mut start = 0usize;
    for (i, &b) in bytes.iter().enumerate() {
        if b >= 0x20 && b != b'"' && b != b'\\' {
            continue;
        }
        out.extend_from_slice(&bytes[start..i]);
        match b {
            b'"' => out.extend_from_slice(b"\\\""),
            b'\\' => out.extend_from_slice(b"\\\\"),
            b'\n' => out.extend_from_slice(b"\\n"),
            b'\r' => out.extend_from_slice(b"\\r"),
            b'\t' => out.extend_from_slice(b"\\t"),
            _ => {
                out.extend_from_slice(b"\\u00");
                out.push(HEX[(b >> 4) as usize]);
                out.push(HEX[(b & 0x0f) as usize]);
            }
        }
        start = i + 1;
    }
    out.extend_from_slice(&bytes[start..]);
    out.push(b'"');
}

pub fn push_opt(out: &mut Vec<u8>, s: Option<&str>) {
    match s {
        Some(s) => push_str(out, s),
        None => out.extend_from_slice(b"null"),
    }
}

pub fn push_bool(out: &mut Vec<u8>, v: bool) {
    out.extend_from_slice(if v { &b"true"[..] } else { &b"false"[..] });
}

pub fn push_int(out: &mut Vec<u8>, v: i64) {
    let mut buf = itoa::Buffer::new();
    out.extend_from_slice(buf.format(v).as_bytes());
}

fn put_digits(out: &mut Vec<u8>, mut v: u32, width: usize) {
    let mut buf = [b'0'; 10];
    for i in (0..width).rev() {
        buf[i] = b'0' + (v % 10) as u8;
        v /= 10;
    }
    out.extend_from_slice(&buf[..width]);
}

/// Days since 1970-01-01 -> (year, month, day). Howard Hinnant's `civil_from_days`.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let year = if m <= 2 { y + 1 } else { y };
    (year, m, d)
}

/// Appends a timestamp as `"2025-04-01T12:00:00.000Z"` (RFC 3339, UTC, exactly 3 fractional digits,
/// truncated rather than rounded), quotes included.
pub fn push_ts(out: &mut Vec<u8>, pg_micros: i64) {
    let unix_micros = pg_micros.saturating_add(946_684_800_000_000);
    let secs = unix_micros.div_euclid(1_000_000);
    let millis = (unix_micros.rem_euclid(1_000_000) / 1_000) as u32;
    let days = secs.div_euclid(86_400);
    let sod = secs.rem_euclid(86_400) as u32;
    let (y, m, d) = civil_from_days(days);
    out.push(b'"');
    put_digits(out, y as u32, 4);
    out.push(b'-');
    put_digits(out, m, 2);
    out.push(b'-');
    put_digits(out, d, 2);
    out.push(b'T');
    put_digits(out, sod / 3600, 2);
    out.push(b':');
    put_digits(out, (sod / 60) % 60, 2);
    out.push(b':');
    put_digits(out, sod % 60, 2);
    out.push(b'.');
    put_digits(out, millis, 3);
    out.extend_from_slice(b"Z\"");
}

pub fn error_body(msg: &str) -> Vec<u8> {
    let mut v = Vec::with_capacity(48 + msg.len());
    v.extend_from_slice(b"{\"errors\":{\"body\":[");
    push_str(&mut v, msg);
    v.extend_from_slice(b"]}}");
    v
}

/// `{"username":..,"bio":..,"image":..,"following":..}`
pub fn write_profile(
    out: &mut Vec<u8>,
    username: &str,
    bio: Option<&str>,
    image: Option<&str>,
    following: bool,
) {
    out.extend_from_slice(b"{\"username\":");
    push_str(out, username);
    out.extend_from_slice(b",\"bio\":");
    push_opt(out, bio);
    out.extend_from_slice(b",\"image\":");
    push_opt(out, image);
    out.extend_from_slice(b",\"following\":");
    push_bool(out, following);
    out.push(b'}');
}

/// Article object from a row of the list statements (`full = false`, no body) or the full-article
/// statements (`full = true`, body at column 3).
///
/// list: slug, title, description, created_at, updated_at, tag_list, favorites_count, favorited,
///       username, bio, image, following [, total]
/// full: slug, title, description, body, created_at, updated_at, tag_list, favorites_count,
///       favorited, username, bio, image, following
pub fn write_article(out: &mut Vec<u8>, row: &Row, full: bool) -> Result<(), Error> {
    let o: usize = if full { 1 } else { 0 };
    out.extend_from_slice(b"{\"slug\":");
    push_str(out, row.try_get::<_, &str>(0)?);
    out.extend_from_slice(b",\"title\":");
    push_str(out, row.try_get::<_, &str>(1)?);
    out.extend_from_slice(b",\"description\":");
    push_str(out, row.try_get::<_, &str>(2)?);
    if full {
        out.extend_from_slice(b",\"body\":");
        push_str(out, row.try_get::<_, &str>(3)?);
    }
    out.extend_from_slice(b",\"tagList\":[");
    let tags: Vec<&str> = row.try_get(5 + o)?;
    for (i, t) in tags.iter().enumerate() {
        if i > 0 {
            out.push(b',');
        }
        push_str(out, t);
    }
    out.extend_from_slice(b"],\"createdAt\":");
    push_ts(out, row.try_get::<_, Ts>(3 + o)?.0);
    out.extend_from_slice(b",\"updatedAt\":");
    push_ts(out, row.try_get::<_, Ts>(4 + o)?.0);
    out.extend_from_slice(b",\"favorited\":");
    push_bool(out, row.try_get::<_, bool>(7 + o)?);
    out.extend_from_slice(b",\"favoritesCount\":");
    push_int(out, row.try_get::<_, i64>(6 + o)?);
    out.extend_from_slice(b",\"author\":");
    write_profile(
        out,
        row.try_get::<_, &str>(8 + o)?,
        row.try_get::<_, Option<&str>>(9 + o)?,
        row.try_get::<_, Option<&str>>(10 + o)?,
        row.try_get::<_, bool>(11 + o)?,
    );
    out.push(b'}');
    Ok(())
}

/// Comment object from a row: id, body, created_at, updated_at, username, bio, image.
pub fn write_comment(out: &mut Vec<u8>, row: &Row, following: bool) -> Result<(), Error> {
    out.extend_from_slice(b"{\"id\":");
    push_int(out, row.try_get::<_, i64>(0)?);
    out.extend_from_slice(b",\"createdAt\":");
    push_ts(out, row.try_get::<_, Ts>(2)?.0);
    out.extend_from_slice(b",\"updatedAt\":");
    push_ts(out, row.try_get::<_, Ts>(3)?.0);
    out.extend_from_slice(b",\"body\":");
    push_str(out, row.try_get::<_, &str>(1)?);
    out.extend_from_slice(b",\"author\":");
    write_profile(
        out,
        row.try_get::<_, &str>(4)?,
        row.try_get::<_, Option<&str>>(5)?,
        row.try_get::<_, Option<&str>>(6)?,
        following,
    );
    out.push(b'}');
    Ok(())
}

/// `{"user":{...}}` from a row: id, username, email, bio, image [, password_hash].
pub fn write_user(out: &mut Vec<u8>, row: &Row, token: &str) -> Result<(), Error> {
    out.extend_from_slice(b"{\"user\":{\"email\":");
    push_str(out, row.try_get::<_, &str>(2)?);
    out.extend_from_slice(b",\"token\":");
    push_str(out, token);
    out.extend_from_slice(b",\"username\":");
    push_str(out, row.try_get::<_, &str>(1)?);
    out.extend_from_slice(b",\"bio\":");
    push_opt(out, row.try_get::<_, Option<&str>>(3)?);
    out.extend_from_slice(b",\"image\":");
    push_opt(out, row.try_get::<_, Option<&str>>(4)?);
    out.extend_from_slice(b"}}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(f: impl FnOnce(&mut Vec<u8>)) -> String {
        let mut v = Vec::new();
        f(&mut v);
        String::from_utf8(v).unwrap()
    }

    #[test]
    fn escapes_strings() {
        assert_eq!(s(|o| push_str(o, "plain")), "\"plain\"");
        assert_eq!(s(|o| push_str(o, "a\"b\\c\nd\te\u{1}")), "\"a\\\"b\\\\c\\nd\\te\\u0001\"");
        assert_eq!(s(|o| push_str(o, "héllo ✓")), "\"héllo ✓\"");
    }

    #[test]
    fn formats_timestamps() {
        // PostgreSQL epoch.
        assert_eq!(s(|o| push_ts(o, 0)), "\"2000-01-01T00:00:00.000Z\"");
        // 2025-04-01T12:00:00.123456Z truncates to .123
        let unix_micros: i64 = 1_743_508_800_123_456;
        assert_eq!(
            s(|o| push_ts(o, unix_micros - 946_684_800_000_000)),
            "\"2025-04-01T12:00:00.123Z\""
        );
        // before the PostgreSQL epoch (negative micros), 1999-12-31T23:59:59.999Z
        assert_eq!(s(|o| push_ts(o, -1_000)), "\"1999-12-31T23:59:59.999Z\"");
        // leap day
        assert_eq!(
            s(|o| push_ts(o, 1_709_208_000_000_000 - 946_684_800_000_000)),
            "\"2024-02-29T12:00:00.000Z\""
        );
    }
}