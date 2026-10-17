//! Hand-written JSON output: responses are built straight into one byte buffer, no intermediate values.

use crate::util::{civil_from_days, push_2};

/// Seconds between 1970-01-01 and 2000-01-01, the Postgres timestamp epoch.
const PG_EPOCH_OFFSET_SECS: i64 = 946_684_800;

/// True if any of the 8 bytes in `w` is `"`, `\` or below 0x20. Classic SWAR tests: they may report a false
/// positive (the caller then checks byte by byte), never a false negative.
#[inline]
fn needs_escape8(w: u64) -> bool {
    const ONES: u64 = 0x0101_0101_0101_0101;
    const HIGH: u64 = 0x8080_8080_8080_8080;
    let below_space = w.wrapping_sub(ONES * 0x20) & !w;
    let quote = (w ^ (ONES * b'"' as u64)).wrapping_sub(ONES) & !(w ^ (ONES * b'"' as u64));
    let backslash = (w ^ (ONES * b'\\' as u64)).wrapping_sub(ONES) & !(w ^ (ONES * b'\\' as u64));
    (below_space | quote | backslash) & HIGH != 0
}

pub fn str(out: &mut Vec<u8>, s: &str) {
    let b = s.as_bytes();
    out.reserve(b.len() + 2);
    out.push(b'"');
    let mut start = 0;
    let mut i = 0;
    while i < b.len() {
        // Skip clean 8-byte words: article bodies are almost all plain text.
        while i + 8 <= b.len() && !needs_escape8(u64::from_le_bytes(b[i..i + 8].try_into().unwrap())) {
            i += 8;
        }
        if i >= b.len() {
            break;
        }
        let c = b[i];
        let esc: &[u8] = match c {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => {
                i += 1;
                continue;
            }
        };
        out.extend_from_slice(&b[start..i]);
        if esc.is_empty() {
            const HEX: &[u8; 16] = b"0123456789abcdef";
            out.extend_from_slice(b"\\u00");
            out.push(HEX[(c >> 4) as usize]);
            out.push(HEX[(c & 0xf) as usize]);
        } else {
            out.extend_from_slice(esc);
        }
        i += 1;
        start = i;
    }
    out.extend_from_slice(&b[start..]);
    out.push(b'"');
}

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

/// A Postgres binary timestamptz (µs since 2000-01-01 UTC) as `"YYYY-MM-DDTHH:MM:SS.mmmZ"`, truncated to ms.
pub fn ts(out: &mut Vec<u8>, pg_micros: i64) {
    let unix_micros = pg_micros + PG_EPOCH_OFFSET_SECS * 1_000_000;
    let secs = unix_micros.div_euclid(1_000_000);
    let ms = (unix_micros.rem_euclid(1_000_000) / 1000) as u32;
    let (y, m, d) = civil_from_days(secs.div_euclid(86_400));
    let sod = secs.rem_euclid(86_400) as u32;
    out.push(b'"');
    let y = y as u32;
    push_2(out, y / 100);
    push_2(out, y % 100);
    out.push(b'-');
    push_2(out, m);
    out.push(b'-');
    push_2(out, d);
    out.push(b'T');
    push_2(out, sod / 3600);
    out.push(b':');
    push_2(out, sod / 60 % 60);
    out.push(b':');
    push_2(out, sod % 60);
    out.push(b'.');
    out.push(b'0' + (ms / 100) as u8);
    push_2(out, ms % 100);
    out.extend_from_slice(b"Z\"");
}

pub fn error(out: &mut Vec<u8>, msg: &str) {
    out.extend_from_slice(b"{\"errors\":{\"body\":[");
    str(out, msg);
    out.extend_from_slice(b"]}}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> String {
        let mut o = Vec::new();
        str(&mut o, v);
        String::from_utf8(o).unwrap()
    }

    #[test]
    fn escapes() {
        assert_eq!(s(r#"a "b" \c"#), r#""a \"b\" \\c""#);
        assert_eq!(s("x\ny\u{1}"), r#""x\ny\u0001""#);
        assert_eq!(s("ünïcode <b>&</b>"), "\"ünïcode <b>&</b>\"");
        let v: serde_json::Value = serde_json::from_str(&s("\u{0}\u{1f}\"\\\t")).unwrap();
        assert_eq!(v, "\u{0}\u{1f}\"\\\t");
    }

    /// The original byte-at-a-time writer, kept as the reference for `str`.
    fn reference(out: &mut Vec<u8>, b: &[u8]) {
        out.push(b'"');
        for &c in b {
            match c {
                b'"' => out.extend_from_slice(b"\\\""),
                b'\\' => out.extend_from_slice(b"\\\\"),
                b'\n' => out.extend_from_slice(b"\\n"),
                b'\r' => out.extend_from_slice(b"\\r"),
                b'\t' => out.extend_from_slice(b"\\t"),
                0..=0x1f => out.extend_from_slice(format!("\\u{:04x}", c).as_bytes()),
                _ => out.push(c),
            }
        }
        out.push(b'"');
    }

    fn same(s: &str) {
        let (mut a, mut b) = (Vec::new(), Vec::new());
        str(&mut a, s);
        reference(&mut b, s.as_bytes());
        assert_eq!(a, b, "input {:?}", s);
    }

    #[test]
    fn matches_reference_exhaustively() {
        // Every special byte, plus neighbours of the SWAR thresholds, at every position of every length up to 24.
        let specials = ['"', '\\', '\n', '\r', '\t', '\0', '\u{1f}', '\u{1}', ' ', '!', '#', '[', ']', '\u{7f}', 'é', '€'];
        for len in 0..=24 {
            for pos in 0..len.max(1) {
                for &sp in &specials {
                    let s: String = (0..len).map(|k| if k == pos { sp } else { 'a' }).collect();
                    same(&s);
                }
            }
        }
        // Pseudo-random mixes, including multi-byte UTF-8 next to specials.
        let alphabet = ['a', 'Z', ' ', '"', '\\', '\n', '\u{1}', 'ü', '€', '😀', '\u{7f}', '.'];
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        for _ in 0..20_000 {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            let len = (x % 70) as usize;
            let s: String = (0..len)
                .map(|k| alphabet[((x >> (k % 50)) as usize + k * 7) % alphabet.len()])
                .collect();
            same(&s);
        }
    }

    #[test]
    fn timestamps() {
        let mut o = Vec::new();
        // 2025-04-01T12:00:00.123999Z: truncated, not rounded.
        let unix = 1_743_508_800i64 * 1_000_000 + 123_999;
        ts(&mut o, unix - PG_EPOCH_OFFSET_SECS * 1_000_000);
        assert_eq!(o, b"\"2025-04-01T12:00:00.123Z\"");
        o.clear();
        ts(&mut o, 0);
        assert_eq!(o, b"\"2000-01-01T00:00:00.000Z\"");
        o.clear();
        ts(&mut o, -1);
        assert_eq!(o, b"\"1999-12-31T23:59:59.999Z\"");
    }
}
