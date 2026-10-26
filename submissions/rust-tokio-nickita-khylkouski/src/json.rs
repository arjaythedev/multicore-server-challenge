//! Response JSON, written straight into a byte buffer (no intermediate structs), and Postgres timestamps.

use std::error::Error;

use postgres_types::{FromSql, Type};

mod escape;
use escape::utf8;

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

/// `"2025-04-01T12:00:00.000Z"`: RFC 3339 UTC, milliseconds truncated (not rounded).
pub fn ts(out: &mut Vec<u8>, t: &Ts) {
    escape::ts_raw(out, t.0);
}

/// A JSON string, quoted and escaped.
pub fn str(out: &mut Vec<u8>, s: &str) {
    utf8(out, s.as_bytes());
}

/// A text column borrowed as bytes. tokio-postgres connects with `client_encoding=UTF8` and PostgreSQL validates
/// every value it stores, so the column is written without a second UTF-8 check.
pub struct Text<'a>(&'a [u8]);
impl<'a> FromSql<'a> for Text<'a> {
    fn from_sql(_: &Type, raw: &'a [u8]) -> Result<Self, Box<dyn Error + Sync + Send>> {
        Ok(Self(raw))
    }
    fn accepts(ty: &Type) -> bool {
        <&str as FromSql>::accepts(ty)
    }
}

pub fn text(out: &mut Vec<u8>, t: Text<'_>) {
    utf8(out, t.0);
}

/// A text column or `null`.
pub fn opt_text(out: &mut Vec<u8>, t: Option<Text<'_>>) {
    match t {
        Some(t) => text(out, t),
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
                utf8(out, &raw[at..at + len as usize]);
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
        // Every escape position in strings across the 16-byte block and short-load boundaries, written after
        // assorted prefixes so the stores land at every offset.
        for len in 0..70 {
            for pos in 0..len {
                for c in ['"', '\\', '\n', '\u{1}', '\u{1f}', 'é'] {
                    let mut s: String = "q".repeat(len);
                    s.replace_range(pos..pos + 1, &c.to_string());
                    for pre in 0..3 {
                        out.clear();
                        out.extend(std::iter::repeat_n(b'x', pre * 5));
                        super::str(&mut out, &s);
                        assert_eq!(serde_json::from_slice::<String>(&out[pre * 5..]).unwrap(), s);
                        assert_eq!(&out[pre * 5..], serde_json::to_string(&s).unwrap().as_bytes());
                    }
                }
            }
        }
    }

    #[test]
    fn timestamps() {
        let at = |micros: i64| {
            let mut out = Vec::new();
            super::ts(&mut out, &super::Ts(micros));
            String::from_utf8(out).unwrap()
        };
        assert_eq!(at(0), "\"2000-01-01T00:00:00.000Z\"");
        assert_eq!(at(-1), "\"1999-12-31T23:59:59.999Z\"");
        // 2025-04-01T12:34:56.789999Z: milliseconds are truncated.
        assert_eq!(at(796_826_096_789_999), "\"2025-04-01T12:34:56.789Z\"");
        assert_eq!(at(825_638_400_000_000), "\"2026-03-01T00:00:00.000Z\"");
    }
}
