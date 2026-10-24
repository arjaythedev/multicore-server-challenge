const HEX: &[u8; 16] = b"0123456789abcdef";

pub fn string(out: &mut Vec<u8>, s: &[u8]) {
    out.reserve(s.len() + 2);
    out.push(b'"');
    let mut start = 0;
    for (i, &c) in s.iter().enumerate() {
        let escape: &[u8] = match c {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => continue,
        };
        out.extend_from_slice(&s[start..i]);
        if escape.is_empty() {
            out.extend_from_slice(b"\\u00");
            out.push(HEX[(c >> 4) as usize]);
            out.push(HEX[(c & 15) as usize]);
        } else {
            out.extend_from_slice(escape);
        }
        start = i + 1;
    }
    out.extend_from_slice(&s[start..]);
    out.push(b'"');
}

pub fn opt_string(out: &mut Vec<u8>, s: Option<&[u8]>) {
    match s {
        Some(s) => string(out, s),
        None => out.extend_from_slice(b"null"),
    }
}

pub fn boolean(out: &mut Vec<u8>, b: bool) {
    out.extend_from_slice(if b { b"true" } else { b"false" });
}

pub fn int(out: &mut Vec<u8>, v: i64) {
    let mut buf = [0u8; 20];
    let mut i = buf.len();
    let neg = v < 0;
    let mut n = v.unsigned_abs();
    loop {
        i -= 1;
        buf[i] = b'0' + (n % 10) as u8;
        n /= 10;
        if n == 0 {
            break;
        }
    }
    if neg {
        out.push(b'-');
    }
    out.extend_from_slice(&buf[i..]);
}

fn two(out: &mut Vec<u8>, v: u32) {
    out.push(b'0' + (v / 10) as u8);
    out.push(b'0' + (v % 10) as u8);
}

pub fn timestamp(out: &mut Vec<u8>, micros: i64) {
    const PG_EPOCH_DAYS: i64 = 10957;
    let ms = micros.div_euclid(1000);
    let secs = ms.div_euclid(1000);
    let millis = ms.rem_euclid(1000) as u32;
    let days = secs.div_euclid(86400) + PG_EPOCH_DAYS;
    let sod = secs.rem_euclid(86400) as u32;
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let month = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    let year = yoe + era * 400 + i64::from(month <= 2);
    out.push(b'"');
    let y = year as u32;
    two(out, y / 100);
    two(out, y % 100);
    out.push(b'-');
    two(out, month);
    out.push(b'-');
    two(out, day);
    out.push(b'T');
    two(out, sod / 3600);
    out.push(b':');
    two(out, sod / 60 % 60);
    out.push(b':');
    two(out, sod % 60);
    out.push(b'.');
    out.push(b'0' + (millis / 100) as u8);
    two(out, millis % 100);
    out.extend_from_slice(b"Z\"");
}

pub fn error(out: &mut Vec<u8>, msg: &str) {
    out.extend_from_slice(b"{\"errors\":{\"body\":[");
    string(out, msg.as_bytes());
    out.extend_from_slice(b"]}}");
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn b64_encode_with(out: &mut Vec<u8>, data: &[u8], table: &[u8; 64], pad: bool) {
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        let chars = chunk.len() + 1;
        for i in 0..4 {
            if i < chars {
                out.push(table[(n >> (18 - 6 * i) & 63) as usize]);
            } else if pad {
                out.push(b'=');
            }
        }
    }
}

pub fn b64_encode(out: &mut Vec<u8>, data: &[u8]) {
    b64_encode_with(out, data, B64, true);
}

pub fn b64url_encode(out: &mut Vec<u8>, data: &[u8]) {
    b64_encode_with(out, data, B64URL, false);
}

fn b64_value(c: u8) -> Option<u32> {
    match c {
        b'A'..=b'Z' => Some(u32::from(c - b'A')),
        b'a'..=b'z' => Some(u32::from(c - b'a') + 26),
        b'0'..=b'9' => Some(u32::from(c - b'0') + 52),
        b'+' | b'-' => Some(62),
        b'/' | b'_' => Some(63),
        _ => None,
    }
}

pub fn b64_decode(data: &[u8], out: &mut Vec<u8>) -> bool {
    let data = match data.iter().position(|&c| c == b'=') {
        Some(p) => &data[..p],
        None => data,
    };
    if data.len() % 4 == 1 {
        return false;
    }
    for chunk in data.chunks(4) {
        let mut n = 0u32;
        for (i, &c) in chunk.iter().enumerate() {
            let Some(v) = b64_value(c) else {
                return false;
            };
            n |= v << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps() {
        let mut out = Vec::new();
        timestamp(&mut out, 0);
        assert_eq!(out, b"\"2000-01-01T00:00:00.000Z\"");
        out.clear();
        let micros = (1743508800i64 - 946684800) * 1_000_000 + 123_456;
        timestamp(&mut out, micros);
        assert_eq!(out, b"\"2025-04-01T12:00:00.123Z\"");
    }

    #[test]
    fn base64_roundtrip() {
        for len in 0..20 {
            let data: Vec<u8> = (0..len).map(|i| (i * 37 + 11) as u8).collect();
            let mut enc = Vec::new();
            b64url_encode(&mut enc, &data);
            let mut dec = Vec::new();
            assert!(b64_decode(&enc, &mut dec));
            assert_eq!(dec, data);
        }
    }

    #[test]
    fn escapes() {
        let mut out = Vec::new();
        string(&mut out, b"a\"b\\c\n\x01");
        assert_eq!(out, b"\"a\\\"b\\\\c\\n\\u0001\"");
    }
}
