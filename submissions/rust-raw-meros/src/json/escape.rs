//! JSON string escaping (RFC 8259 section 7).
//!
//! Escaped: `"`, `\`, and control characters below 0x20 (`\n \r \t \b \f`, otherwise `\u00XX`).
//! Not escaped: `/`, DEL, and all non-ASCII bytes (the output is UTF-8, which JSON allows as is).
//!
//! Most strings in this API (slugs, titles, usernames, base64) need no escaping at all, so the work is to find
//! the first byte that does, as fast as possible, and copy everything before it in one `memcpy`. On x86_64 the
//! search tests 16 bytes per step with SSE2; the scalar search is the reference and the fallback.

/// 256-entry table: true for the bytes that must be escaped.
const NEEDS_ESCAPE: [bool; 256] = {
    let mut table = [false; 256];
    let mut b = 0;
    while b < 0x20 {
        table[b] = true;
        b += 1;
    }
    table[b'"' as usize] = true;
    table[b'\\' as usize] = true;
    table
};

const HEX: &[u8; 16] = b"0123456789abcdef";

/// Append `s` to `out`, escaped, without surrounding quotes. `s` must be valid UTF-8 for the output to be
/// valid JSON; the escaper itself works on bytes and never splits a multi-byte sequence.
pub fn write_escaped(out: &mut Vec<u8>, s: &[u8]) {
    out.reserve(s.len());
    let mut copied = 0; // everything before this index is already in `out`
    let mut at = first_dirty(s, 0);
    while at < s.len() {
        out.extend_from_slice(&s[copied..at]);
        push_escape(out, s[at]);
        copied = at + 1;
        at = first_dirty(s, copied);
    }
    out.extend_from_slice(&s[copied..]);
}

/// Append the escape sequence for one byte that `NEEDS_ESCAPE`.
fn push_escape(out: &mut Vec<u8>, b: u8) {
    match b {
        b'"' => out.extend_from_slice(b"\\\""),
        b'\\' => out.extend_from_slice(b"\\\\"),
        b'\n' => out.extend_from_slice(b"\\n"),
        b'\r' => out.extend_from_slice(b"\\r"),
        b'\t' => out.extend_from_slice(b"\\t"),
        0x08 => out.extend_from_slice(b"\\b"),
        0x0c => out.extend_from_slice(b"\\f"),
        _ => out.extend_from_slice(&[
            b'\\',
            b'u',
            b'0',
            b'0',
            HEX[usize::from(b >> 4)],
            HEX[usize::from(b & 15)],
        ]),
    }
}

/// Index of the first byte at or after `from` that needs escaping, or `s.len()`.
#[inline]
pub fn first_dirty(s: &[u8], from: usize) -> usize {
    #[cfg(target_arch = "x86_64")]
    {
        first_dirty_sse2(s, from)
    }
    #[cfg(not(target_arch = "x86_64"))]
    {
        first_dirty_scalar(s, from)
    }
}

/// Portable search; also finishes the tail the vector loop cannot cover.
#[inline]
pub fn first_dirty_scalar(s: &[u8], from: usize) -> usize {
    s[from..]
        .iter()
        .position(|&b| NEEDS_ESCAPE[usize::from(b)])
        .map_or(s.len(), |p| from + p)
}

#[cfg(target_arch = "x86_64")]
#[inline]
pub fn first_dirty_sse2(s: &[u8], from: usize) -> usize {
    use std::arch::x86_64::{
        __m128i, _mm_cmpeq_epi8, _mm_loadu_si128, _mm_min_epu8, _mm_movemask_epi8, _mm_or_si128,
        _mm_set1_epi8,
    };
    const LANES: usize = 16;
    let mut i = from;
    while i + LANES <= s.len() {
        // SAFETY: `i + 16 <= s.len()` bounds the unaligned 16-byte load; SSE2 is in the x86_64 baseline.
        let mask = unsafe {
            let v = _mm_loadu_si128(s.as_ptr().add(i).cast::<__m128i>());
            // Unsigned `v <= 0x1F` is `min(v, 0x1F) == v`; SSE2 has no unsigned compare, and a signed one
            // would flag every byte >= 0x80 (all of non-ASCII UTF-8).
            let control = _mm_cmpeq_epi8(_mm_min_epu8(v, _mm_set1_epi8(0x1f)), v);
            let quote = _mm_cmpeq_epi8(v, _mm_set1_epi8(b'"' as i8));
            let backslash = _mm_cmpeq_epi8(v, _mm_set1_epi8(b'\\' as i8));
            _mm_movemask_epi8(_mm_or_si128(control, _mm_or_si128(quote, backslash))) as u32
        };
        if mask != 0 {
            return i + mask.trailing_zeros() as usize;
        }
        i += LANES;
    }
    first_dirty_scalar(s, i)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn escaped(s: &[u8]) -> String {
        let mut v = Vec::new();
        write_escaped(&mut v, s);
        String::from_utf8(v).unwrap()
    }

    #[test]
    fn named_escapes() {
        assert_eq!(
            escaped(b"a\"b\\c\nd\re\tf\x08g\x0ch"),
            r#"a\"b\\c\nd\re\tf\bg\fh"#
        );
    }

    #[test]
    fn other_control_characters_use_u00xx() {
        assert_eq!(
            escaped(&[0x00, 0x01, 0x1f, 0x0b]),
            r"\u0000\u0001\u001f\u000b"
        );
    }

    #[test]
    fn slash_del_and_non_ascii_pass_through() {
        assert_eq!(escaped("a/b\u{7f}åäö€😀".as_bytes()), "a/b\u{7f}åäö€😀");
    }

    #[test]
    fn dirty_byte_at_every_offset_of_a_long_string() {
        for len in [0usize, 1, 15, 16, 17, 31, 32, 33, 100] {
            for pos in 0..len {
                let mut s = vec![b'x'; len];
                s[pos] = b'"';
                let out = escaped(&s);
                assert_eq!(out.len(), len + 1, "len {len} pos {pos}");
                assert_eq!(out.as_bytes()[pos..pos + 2], *b"\\\"");
            }
        }
    }

    #[test]
    fn sse2_equals_scalar_on_random_data() {
        let mut seed = 0x2545_F491_4F6C_DD1Du64;
        let mut next = move || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        for round in 0..20_000 {
            let len = (next() % 70) as usize;
            // Mix: mostly clean ASCII and high bytes, a few dirty ones; every 4th round fully random.
            let s: Vec<u8> = (0..len)
                .map(|_| {
                    let r = next();
                    if round % 4 == 0 {
                        r as u8
                    } else {
                        match r % 40 {
                            0 => b'"',
                            1 => b'\\',
                            2 => (r >> 8) as u8 % 0x20,
                            3 => 0x80 | (r >> 8) as u8,
                            _ => b' ' + (r >> 8) as u8 % 90,
                        }
                    }
                })
                .collect();
            let from = if len == 0 {
                0
            } else {
                (next() as usize) % (len + 1)
            };
            #[cfg(target_arch = "x86_64")]
            assert_eq!(
                first_dirty_sse2(&s, from),
                first_dirty_scalar(&s, from),
                "{s:?} from {from}"
            );
            // Whole-string output must also match a byte-at-a-time model.
            let mut expected = Vec::new();
            for &b in &s {
                if NEEDS_ESCAPE[usize::from(b)] {
                    push_escape(&mut expected, b);
                } else {
                    expected.push(b);
                }
            }
            let mut got = Vec::new();
            write_escaped(&mut got, &s);
            assert_eq!(got, expected);
        }
    }

    #[test]
    #[ignore = "benchmark: cargo test --release -- --ignored --nocapture"]
    fn bench_escape_clean_kib() {
        let s: Vec<u8> = (0..1024).map(|i| b'a' + (i % 26) as u8).collect();
        let mut out = Vec::with_capacity(2048);
        const ROUNDS: usize = 2_000_000;
        let start = std::time::Instant::now();
        for _ in 0..ROUNDS {
            out.clear();
            write_escaped(&mut out, std::hint::black_box(&s));
            std::hint::black_box(&out);
        }
        let secs = start.elapsed().as_secs_f64();
        let mb_s = (ROUNDS * s.len()) as f64 / secs / 1e6;
        println!(
            "write_escaped, 1 KiB clean string: {mb_s:.0} MB/s ({:.1} ns per call)",
            secs * 1e9 / ROUNDS as f64
        );
    }
}
