//! JSON string escaping and timestamp text. Dependency-free, so microbench/json_bench.rs includes this file.

const HEX: &[u8; 16] = b"0123456789abcdef";

/// The escape sequence for a byte below 0x20, `"` or `\`, and its length.
#[inline]
fn escaped(b: u8) -> ([u8; 6], usize) {
    match b {
        b'"' => (*b"\\\"....", 2),
        b'\\' => (*b"\\\\....", 2),
        b'\n' => (*b"\\n....", 2),
        b'\r' => (*b"\\r....", 2),
        b'\t' => (*b"\\t....", 2),
        _ => (
            [b'\\', b'u', b'0', b'0', HEX[(b >> 4) as usize], HEX[(b & 0xf) as usize]],
            6,
        ),
    }
}

/// Quote and escape bytes that are already valid UTF-8.
///
/// One pass on x86-64: each 16-byte block is stored to the output as it is checked, so clean text is copied by
/// the scan itself (SSE2 is part of the x86-64 baseline). The last partial block is the input's last 16 bytes,
/// stored over the copy of the bytes before it when those were copied verbatim; strings under 16 bytes are read
/// with two overlapping 8- or 4-byte loads. Every load is inside the input; every store is inside the reserved
/// capacity, past the output's length until it is extended over them.
#[cfg(all(feature = "simd-json", target_arch = "x86_64"))]
pub fn utf8(out: &mut Vec<u8>, bytes: &[u8]) {
    use std::arch::x86_64::*;
    let n = bytes.len();
    // The quotes and one 16-byte store past the copied text; an escape reserves again for its extra bytes.
    out.reserve(n + 2 + 16);
    // SAFETY: loads stay inside `bytes`; before each store, capacity - len >= (n - at) + 17 (see `reserve`
    // above and after each escape), and every store ends at most 16 bytes past `len`.
    unsafe {
        let control = _mm_set1_epi8(31);
        let zero = _mm_setzero_si128();
        let quote = _mm_set1_epi8(b'"' as i8);
        let slash = _mm_set1_epi8(b'\\' as i8);
        // Saturating unsigned subtraction also handles UTF-8 bytes.
        let special = |v: __m128i| -> u32 {
            _mm_movemask_epi8(_mm_or_si128(
                _mm_cmpeq_epi8(_mm_subs_epu8(v, control), zero),
                _mm_or_si128(_mm_cmpeq_epi8(v, quote), _mm_cmpeq_epi8(v, slash)),
            )) as u32
        };
        let src = bytes.as_ptr();
        let mut len = out.len();
        *out.as_mut_ptr().add(len) = b'"';
        len += 1;
        let mut at = 0;
        // How many output bytes just before `len` are a verbatim copy of the input just before `at`.
        let mut clean = 0;
        while at < n {
            let rem = n - at;
            let dst = out.as_mut_ptr().add(len);
            let (mask, take) = if rem >= 16 {
                let v = _mm_loadu_si128(src.add(at).cast());
                _mm_storeu_si128(dst.cast(), v);
                (special(v), 16)
            } else if clean >= 16 - rem {
                let back = 16 - rem;
                let v = _mm_loadu_si128(src.add(n - 16).cast());
                _mm_storeu_si128(dst.sub(back).cast(), v);
                (special(v) >> back, rem)
            } else if rem >= 8 && at == 0 {
                let lo = src.cast::<u64>().read_unaligned();
                let hi = src.add(n - 8).cast::<u64>().read_unaligned();
                if special(_mm_set_epi64x(hi as i64, lo as i64)) == 0 {
                    dst.cast::<u64>().write_unaligned(lo);
                    dst.add(n - 8).cast::<u64>().write_unaligned(hi);
                    len += n;
                    break;
                }
                partial(src.add(at), dst, rem, special)
            } else if rem >= 4 && at == 0 {
                let lo = src.cast::<u32>().read_unaligned();
                let hi = src.add(n - 4).cast::<u32>().read_unaligned();
                if special(_mm_cvtsi64_si128((lo as u64 | (hi as u64) << 32) as i64)) & 0xff == 0 {
                    dst.cast::<u32>().write_unaligned(lo);
                    dst.add(n - 4).cast::<u32>().write_unaligned(hi);
                    len += n;
                    break;
                }
                partial(src.add(at), dst, rem, special)
            } else {
                partial(src.add(at), dst, rem, special)
            };
            if mask == 0 {
                len += take;
                at += take;
                clean += take;
                continue;
            }
            let i = mask.trailing_zeros() as usize;
            len += i;
            at += i;
            let (esc, k) = escaped(*src.add(at));
            at += 1;
            out.set_len(len);
            out.extend_from_slice(&esc[..k]);
            out.reserve(n - at + 17);
            len = out.len();
            clean = 0;
        }
        *out.as_mut_ptr().add(len) = b'"';
        out.set_len(len + 1);
    }
}

/// The last `rem` (< 16) input bytes at `src`, through a space-padded copy: stored at `dst`, with their mask.
#[cfg(all(feature = "simd-json", target_arch = "x86_64"))]
#[inline]
unsafe fn partial(
    src: *const u8,
    dst: *mut u8,
    rem: usize,
    special: impl Fn(std::arch::x86_64::__m128i) -> u32,
) -> (u32, usize) {
    use std::arch::x86_64::*;
    let mut buf = [b' '; 16];
    // SAFETY: the caller guarantees `rem` readable bytes at `src` and 16 writable bytes at `dst`.
    unsafe {
        std::ptr::copy_nonoverlapping(src, buf.as_mut_ptr(), rem);
        let v = _mm_loadu_si128(buf.as_ptr().cast());
        _mm_storeu_si128(dst.cast(), v);
        (special(v), rem)
    }
}

/// Quote and escape bytes that are already valid UTF-8.
#[cfg(not(all(feature = "simd-json", target_arch = "x86_64")))]
pub fn utf8(out: &mut Vec<u8>, bytes: &[u8]) {
    out.reserve(bytes.len() + 2);
    out.push(b'"');
    let mut start = 0;
    while let Some(offset) = bytes[start..]
        .iter()
        .position(|b| *b < 32 || *b == b'"' || *b == b'\\')
    {
        let i = start + offset;
        out.extend_from_slice(&bytes[start..i]);
        let (esc, k) = escaped(bytes[i]);
        out.extend_from_slice(&esc[..k]);
        start = i + 1;
    }
    out.extend_from_slice(&bytes[start..]);
    out.push(b'"');
}

const PG_EPOCH_MS: i64 = 946_684_800_000;

/// "00" through "99".
const PAIRS: &[u8; 200] = b"0001020304050607080910111213141516171819\
2021222324252627282930313233343536373839\
4041424344454647484950515253545556575859\
6061626364656667686970717273747576777879\
8081828384858687888990919293949596979899";

/// `"2025-04-01T12:00:00.000Z"` for a timestamptz in microseconds since 2000-01-01 UTC: RFC 3339 UTC,
/// milliseconds truncated (not rounded). Built in a stack buffer from two-digit pairs and appended once.
pub fn ts_raw(out: &mut Vec<u8>, micros: i64) {
    let ms = micros.div_euclid(1000) + PG_EPOCH_MS;
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
    if !(0..=9999).contains(&y) {
        return ts_wide(out, y, m, d, rem);
    }
    let rem = rem as u32;
    let (h, mi, s, milli) = (
        rem / 3_600_000,
        rem / 60_000 % 60,
        rem / 1000 % 60,
        rem % 1000,
    );
    let pair = |v: u32| -> [u8; 2] {
        let i = v as usize * 2;
        [PAIRS[i], PAIRS[i + 1]]
    };
    let y = y as u32;
    let [y0, y1] = pair(y / 100);
    let [y2, y3] = pair(y % 100);
    let [m0, m1] = pair(m as u32);
    let [d0, d1] = pair(d as u32);
    let [h0, h1] = pair(h);
    let [i0, i1] = pair(mi);
    let [s0, s1] = pair(s);
    let [l1, l2] = pair(milli % 100);
    out.extend_from_slice(&[
        b'"',
        y0,
        y1,
        y2,
        y3,
        b'-',
        m0,
        m1,
        b'-',
        d0,
        d1,
        b'T',
        h0,
        h1,
        b':',
        i0,
        i1,
        b':',
        s0,
        s1,
        b'.',
        b'0' + (milli / 100) as u8,
        l1,
        l2,
        b'Z',
        b'"',
    ]);
}

/// Years outside 0..=9999, digit by digit as before (four low digits; never produced by real data).
#[cold]
fn ts_wide(out: &mut Vec<u8>, y: i64, m: i64, d: i64, rem: i64) {
    fn digits(out: &mut Vec<u8>, v: i64, width: u32) {
        let mut div = 10i64.pow(width - 1);
        while div > 0 {
            out.push(b'0' + (v / div % 10) as u8);
            div /= 10;
        }
    }
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
