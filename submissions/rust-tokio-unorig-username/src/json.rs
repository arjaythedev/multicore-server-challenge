//! JSON output written straight from Postgres rows.

use std::time::{SystemTime, UNIX_EPOCH};
use tokio_postgres::Row;

pub fn str(o: &mut Vec<u8>, s: &str) {
    o.push(b'"');
    let b = s.as_bytes();
    let mut start = 0;
    for (i, &c) in b.iter().enumerate() {
        let esc: &[u8] = match c {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => continue,
        };
        o.extend_from_slice(&b[start..i]);
        if esc.is_empty() {
            const HEX: &[u8; 16] = b"0123456789abcdef";
            o.extend_from_slice(&[b'\\', b'u', b'0', b'0', HEX[(c >> 4) as usize], HEX[(c & 15) as usize]]);
        } else {
            o.extend_from_slice(esc);
        }
        start = i + 1;
    }
    o.extend_from_slice(&b[start..]);
    o.push(b'"');
}

pub fn opt(o: &mut Vec<u8>, s: Option<&str>) {
    match s {
        Some(s) => str(o, s),
        None => o.extend_from_slice(b"null"),
    }
}

pub fn int(o: &mut Vec<u8>, n: i64) {
    o.extend_from_slice(itoa::Buffer::new().format(n).as_bytes());
}

pub fn bool(o: &mut Vec<u8>, b: bool) {
    o.extend_from_slice(if b { b"true" } else { b"false" });
}

/// RFC 3339 UTC with exactly 3 fractional digits, truncated.
pub fn time(o: &mut Vec<u8>, t: SystemTime) {
    // Conduit timestamps are after 1970; civil-from-days (Howard Hinnant) for non-negative days.
    let ms = t.duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64);
    let (days, rem) = (ms / 86_400_000, ms % 86_400_000);
    let z = days + 719_468;
    let era = z / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + (m <= 2) as i64;
    let (h, mi, s, f) = (rem / 3_600_000, rem / 60_000 % 60, rem / 1000 % 60, rem % 1000);
    let mut b = *b"\"0000-00-00T00:00:00.000Z\"";
    let mut put = |at: usize, v: i64, w: usize| {
        let mut v = v;
        for k in (0..w).rev() {
            b[at + k] = b'0' + (v % 10) as u8;
            v /= 10;
        }
    };
    put(1, y, 4);
    put(6, m, 2);
    put(9, d, 2);
    put(12, h, 2);
    put(15, mi, 2);
    put(18, s, 2);
    put(21, f, 3);
    o.extend_from_slice(&b);
}

pub fn profile(o: &mut Vec<u8>, username: &str, bio: Option<&str>, image: Option<&str>, following: bool) {
    o.extend_from_slice(b"{\"username\":");
    str(o, username);
    o.extend_from_slice(b",\"bio\":");
    opt(o, bio);
    o.extend_from_slice(b",\"image\":");
    opt(o, image);
    o.extend_from_slice(b",\"following\":");
    bool(o, following);
    o.push(b'}');
}

/// Article columns from index `b`: id, slug, title, description, created_at, updated_at, tags, count,
/// favorited, username, bio, image, following, then body when `body`.
pub fn article(o: &mut Vec<u8>, r: &Row, b: usize, body: bool) {
    o.extend_from_slice(b"{\"slug\":");
    str(o, r.get(b + 1));
    o.extend_from_slice(b",\"title\":");
    str(o, r.get(b + 2));
    o.extend_from_slice(b",\"description\":");
    str(o, r.get(b + 3));
    if body {
        o.extend_from_slice(b",\"body\":");
        str(o, r.get(b + 13));
    }
    o.extend_from_slice(b",\"tagList\":[");
    for (i, t) in r.get::<_, Vec<&str>>(b + 6).into_iter().enumerate() {
        if i > 0 {
            o.push(b',');
        }
        str(o, t);
    }
    o.extend_from_slice(b"],\"createdAt\":");
    time(o, r.get(b + 4));
    o.extend_from_slice(b",\"updatedAt\":");
    time(o, r.get(b + 5));
    o.extend_from_slice(b",\"favorited\":");
    bool(o, r.get(b + 8));
    o.extend_from_slice(b",\"favoritesCount\":");
    int(o, r.get(b + 7));
    o.extend_from_slice(b",\"author\":");
    profile(o, r.get(b + 9), r.get(b + 10), r.get(b + 11), r.get(b + 12));
    o.push(b'}');
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    #[test]
    fn formats() {
        let mut o = Vec::new();
        time(&mut o, UNIX_EPOCH + Duration::from_micros(1_743_508_800_123_999));
        assert_eq!(o, b"\"2025-04-01T12:00:00.123Z\"");
        o.clear();
        time(&mut o, UNIX_EPOCH + Duration::from_secs(951_782_400)); // leap day 2000
        assert_eq!(o, b"\"2000-02-29T00:00:00.000Z\"");
        o.clear();
        str(&mut o, "a\"b\\c\n\u{1}é");
        assert_eq!(o, "\"a\\\"b\\\\c\\n\\u0001é\"".as_bytes());
    }
}
