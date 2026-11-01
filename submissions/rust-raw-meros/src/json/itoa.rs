//! Integer to decimal text with a two-digit lookup table (halves the number of divisions).

/// Digits of `u64::MAX`.
pub const MAX_U64_DIGITS: usize = 20;

/// `"00" "01" ... "99"` as 200 bytes, built at compile time.
const PAIRS: [u8; 200] = {
    let mut table = [0u8; 200];
    let mut i = 0;
    while i < 100 {
        table[2 * i] = b'0' + (i / 10) as u8;
        table[2 * i + 1] = b'0' + (i % 10) as u8;
        i += 1;
    }
    table
};

/// Write the digits of `n` right-aligned into `buf` and return the index of the first digit.
/// The text is `buf[returned..]`.
pub fn format_u64(mut n: u64, buf: &mut [u8; MAX_U64_DIGITS]) -> usize {
    let mut at = MAX_U64_DIGITS;
    while n >= 100 {
        let pair = (n % 100) as usize * 2;
        n /= 100;
        at -= 2;
        buf[at..at + 2].copy_from_slice(&PAIRS[pair..pair + 2]);
    }
    if n >= 10 {
        let pair = n as usize * 2;
        at -= 2;
        buf[at..at + 2].copy_from_slice(&PAIRS[pair..pair + 2]);
    } else {
        at -= 1;
        buf[at] = b'0' + n as u8;
    }
    at
}

/// Append `n` in decimal.
pub fn write_u64(out: &mut Vec<u8>, n: u64) {
    let mut buf = [0u8; MAX_U64_DIGITS];
    let first = format_u64(n, &mut buf);
    out.extend_from_slice(&buf[first..]);
}

/// Append `n` in decimal, with a leading `-` when negative.
pub fn write_i64(out: &mut Vec<u8>, n: i64) {
    if n < 0 {
        out.push(b'-');
    }
    write_u64(out, n.unsigned_abs());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(n: i64) -> String {
        let mut v = Vec::new();
        write_i64(&mut v, n);
        String::from_utf8(v).unwrap()
    }

    #[test]
    fn matches_std_formatting() {
        let mut samples = vec![
            0i64,
            1,
            9,
            10,
            11,
            99,
            100,
            101,
            999,
            1000,
            12345,
            i64::MAX,
            i64::MIN,
            -1,
            -10,
            -100,
        ];
        let mut x = 1i64;
        while let Some(next) = x.checked_mul(7) {
            samples.extend([next, next - 1, next + 1, -next]);
            x = next;
        }
        for n in samples {
            assert_eq!(text(n), n.to_string());
        }
    }

    #[test]
    fn u64_max() {
        let mut v = Vec::new();
        write_u64(&mut v, u64::MAX);
        assert_eq!(v, u64::MAX.to_string().as_bytes());
        assert_eq!(v.len(), MAX_U64_DIGITS);
    }
}
