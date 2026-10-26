//! JSON output helpers and timestamp formatting.

const LO: u64 = 0x0101_0101_0101_0101;
const HI: u64 = 0x8080_8080_8080_8080;

/// True if any byte of the 8 needs escaping: < 0x20, '"' or '\\' (SWAR: a zero byte after XOR, or a borrow
/// below 0x20, sets that byte's high bit; bytes >= 0x80 are excluded so UTF-8 passes through).
#[inline(always)]
fn needs_escape(w: u64) -> bool {
    let quote = w ^ (LO * b'"' as u64);
    let bslash = w ^ (LO * b'\\' as u64);
    let t = (w.wrapping_sub(LO * 0x20)) | quote.wrapping_sub(LO) & !quote | bslash.wrapping_sub(LO) & !bslash;
    t & !w & HI != 0
}

/// Appends `s` as a JSON string literal (with quotes).
#[inline]
pub fn str(out: &mut Vec<u8>, s: &[u8]) {
    out.reserve(s.len() + 2);
    out.push(b'"');
    // Fast path: copy 8-byte words that need no escaping.
    let mut i = 0;
    while i + 8 <= s.len() {
        let w = u64::from_le_bytes(s[i..i + 8].try_into().unwrap());
        if needs_escape(w) {
            break;
        }
        i += 8;
    }
    if i == s.len() {
        out.extend_from_slice(s);
        out.push(b'"');
        return;
    }
    out.extend_from_slice(&s[..i]);
    let s = &s[i..];
    let mut start = 0;
    for (i, &b) in s.iter().enumerate() {
        let esc: &[u8] = match b {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => continue,
        };
        out.extend_from_slice(&s[start..i]);
        if esc.is_empty() {
            const HEX: &[u8; 16] = b"0123456789abcdef";
            out.extend_from_slice(b"\\u00");
            out.push(HEX[(b >> 4) as usize]);
            out.push(HEX[(b & 15) as usize]);
        } else {
            out.extend_from_slice(esc);
        }
        start = i + 1;
    }
    out.extend_from_slice(&s[start..]);
    out.push(b'"');
}

/// Appends a nullable string.
#[inline]
pub fn opt_str(out: &mut Vec<u8>, s: Option<&[u8]>) {
    match s {
        Some(s) => str(out, s),
        None => out.extend_from_slice(b"null"),
    }
}

#[inline]
pub fn int(out: &mut Vec<u8>, v: i64) {
    let mut b = itoa::Buffer::new();
    out.extend_from_slice(b.format(v).as_bytes());
}

#[inline]
pub fn bool(out: &mut Vec<u8>, v: bool) {
    out.extend_from_slice(if v { b"true" } else { b"false" });
}

/// Days since 1970-01-01 -> (year, month, day). Howard Hinnant's civil_from_days.
fn civil(z: i64) -> (i64, u32, u32) {
    let z = z + 719468;
    let era = if z >= 0 { z } else { z - 146096 } / 146097;
    let doe = (z - era * 146097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Appends a Postgres binary timestamptz (µs since 2000-01-01 UTC) as "YYYY-MM-DDTHH:MM:SS.mmmZ", truncated.
pub fn ts(out: &mut Vec<u8>, pg_us: i64) {
    const PG_EPOCH_US: i64 = 946_684_800_000_000;
    let us = pg_us + PG_EPOCH_US;
    let ms = us.div_euclid(1000);
    let secs = ms.div_euclid(1000);
    let msr = ms.rem_euclid(1000) as u32;
    let days = secs.div_euclid(86400);
    let sod = secs.rem_euclid(86400) as u32;
    let (y, mo, d) = civil(days);
    let mut b = [0u8; 26];
    let y = y as u32;
    b[0] = b'"';
    b[1] = b'0' + (y / 1000 % 10) as u8;
    b[2] = b'0' + (y / 100 % 10) as u8;
    b[3] = b'0' + (y / 10 % 10) as u8;
    b[4] = b'0' + (y % 10) as u8;
    b[5] = b'-';
    b[6] = b'0' + (mo / 10) as u8;
    b[7] = b'0' + (mo % 10) as u8;
    b[8] = b'-';
    b[9] = b'0' + (d / 10) as u8;
    b[10] = b'0' + (d % 10) as u8;
    b[11] = b'T';
    let (hh, mm, ss) = (sod / 3600, sod / 60 % 60, sod % 60);
    b[12] = b'0' + (hh / 10) as u8;
    b[13] = b'0' + (hh % 10) as u8;
    b[14] = b':';
    b[15] = b'0' + (mm / 10) as u8;
    b[16] = b'0' + (mm % 10) as u8;
    b[17] = b':';
    b[18] = b'0' + (ss / 10) as u8;
    b[19] = b'0' + (ss % 10) as u8;
    b[20] = b'.';
    b[21] = b'0' + (msr / 100) as u8;
    b[22] = b'0' + (msr / 10 % 10) as u8;
    b[23] = b'0' + (msr % 10) as u8;
    b[24] = b'Z';
    b[25] = b'"';
    out.extend_from_slice(&b);
}

#[cfg(test)]
mod tests {
    #[test]
    fn timestamps() {
        let mut o = Vec::new();
        super::ts(&mut o, 0);
        assert_eq!(o, b"\"2000-01-01T00:00:00.000Z\"");
        o.clear();
        // 2025-04-01T12:00:00.123999Z
        let us = (1743508800i64 * 1_000_000 + 123_999) - 946_684_800_000_000;
        super::ts(&mut o, us);
        assert_eq!(o, b"\"2025-04-01T12:00:00.123Z\"");
        o.clear();
        super::ts(&mut o, -1);
        assert_eq!(o, b"\"1999-12-31T23:59:59.999Z\"");
    }
    /// The word-at-a-time path must agree with a byte-by-byte reference on every input.
    #[test]
    fn escapes_match_reference() {
        fn reference(s: &[u8]) -> Vec<u8> {
            let mut o = vec![b'"'];
            for &b in s {
                match b {
                    b'"' => o.extend_from_slice(b"\\\""),
                    b'\\' => o.extend_from_slice(b"\\\\"),
                    b'\n' => o.extend_from_slice(b"\\n"),
                    b'\r' => o.extend_from_slice(b"\\r"),
                    b'\t' => o.extend_from_slice(b"\\t"),
                    0..=0x1f => o.extend_from_slice(format!("\\u{:04x}", b).as_bytes()),
                    _ => o.push(b),
                }
            }
            o.push(b'"');
            o
        }
        let mut x: u64 = 0x9e3779b97f4a7c15;
        for len in 0..80 {
            for _ in 0..300 {
                let s: Vec<u8> = (0..len)
                    .map(|_| {
                        x ^= x << 13;
                        x ^= x >> 7;
                        x ^= x << 17;
                        let pick = [b'a', b' ', b'"', b'\\', 0x01, 0x1f, 0x20, 0x7f, 0x80, 0xc3, 0xa9, 0xff, b'\n'];
                        if x % 4 == 0 { pick[(x >> 8) as usize % pick.len()] } else { b'a' + (x >> 16) as u8 % 26 }
                    })
                    .collect();
                let mut o = Vec::new();
                super::str(&mut o, &s);
                assert_eq!(o, reference(&s), "{s:?}");
            }
        }
    }

    #[test]
    fn escapes() {
        let mut o = Vec::new();
        super::str(&mut o, b"a\"b\\c\n\x01\xc3\xa9");
        assert_eq!(o, b"\"a\\\"b\\\\c\\n\\u0001\xc3\xa9\"");
    }
}
