//! Response JSON, written straight into a byte buffer (no intermediate structs), and Postgres timestamps.

use std::error::Error;

use postgres_types::{FromSql, Type};

/// A timestamptz as Postgres sends it in binary: microseconds since 2000-01-01 00:00:00 UTC.
pub struct Ts(i64);

impl<'a> FromSql<'a> for Ts {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        let b: [u8; 8] = raw.try_into().map_err(|_| "bad timestamp length")?;
        Ok(Ts(i64::from_be_bytes(b)))
    }

    fn accepts(ty: &Type) -> bool {
        *ty == Type::TIMESTAMPTZ || *ty == Type::TIMESTAMP
    }
}

const PG_EPOCH_MS: i64 = 946_684_800_000;

/// `"2025-04-01T12:00:00.000Z"`: RFC 3339 UTC, milliseconds truncated (not rounded).
pub fn ts(out: &mut Vec<u8>, t: &Ts) {
    let ms = t.0.div_euclid(1000) + PG_EPOCH_MS;
    let days = ms.div_euclid(86_400_000);
    let rem = ms.rem_euclid(86_400_000);
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };

    let (h, mi, s, milli) = (
        rem / 3_600_000,
        rem / 60_000 % 60,
        rem / 1000 % 60,
        rem % 1000,
    );
    out.push(b'"');
    digits(out, y, 4);
    out.push(b'-');
    digits(out, m, 2);
    out.push(b'-');
    digits(out, d, 2);
    out.push(b'T');
    digits(out, h, 2);
    out.push(b':');
    digits(out, mi, 2);
    out.push(b':');
    digits(out, s, 2);
    out.push(b'.');
    digits(out, milli, 3);
    out.extend_from_slice(b"Z\"");
}

fn digits(out: &mut Vec<u8>, v: i64, width: u32) {
    let mut div = 10i64.pow(width - 1);
    while div > 0 {
        out.push(b'0' + (v / div % 10) as u8);
        div /= 10;
    }
}

const HEX: &[u8; 16] = b"0123456789abcdef";

/// A JSON string, quoted and escaped.
pub fn str(out: &mut Vec<u8>, s: &str) {
    out.reserve(s.len() + 2);
    out.push(b'"');
    let bytes = s.as_bytes();
    let mut start = 0;
    let mut at = 0;
    while let Some(offset) = escape(&bytes[at..]) {
        let i = at + offset;
        let b = bytes[i];
        let esc: &[u8] = match b {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => continue,
        };
        out.extend_from_slice(&bytes[start..i]);
        if esc.is_empty() {
            out.extend_from_slice(&[
                b'\\',
                b'u',
                b'0',
                b'0',
                HEX[(b >> 4) as usize],
                HEX[(b & 0xf) as usize],
            ]);
        } else {
            out.extend_from_slice(esc);
        }
        start = i + 1;
        at = start;
    }
    out.extend_from_slice(&bytes[start..]);
    out.push(b'"');
}

#[inline]
fn escape(bytes: &[u8]) -> Option<usize> {
    #[cfg(all(feature = "simd-json", target_arch = "x86_64"))]
    let mut at = 0;
    #[cfg(not(all(feature = "simd-json", target_arch = "x86_64")))]
    let at = 0;
    #[cfg(all(feature = "simd-json", target_arch = "x86_64"))]
    {
        use std::arch::x86_64::*;
        // SSE2 is part of the x86-64 baseline. Every load is fully inside the
        // slice; saturating unsigned subtraction also handles UTF-8 bytes.
        unsafe {
            let control = _mm_set1_epi8(31);
            let zero = _mm_setzero_si128();
            let quote = _mm_set1_epi8(b'"' as i8);
            let slash = _mm_set1_epi8(b'\\' as i8);
            while bytes.len() - at >= 16 {
                let v = _mm_loadu_si128(bytes.as_ptr().add(at).cast());
                let mask = _mm_movemask_epi8(_mm_or_si128(
                    _mm_cmpeq_epi8(_mm_subs_epu8(v, control), zero),
                    _mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, slash)),
                ));
                if mask != 0 {
                    return Some(at + mask.trailing_zeros() as usize);
                }
                at += 16;
            }
        }
    }
    bytes[at..]
        .iter()
        .position(|b| *b < 32 || *b == b'"' || *b == b'\\')
        .map(|i| at + i)
}

/// A string or `null`.
pub fn opt_str(out: &mut Vec<u8>, s: Option<&str>) {
    match s {
        Some(s) => str(out, s),
        None => out.extend_from_slice(b"null"),
    }
}

pub fn int(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(itoa::Buffer::new().format(v).as_bytes());
}

pub fn bool(out: &mut Vec<u8>, v: bool) {
    out.extend_from_slice(if v { b"true" } else { b"false" });
}

/// Borrow a binary PostgreSQL text[] instead of allocating a Vec for each article.
pub struct Tags<'a>(&'a [u8]);
impl<'a> FromSql<'a> for Tags<'a> {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        Ok(Self(raw))
    }
    fn accepts(ty: &Type) -> bool {
        *ty == Type::TEXT_ARRAY
    }
}
impl Tags<'_> {
    pub fn write(&self, out: &mut Vec<u8>) {
        let raw = self.0;
        let int = |at: usize| i32::from_be_bytes(raw[at..at + 4].try_into().expect("array header"));
        let dims = int(0);
        out.push(b'[');
        if dims != 0 {
            assert_eq!(dims, 1, "one-dimensional tags");
            let n = int(12);
            let mut at = 20;
            for i in 0..n {
                let len = int(at);
                at += 4;
                assert!(len >= 0, "non-null tag");
                if i != 0 {
                    out.push(b',');
                }
                str(
                    out,
                    std::str::from_utf8(&raw[at..at + len as usize]).expect("UTF-8 tag"),
                );
                at += len as usize;
            }
        }
        out.push(b']');
    }
}

/// Reuse a timestamp already formatted in this response when the two values match.
/// This borrows no result across requests and still reads both database columns.
pub fn times(out: &mut Vec<u8>, created: &Ts, updated: &Ts) {
    out.extend_from_slice(b",\"createdAt\":");
    let start = out.len();
    ts(out, created);
    let end = out.len();
    out.extend_from_slice(b",\"updatedAt\":");
    if created.0 == updated.0 {
        out.extend_from_within(start..end);
    } else {
        ts(out, updated);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn escaping_matches_serde() {
        let mut out = Vec::new();
        let mut s = String::new();
        for i in 0..1024 {
            s.push(char::from_u32((i * 7907) % 0xd800).unwrap());
            if i % 7 == 0 {
                s.push(char::from_u32(i % 128).unwrap());
            }
            out.clear();
            super::str(&mut out, &s);
            assert_eq!(serde_json::from_slice::<String>(&out).unwrap(), s);
        }
        for i in 0..64 {
            for c in ['a', '"', '\\', '\n', '\0', 'é', '🦀'] {
                let s = format!("{}{}{}", "a".repeat(i), c, "b".repeat(64 - i));
                out.clear();
                super::str(&mut out, &s);
                assert_eq!(serde_json::from_slice::<String>(&out).unwrap(), s);
            }
        }
    }
}
