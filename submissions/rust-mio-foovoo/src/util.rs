//! Small parsing and formatting helpers shared by the HTTP layer and the handlers.

use std::time::{SystemTime, UNIX_EPOCH};

pub fn unix_now() -> (i64, u32) {
    let d = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default();
    (d.as_secs() as i64, d.subsec_micros())
}

/// Non-empty ASCII digits that fit in an i64 (no sign, no whitespace).
pub fn parse_digits_i64(s: &str) -> Option<i64> {
    if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    s.bytes().try_fold(0i64, |acc, b| acc.checked_mul(10)?.checked_add((b - b'0') as i64))
}

/// Percent-decodes one path segment. `None` for invalid UTF-8 or an embedded NUL, which Postgres can't store in text.
pub fn decode_segment(s: &str) -> Option<String> {
    if !s.contains('%') {
        return (!s.contains('\0')).then(|| s.to_string());
    }
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            if let (Some(h), Some(l)) = (hex(b.get(i + 1)), hex(b.get(i + 2))) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    let s = String::from_utf8(out).ok()?;
    (!s.contains('\0')).then_some(s)
}

fn hex(b: Option<&u8>) -> Option<u8> {
    match *b? {
        c @ b'0'..=b'9' => Some(c - b'0'),
        c @ b'a'..=b'f' => Some(c - b'a' + 10),
        c @ b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

/// Days since 1970-01-01 to (year, month, day), proleptic Gregorian (Howard Hinnant's civil_from_days).
pub fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

pub fn push_2(out: &mut Vec<u8>, v: u32) {
    out.push(b'0' + (v / 10 % 10) as u8);
    out.push(b'0' + (v % 10) as u8);
}

/// IMF-fixdate for the `Date` header, e.g. `Sun, 06 Nov 1994 08:49:37 GMT`.
pub fn http_date(unix_secs: i64, out: &mut Vec<u8>) {
    const DAYS: [&[u8]; 7] = [b"Thu", b"Fri", b"Sat", b"Sun", b"Mon", b"Tue", b"Wed"];
    const MONTHS: [&[u8]; 12] = [b"Jan", b"Feb", b"Mar", b"Apr", b"May", b"Jun", b"Jul", b"Aug", b"Sep", b"Oct", b"Nov", b"Dec"];
    let days = unix_secs.div_euclid(86_400);
    let sod = unix_secs.rem_euclid(86_400) as u32;
    let (y, m, d) = civil_from_days(days);
    out.extend_from_slice(DAYS[days.rem_euclid(7) as usize]);
    out.extend_from_slice(b", ");
    push_2(out, d);
    out.push(b' ');
    out.extend_from_slice(MONTHS[(m - 1) as usize]);
    out.push(b' ');
    out.extend_from_slice(itoa::Buffer::new().format(y).as_bytes());
    out.push(b' ');
    push_2(out, sod / 3600);
    out.push(b':');
    push_2(out, sod / 60 % 60);
    out.push(b':');
    push_2(out, sod % 60);
    out.extend_from_slice(b" GMT");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn digits() {
        assert_eq!(parse_digits_i64("005"), Some(5));
        assert_eq!(parse_digits_i64(""), None);
        assert_eq!(parse_digits_i64("+5"), None);
        assert_eq!(parse_digits_i64(" 5"), None);
        assert_eq!(parse_digits_i64("1.5"), None);
        assert_eq!(parse_digits_i64("9223372036854775807"), Some(i64::MAX));
        assert_eq!(parse_digits_i64("99999999999999999999"), None);
    }

    #[test]
    fn segments() {
        assert_eq!(decode_segment("abc-1").as_deref(), Some("abc-1"));
        assert_eq!(decode_segment("a%20b").as_deref(), Some("a b"));
        assert_eq!(decode_segment("a%2").as_deref(), Some("a%2"));
        assert_eq!(decode_segment("a%00b"), None);
        assert_eq!(decode_segment("%ff"), None);
    }

    #[test]
    fn date() {
        let mut v = Vec::new();
        http_date(784_111_777, &mut v);
        assert_eq!(v, b"Sun, 06 Nov 1994 08:49:37 GMT");
    }
}
