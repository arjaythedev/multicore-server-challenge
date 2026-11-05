//! Response JSON, written straight into a byte buffer (no intermediate structs), and Postgres timestamps.

mod escape;
use escape::utf8;

/// `"2025-04-01T12:00:00.000Z"` for a timestamptz (microseconds since 2000-01-01 00:00:00 UTC, as Postgres sends
/// it in binary): RFC 3339 UTC, milliseconds truncated (not rounded).
pub fn ts(out: &mut Vec<u8>, micros: i64) {
    escape::ts_raw(out, micros);
}

/// A JSON string, quoted and escaped.
pub fn str(out: &mut Vec<u8>, s: &str) {
    utf8(out, s.as_bytes());
}

/// A text column's bytes (see col.rs: already valid UTF-8).
pub fn text(out: &mut Vec<u8>, t: &[u8]) {
    utf8(out, t);
}

/// A text column or `null`.
pub fn opt_text(out: &mut Vec<u8>, t: Option<&[u8]>) {
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

/// A binary PostgreSQL text[] (one dimension, no NULLs) as a JSON array, read in place.
pub fn tags(out: &mut Vec<u8>, raw: &[u8]) {
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

/// Reuse a timestamp already formatted in this response when the two values match.
/// This borrows no result across requests and still reads both database columns.
pub fn times(out: &mut Vec<u8>, created: i64, updated: i64) {
    out.extend_from_slice(b",\"createdAt\":");
    let start = out.len();
    ts(out, created);
    let end = out.len();
    out.extend_from_slice(b",\"updatedAt\":");
    if created == updated {
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
                        assert_eq!(
                            serde_json::from_slice::<String>(&out[pre * 5..]).unwrap(),
                            s
                        );
                        assert_eq!(
                            &out[pre * 5..],
                            serde_json::to_string(&s).unwrap().as_bytes()
                        );
                    }
                }
            }
        }
    }

    /// The SSE2 and AVX-512 escapes on every length to 140 with specials at every position, after a prefix.
    #[cfg(all(feature = "simd-json", target_arch = "x86_64"))]
    #[test]
    fn escape_paths_agree() {
        if !(std::is_x86_feature_detected!("avx512bw")
            && std::is_x86_feature_detected!("avx512vl")
            && std::is_x86_feature_detected!("bmi2"))
        {
            return;
        }
        let (mut a, mut b) = (Vec::new(), Vec::new());
        for len in 0..140usize {
            for pos in 0..len.max(1) {
                for c in [b'q', b'"', b'\\', b'\n', 0, 0x1f, 0x7f, 0xc3, 0xff] {
                    let mut s = vec![b'q'; len];
                    if len > 0 {
                        s[pos] = c;
                        s[len - 1 - pos / 2] = c;
                    }
                    for pre in [0, 3, 31] {
                        a.clear();
                        b.clear();
                        a.resize(pre, b'x');
                        b.resize(pre, b'x');
                        super::escape::utf8_sse2(&mut a, &s);
                        // SAFETY: the CPU has AVX-512BW, AVX-512VL and BMI2 (checked above).
                        unsafe { super::escape::utf8_avx512(&mut b, &s) };
                        assert_eq!(a, b, "len {len} pos {pos} byte {c}");
                    }
                }
            }
        }
    }

    #[test]
    fn timestamps() {
        let at = |micros: i64| {
            let mut out = Vec::new();
            super::ts(&mut out, micros);
            String::from_utf8(out).unwrap()
        };
        assert_eq!(at(0), "\"2000-01-01T00:00:00.000Z\"");
        assert_eq!(at(-1), "\"1999-12-31T23:59:59.999Z\"");
        // 2025-04-01T12:34:56.789999Z: milliseconds are truncated.
        assert_eq!(at(796_826_096_789_999), "\"2025-04-01T12:34:56.789Z\"");
        assert_eq!(at(825_638_400_000_000), "\"2026-03-01T00:00:00.000Z\"");
        assert_eq!(at(-63_113_904_000_000_000), "\"0000-01-01T00:00:00.000Z\"");
    }

    /// The fast path against Hinnant's algorithm on every day from 0000-01-01 to past 9999.
    #[test]
    fn timestamps_match_hinnant() {
        let (mut a, mut b) = (Vec::new(), Vec::new());
        for day in -719_528i64..3_100_000 {
            let rem = (day * 7_919_321).rem_euclid(86_400_000);
            a.clear();
            b.clear();
            super::escape::ts_raw(&mut a, (day - 10_957) * 86_400_000_000 + rem * 1000 + 999);
            super::escape::ts_far(&mut b, day, rem);
            assert_eq!(a, b, "day {day}");
        }
    }
}
