#![allow(dead_code)]

const HEX: &[u8; 16] = b"0123456789abcdef";

const DIGIT_PAIRS: &[u8; 200] = b"\
0001020304050607080910111213141516171819\
2021222324252627282930313233343536373839\
4041424344454647484950515253545556575859\
6061626364656667686970717273747576777879\
8081828384858687888990919293949596979899";

#[inline]
pub fn put_int(buf: &mut Vec<u8>, v: i64) {
    let mut tmp = [0u8; 24];
    let mut i = 24usize;
    let mut u = if v < 0 {
        (v as i128).unsigned_abs() as u64
    } else {
        v as u64
    };
    while u >= 100 {
        let rem = ((u % 100) as usize) * 2;
        u /= 100;
        i -= 2;
        tmp[i] = DIGIT_PAIRS[rem];
        tmp[i + 1] = DIGIT_PAIRS[rem + 1];
    }
    if u >= 10 {
        let rem = (u as usize) * 2;
        i -= 2;
        tmp[i] = DIGIT_PAIRS[rem];
        tmp[i + 1] = DIGIT_PAIRS[rem + 1];
    } else {
        i -= 1;
        tmp[i] = b'0' + (u as u8);
    }
    if v < 0 {
        i -= 1;
        tmp[i] = b'-';
    }
    buf.extend_from_slice(&tmp[i..]);
}

#[inline]
pub fn put_padded(buf: &mut Vec<u8>, v: i64, width: usize) {
    let mut tmp = [0u8; 24];
    let mut i = 24usize;
    let mut u = v.max(0) as u64;
    loop {
        i -= 1;
        tmp[i] = b'0' + ((u % 10) as u8);
        u /= 10;
        if u == 0 && (24 - i) >= width {
            break;
        }
    }
    buf.extend_from_slice(&tmp[i..]);
}

/// Writes `p` as a JSON string literal (`"..."`), escaping quotes, backslashes, and control characters
/// (`< 0x20`) identically to `JSON.stringify`.
#[inline]
pub fn put_json_string(buf: &mut Vec<u8>, p: &[u8]) {
    buf.reserve(p.len() + 2);
    buf.push(b'"');
    let mut start = 0usize;
    for (i, &c) in p.iter().enumerate() {
        if c < 0x20 || c == b'"' || c == b'\\' {
            if i > start {
                buf.extend_from_slice(&p[start..i]);
            }
            start = i + 1;
            match c {
                b'"' => buf.extend_from_slice(b"\\\""),
                b'\\' => buf.extend_from_slice(b"\\\\"),
                b'\n' => buf.extend_from_slice(b"\\n"),
                b'\r' => buf.extend_from_slice(b"\\r"),
                b'\t' => buf.extend_from_slice(b"\\t"),
                8 => buf.extend_from_slice(b"\\b"),
                12 => buf.extend_from_slice(b"\\f"),
                _ => {
                    buf.extend_from_slice(&[
                        b'\\',
                        b'u',
                        b'0',
                        b'0',
                        HEX[(c >> 4) as usize],
                        HEX[(c & 15) as usize],
                    ]);
                }
            }
        }
    }
    if p.len() > start {
        buf.extend_from_slice(&p[start..]);
    }
    buf.push(b'"');
}

#[inline]
fn put_2d(out: &mut [u8], val: usize) {
    let idx = (val % 100) * 2;
    out[0] = DIGIT_PAIRS[idx];
    out[1] = DIGIT_PAIRS[idx + 1];
}

/// Formats a Postgres binary `timestamptz` (microseconds since 2000-01-01 00:00:00 UTC)
/// as a quoted ISO 8601 UTC timestamp truncated to milliseconds: `"2025-12-31T23:59:19.409Z"`.
#[inline]
pub fn put_timestamp(buf: &mut Vec<u8>, pg_us: i64) {
    let ms = pg_us.div_euclid(1000) + 946_684_800_000;
    let days = ms.div_euclid(86_400_000);
    let in_day = (ms - days * 86_400_000) as usize;

    // Howard Hinnant's civil_from_days
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as usize;
    let m = (if mp >= 10 { mp - 9 } else { mp + 3 }) as usize;
    let mut y = yoe + era * 400;
    if m <= 2 {
        y += 1;
    }

    if (0..=9999).contains(&y) {
        let yu = y as usize;
        let hh = in_day / 3_600_000;
        let mm = (in_day / 60_000) % 60;
        let ss = (in_day / 1_000) % 60;
        let millis = in_day % 1_000;

        let mut tmp = [0u8; 26];
        tmp[0] = b'"';
        put_2d(&mut tmp[1..3], yu / 100);
        put_2d(&mut tmp[3..5], yu % 100);
        tmp[5] = b'-';
        put_2d(&mut tmp[6..8], m);
        tmp[8] = b'-';
        put_2d(&mut tmp[9..11], d);
        tmp[11] = b'T';
        put_2d(&mut tmp[12..14], hh);
        tmp[14] = b':';
        put_2d(&mut tmp[15..17], mm);
        tmp[17] = b':';
        put_2d(&mut tmp[18..20], ss);
        tmp[20] = b'.';
        tmp[21] = b'0' + ((millis / 100) as u8);
        put_2d(&mut tmp[22..24], millis % 100);
        tmp[24] = b'Z';
        tmp[25] = b'"';
        buf.extend_from_slice(&tmp);
    } else {
        buf.push(b'"');
        put_padded(buf, y, 4);
        buf.push(b'-');
        put_padded(buf, m as i64, 2);
        buf.push(b'-');
        put_padded(buf, d as i64, 2);
        buf.push(b'T');
        put_padded(buf, (in_day / 3_600_000) as i64, 2);
        buf.push(b':');
        put_padded(buf, ((in_day / 60_000) % 60) as i64, 2);
        buf.push(b':');
        put_padded(buf, ((in_day / 1_000) % 60) as i64, 2);
        buf.push(b'.');
        put_padded(buf, (in_day % 1_000) as i64, 3);
        buf.extend_from_slice(b"Z\"");
    }
}

