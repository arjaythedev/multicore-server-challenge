//! JSON output: strings, nullable strings, integers, booleans and Postgres timestamps.

const LO: u64 = 0x0101_0101_0101_0101;
const HI: u64 = 0x8080_8080_8080_8080;

/// Any of the 8 bytes < 0x20, '"' or '\\' (bytes >= 0x80 pass, so UTF-8 is copied as is).
#[inline(always)]
fn needs_escape(w: u64) -> bool {
    let q = w ^ (LO * b'"' as u64);
    let b = w ^ (LO * b'\\' as u64);
    let t = w.wrapping_sub(LO * 0x20) | (q.wrapping_sub(LO) & !q) | (b.wrapping_sub(LO) & !b);
    t & !w & HI != 0
}

/// `s` as a JSON string literal, quotes included.
#[inline]
pub fn string(out: &mut Vec<u8>, s: &[u8]) {
    out.reserve(s.len() + 2);
    out.push(b'"');
    let mut i = 0;
    while i + 8 <= s.len() && !needs_escape(u64::from_le_bytes(s[i..i + 8].try_into().unwrap())) {
        i += 8;
    }
    let mut start = 0;
    for j in i..s.len() {
        let c = s[j];
        let esc: &[u8] = match c {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => continue,
        };
        out.extend_from_slice(&s[start..j]);
        if esc.is_empty() {
            const HEX: &[u8; 16] = b"0123456789abcdef";
            out.extend_from_slice(&[b'\\', b'u', b'0', b'0', HEX[(c >> 4) as usize], HEX[(c & 15) as usize]]);
        } else {
            out.extend_from_slice(esc);
        }
        start = j + 1;
    }
    out.extend_from_slice(&s[start..]);
    out.push(b'"');
}

#[inline]
pub fn opt(out: &mut Vec<u8>, s: Option<&[u8]>) {
    match s {
        Some(s) => string(out, s),
        None => out.extend_from_slice(b"null"),
    }
}

#[inline]
pub fn int(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(itoa::Buffer::new().format(v).as_bytes());
}

#[inline]
pub fn bool(out: &mut Vec<u8>, v: bool) {
    out.extend_from_slice(if v { b"true" } else { b"false" });
}

/// Days since 1970-01-01 -> (year, month, day) (Hinnant's civil_from_days).
fn civil(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let y = yoe as i64 + era * 400;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// A binary timestamptz (µs since 2000-01-01 UTC) as `"YYYY-MM-DDTHH:MM:SS.mmmZ"`, truncated to milliseconds.
pub fn ts(out: &mut Vec<u8>, pg_us: i64) {
    const PG_EPOCH_US: i64 = 946_684_800_000_000;
    let ms = (pg_us + PG_EPOCH_US).div_euclid(1000);
    let secs = ms.div_euclid(1000);
    let msr = ms.rem_euclid(1000) as u32;
    let (y, mo, d) = civil(secs.div_euclid(86_400));
    let sod = secs.rem_euclid(86_400) as u32;
    let (hh, mm, ss) = (sod / 3600, sod / 60 % 60, sod % 60);
    let y = y as u32;
    let dg = |v: u32| b'0' + (v % 10) as u8;
    out.extend_from_slice(&[
        b'"',
        dg(y / 1000),
        dg(y / 100),
        dg(y / 10),
        dg(y),
        b'-',
        dg(mo / 10),
        dg(mo),
        b'-',
        dg(d / 10),
        dg(d),
        b'T',
        dg(hh / 10),
        dg(hh),
        b':',
        dg(mm / 10),
        dg(mm),
        b':',
        dg(ss / 10),
        dg(ss),
        b'.',
        dg(msr / 100),
        dg(msr / 10),
        dg(msr),
        b'Z',
        b'"',
    ]);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps() {
        let mut o = Vec::new();
        ts(&mut o, 0);
        assert_eq!(o, b"\"2000-01-01T00:00:00.000Z\"");
        o.clear();
        ts(&mut o, (1_743_508_800i64 * 1_000_000 + 123_999) - 946_684_800_000_000);
        assert_eq!(o, b"\"2025-04-01T12:00:00.123Z\"");
        o.clear();
        ts(&mut o, -1);
        assert_eq!(o, b"\"1999-12-31T23:59:59.999Z\"");
    }

    #[test]
    fn escaping_matches_a_byte_at_a_time_reference() {
        fn reference(s: &[u8]) -> Vec<u8> {
            let mut o = vec![b'"'];
            for &b in s {
                match b {
                    b'"' => o.extend_from_slice(b"\\\""),
                    b'\\' => o.extend_from_slice(b"\\\\"),
                    b'\n' => o.extend_from_slice(b"\\n"),
                    b'\r' => o.extend_from_slice(b"\\r"),
                    b'\t' => o.extend_from_slice(b"\\t"),
                    0..=0x1f => o.extend_from_slice(format!("\\u{b:04x}").as_bytes()),
                    _ => o.push(b),
                }
            }
            o.push(b'"');
            o
        }
        let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
        let pick = [b'a', b' ', b'"', b'\\', 0x01, 0x1f, 0x20, 0x7f, 0x80, 0xc3, 0xa9, 0xff, b'\n'];
        for len in 0..80 {
            for _ in 0..300 {
                let s: Vec<u8> = (0..len)
                    .map(|_| {
                        x ^= x << 13;
                        x ^= x >> 7;
                        x ^= x << 17;
                        if x % 4 == 0 { pick[(x >> 8) as usize % pick.len()] } else { b'a' + (x >> 16) as u8 % 26 }
                    })
                    .collect();
                let mut o = Vec::new();
                string(&mut o, &s);
                assert_eq!(o, reference(&s), "{s:?}");
            }
        }
    }
}
