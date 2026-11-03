const MASK_LO: u64 = 0x0101_0101_0101_0101;
const MASK_HI: u64 = 0x8080_8080_8080_8080;

const DEC_DIGITS_LUT: &[u8; 200] = b"\
0001020304050607080910111213141516171819\
2021222324252627282930313233343536373839\
4041424344454647484950515253545556575859\
6061626364656667686970717273747576777879\
8081828384858687888990919293949596979899";

#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn has_avx2() -> bool {
    #[cfg(target_feature = "avx2")]
    {
        true
    }
    #[cfg(not(target_feature = "avx2"))]
    {
        use std::sync::atomic::{AtomicU8, Ordering};
        static CACHE: AtomicU8 = AtomicU8::new(0);
        match CACHE.load(Ordering::Relaxed) {
            2 => true,
            1 => false,
            _ => {
                let ok = std::is_x86_feature_detected!("avx2");
                CACHE.store(if ok { 2 } else { 1 }, Ordering::Relaxed);
                ok
            }
        }
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn find_byte_avx2(haystack: &[u8], needle: u8) -> Option<usize> {
    use std::arch::x86_64::*;
    let mut pos = 0usize;
    let vn = _mm256_set1_epi8(needle as i8);
    while pos + 32 <= haystack.len() {
        let chunk = unsafe { _mm256_loadu_si256(haystack.as_ptr().add(pos).cast()) };
        let mask = _mm256_movemask_epi8(_mm256_cmpeq_epi8(chunk, vn)) as u32;
        if mask != 0 {
            return Some(pos + mask.trailing_zeros() as usize);
        }
        pos += 32;
    }
    let vn16 = _mm_set1_epi8(needle as i8);
    if pos + 16 <= haystack.len() {
        let chunk = unsafe { _mm_loadu_si128(haystack.as_ptr().add(pos).cast()) };
        let mask = _mm_movemask_epi8(_mm_cmpeq_epi8(chunk, vn16)) as u32;
        if mask != 0 {
            return Some(pos + mask.trailing_zeros() as usize);
        }
        pos += 16;
    }
    while pos < haystack.len() {
        if haystack[pos] == needle {
            return Some(pos);
        }
        pos += 1;
    }
    None
}

#[inline(always)]
pub fn find_byte(haystack: &[u8], needle: u8) -> Option<usize> {
    #[cfg(target_arch = "x86_64")]
    if haystack.len() >= 32 && has_avx2() {
        return unsafe { find_byte_avx2(haystack, needle) };
    }
    let mut pos = 0;
    #[cfg(target_arch = "x86_64")]
    unsafe {
        use std::arch::x86_64::*;
        let vn = _mm_set1_epi8(needle as i8);
        while pos + 16 <= haystack.len() {
            let chunk = _mm_loadu_si128(haystack.as_ptr().add(pos).cast());
            let mask = _mm_movemask_epi8(_mm_cmpeq_epi8(chunk, vn)) as u32;
            if mask != 0 {
                return Some(pos + mask.trailing_zeros() as usize);
            }
            pos += 16;
        }
    }
    while pos < haystack.len() {
        if haystack[pos] == needle {
            return Some(pos);
        }
        pos += 1;
    }
    None
}

#[inline(always)]
pub fn find_crlf(haystack: &[u8]) -> Option<usize> {
    if haystack.len() < 2 {
        return None;
    }
    let last = haystack.len() - 1;
    let mut pos = 0;
    while pos < last {
        let rem = &haystack[pos..last];
        let Some(off) = find_byte(rem, b'\r') else {
            return None;
        };
        let idx = pos + off;
        if haystack[idx + 1] == b'\n' {
            return Some(idx);
        }
        pos = idx + 1;
    }
    None
}

pub fn fill_random(mut dst: &mut [u8]) -> bool {
    while !dst.is_empty() {
        let rc = unsafe { crate::reactor::sys::getrandom(dst.as_mut_ptr().cast(), dst.len(), 0) };
        if rc < 0 {
            let err = std::io::Error::last_os_error().raw_os_error();
            if err == Some(crate::reactor::sys::EINTR) {
                continue;
            }
            return false;
        }
        let n = rc as usize;
        dst = &mut dst[n..];
    }
    true
}

#[inline(always)]
fn has_special8(word: u64) -> bool {
    let q = word ^ (MASK_LO * b'"' as u64);
    let bs = word ^ (MASK_LO * b'\\' as u64);
    let ctrl = (word.wrapping_sub(MASK_LO * 0x20))
        | (q.wrapping_sub(MASK_LO) & !q)
        | (bs.wrapping_sub(MASK_LO) & !bs);
    (ctrl & !word & MASK_HI) != 0
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn scan_clean_avx2(buf: &[u8]) -> usize {
    use std::arch::x86_64::*;
    let mut pos = 0usize;
    let vq = _mm256_set1_epi8(b'"' as i8);
    let vs = _mm256_set1_epi8(b'\\' as i8);
    let vc = _mm256_set1_epi8(0x1f);
    while pos + 32 <= buf.len() {
        let chunk = unsafe { _mm256_loadu_si256(buf.as_ptr().add(pos).cast()) };
        let is_quote = _mm256_cmpeq_epi8(chunk, vq);
        let is_slash = _mm256_cmpeq_epi8(chunk, vs);
        let is_ctrl = _mm256_cmpeq_epi8(_mm256_min_epu8(chunk, vc), chunk);
        let mask = _mm256_movemask_epi8(_mm256_or_si256(_mm256_or_si256(is_quote, is_slash), is_ctrl)) as u32;
        if mask != 0 {
            return pos + mask.trailing_zeros() as usize;
        }
        pos += 32;
    }
    pos
}

#[cfg(target_arch = "x86_64")]
#[inline(always)]
fn chunk16_clean(buf: &[u8]) -> bool {
    unsafe {
        use std::arch::x86_64::*;
        let chunk = _mm_loadu_si128(buf.as_ptr().cast());
        let is_quote = _mm_cmpeq_epi8(chunk, _mm_set1_epi8(b'"' as i8));
        let is_slash = _mm_cmpeq_epi8(chunk, _mm_set1_epi8(b'\\' as i8));
        let is_ctrl = _mm_cmpeq_epi8(_mm_min_epu8(chunk, _mm_set1_epi8(0x1f)), chunk);
        let mask = _mm_or_si128(_mm_or_si128(is_quote, is_slash), is_ctrl);
        _mm_movemask_epi8(mask) == 0
    }
}

#[inline]
pub fn write_str(dst: &mut Vec<u8>, src: &[u8]) {
    dst.reserve(src.len() + 2);
    dst.push(b'"');
    let mut pos = 0;

    #[cfg(target_arch = "x86_64")]
    if src.len() >= 32 && has_avx2() {
        pos = unsafe { scan_clean_avx2(src) };
    }
    #[cfg(target_arch = "x86_64")]
    while pos + 16 <= src.len() {
        if !chunk16_clean(&src[pos..]) {
            break;
        }
        pos += 16;
    }
    while pos + 8 <= src.len() {
        let w = u64::from_le_bytes(src[pos..pos + 8].try_into().unwrap());
        if has_special8(w) {
            break;
        }
        pos += 8;
    }
    while pos < src.len() {
        let c = src[pos];
        if c < 0x20 || c == b'"' || c == b'\\' {
            break;
        }
        pos += 1;
    }
    if pos == src.len() {
        dst.extend_from_slice(src);
        dst.push(b'"');
        return;
    }

    dst.extend_from_slice(&src[..pos]);
    let tail = &src[pos..];
    let mut anchor = 0;
    let mut idx = 0;
    while idx < tail.len() {
        #[cfg(target_arch = "x86_64")]
        if idx + 32 <= tail.len() && has_avx2() {
            let step = unsafe { scan_clean_avx2(&tail[idx..]) };
            if step > 0 {
                idx += step;
                if idx >= tail.len() {
                    break;
                }
            }
        }
        #[cfg(target_arch = "x86_64")]
        if idx + 16 <= tail.len() && chunk16_clean(&tail[idx..]) {
            idx += 16;
            continue;
        }
        let c = tail[idx];
        let repl: &[u8] = match c {
            b'"' => b"\\\"",
            b'\\' => b"\\\\",
            b'\n' => b"\\n",
            b'\r' => b"\\r",
            b'\t' => b"\\t",
            0..=0x1f => b"",
            _ => {
                idx += 1;
                continue;
            }
        };
        dst.extend_from_slice(&tail[anchor..idx]);
        if repl.is_empty() {
            const HEX: &[u8; 16] = b"0123456789abcdef";
            dst.extend_from_slice(&[b'\\', b'u', b'0', b'0', HEX[(c >> 4) as usize], HEX[(c & 0x0f) as usize]]);
        } else {
            dst.extend_from_slice(repl);
        }
        anchor = idx + 1;
        idx += 1;
    }
    dst.extend_from_slice(&tail[anchor..]);
    dst.push(b'"');
}

#[inline]
pub fn write_nullable_str(dst: &mut Vec<u8>, val: Option<&[u8]>) {
    match val {
        Some(s) => write_str(dst, s),
        None => dst.extend_from_slice(b"null"),
    }
}

#[inline]
pub fn format_u64_into(mut n: u64, buf: &mut [u8; 20]) -> &[u8] {
    let mut pos = 20;
    while n >= 100 {
        let rem = ((n % 100) * 2) as usize;
        n /= 100;
        pos -= 2;
        buf[pos] = DEC_DIGITS_LUT[rem];
        buf[pos + 1] = DEC_DIGITS_LUT[rem + 1];
    }
    if n < 10 {
        pos -= 1;
        buf[pos] = b'0' + n as u8;
    } else {
        let rem = (n * 2) as usize;
        pos -= 2;
        buf[pos] = DEC_DIGITS_LUT[rem];
        buf[pos + 1] = DEC_DIGITS_LUT[rem + 1];
    }
    &buf[pos..]
}

#[inline]
pub fn write_i64(dst: &mut Vec<u8>, val: i64) {
    if val < 0 {
        dst.push(b'-');
    }
    let mut buf = [0u8; 20];
    dst.extend_from_slice(format_u64_into(val.unsigned_abs(), &mut buf));
}

#[inline]
pub fn write_bool(dst: &mut Vec<u8>, val: bool) {
    dst.extend_from_slice(if val { b"true" } else { b"false" });
}

#[inline]
fn ymd_from_unix_days(days: i64) -> (i64, u32, u32) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// Formats a PostgreSQL binary timestamptz (microseconds since 2000-01-01 UTC) as RFC 3339.
#[inline]
pub fn write_timestamp(dst: &mut Vec<u8>, pg_micros: i64) {
    const PG_EPOCH_MICROS: i64 = 946_684_800_000_000;
    let total_us = pg_micros + PG_EPOCH_MICROS;
    let total_ms = total_us.div_euclid(1000);
    let total_sec = total_ms.div_euclid(1000);
    let millis = total_ms.rem_euclid(1000) as u32;
    let days = total_sec.div_euclid(86_400);
    let day_sec = total_sec.rem_euclid(86_400) as u32;
    let (year, month, day) = ymd_from_unix_days(days);
    let y = year as u32;
    let (hh, mm, ss) = (day_sec / 3600, (day_sec / 60) % 60, day_sec % 60);

    let yh = (((y / 100) % 100) * 2) as usize;
    let yl = ((y % 100) * 2) as usize;
    let mo = (month * 2) as usize;
    let da = (day * 2) as usize;
    let h2 = (hh * 2) as usize;
    let m2 = (mm * 2) as usize;
    let s2 = (ss * 2) as usize;
    let msl = ((millis % 100) * 2) as usize;

    let out: [u8; 26] = [
        b'"',
        DEC_DIGITS_LUT[yh],
        DEC_DIGITS_LUT[yh + 1],
        DEC_DIGITS_LUT[yl],
        DEC_DIGITS_LUT[yl + 1],
        b'-',
        DEC_DIGITS_LUT[mo],
        DEC_DIGITS_LUT[mo + 1],
        b'-',
        DEC_DIGITS_LUT[da],
        DEC_DIGITS_LUT[da + 1],
        b'T',
        DEC_DIGITS_LUT[h2],
        DEC_DIGITS_LUT[h2 + 1],
        b':',
        DEC_DIGITS_LUT[m2],
        DEC_DIGITS_LUT[m2 + 1],
        b':',
        DEC_DIGITS_LUT[s2],
        DEC_DIGITS_LUT[s2 + 1],
        b'.',
        b'0' + (millis / 100) as u8,
        DEC_DIGITS_LUT[msl],
        DEC_DIGITS_LUT[msl + 1],
        b'Z',
        b'"',
    ];
    dst.extend_from_slice(&out);
}

const B64_STD_ENC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const B64_URL_ENC: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

const B64_STD_DEC: [u8; 256] = {
    let mut t = [0xffu8; 256];
    let mut i = 0;
    while i < 64 {
        t[B64_STD_ENC[i] as usize] = i as u8;
        i += 1;
    }
    t
};

const B64_URL_DEC: [u8; 256] = {
    let mut t = [0xffu8; 256];
    let mut i = 0;
    while i < 64 {
        t[B64_URL_ENC[i] as usize] = i as u8;
        i += 1;
    }
    t
};

#[inline]
pub fn b64url_encode_append(src: &[u8], dst: &mut String) {
    let out = unsafe { dst.as_mut_vec() };
    out.reserve((src.len() * 4 + 2) / 3);
    let mut i = 0;
    while i + 3 <= src.len() {
        let n = ((src[i] as u32) << 16) | ((src[i + 1] as u32) << 8) | (src[i + 2] as u32);
        out.extend_from_slice(&[
            B64_URL_ENC[((n >> 18) & 0x3f) as usize],
            B64_URL_ENC[((n >> 12) & 0x3f) as usize],
            B64_URL_ENC[((n >> 6) & 0x3f) as usize],
            B64_URL_ENC[(n & 0x3f) as usize],
        ]);
        i += 3;
    }
    let rem = src.len() - i;
    if rem == 1 {
        let n = (src[i] as u32) << 16;
        out.push(B64_URL_ENC[((n >> 18) & 0x3f) as usize]);
        out.push(B64_URL_ENC[((n >> 12) & 0x3f) as usize]);
    } else if rem == 2 {
        let n = ((src[i] as u32) << 16) | ((src[i + 1] as u32) << 8);
        out.push(B64_URL_ENC[((n >> 18) & 0x3f) as usize]);
        out.push(B64_URL_ENC[((n >> 12) & 0x3f) as usize]);
        out.push(B64_URL_ENC[((n >> 6) & 0x3f) as usize]);
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "ssse3")]
unsafe fn b64url_decode_chunk16_ssse3(chunk: &[u8], out12: &mut [u8]) -> bool {
    unsafe {
        use std::arch::x86_64::*;
        let c = _mm_loadu_si128(chunk.as_ptr().cast());
        let is_upper = _mm_and_si128(
            _mm_cmpgt_epi8(c, _mm_set1_epi8(b'A' as i8 - 1)),
            _mm_cmpgt_epi8(_mm_set1_epi8(b'Z' as i8 + 1), c),
        );
        let is_lower = _mm_and_si128(
            _mm_cmpgt_epi8(c, _mm_set1_epi8(b'a' as i8 - 1)),
            _mm_cmpgt_epi8(_mm_set1_epi8(b'z' as i8 + 1), c),
        );
        let is_digit = _mm_and_si128(
            _mm_cmpgt_epi8(c, _mm_set1_epi8(b'0' as i8 - 1)),
            _mm_cmpgt_epi8(_mm_set1_epi8(b'9' as i8 + 1), c),
        );
        let is_dash = _mm_cmpeq_epi8(c, _mm_set1_epi8(b'-' as i8));
        let is_under = _mm_cmpeq_epi8(c, _mm_set1_epi8(b'_' as i8));
        let valid = _mm_or_si128(
            _mm_or_si128(is_upper, is_lower),
            _mm_or_si128(is_digit, _mm_or_si128(is_dash, is_under)),
        );
        if _mm_movemask_epi8(valid) != 0xffff {
            return false;
        }
        let off = _mm_or_si128(
            _mm_or_si128(
                _mm_and_si128(is_upper, _mm_set1_epi8(-65)),
                _mm_and_si128(is_lower, _mm_set1_epi8(-71)),
            ),
            _mm_or_si128(
                _mm_and_si128(is_digit, _mm_set1_epi8(4)),
                _mm_or_si128(
                    _mm_and_si128(is_dash, _mm_set1_epi8(17)),
                    _mm_and_si128(is_under, _mm_set1_epi8(-32)),
                ),
            ),
        );
        let v = _mm_add_epi8(c, off);
        let merged16 = _mm_maddubs_epi16(v, _mm_set1_epi32(0x0140_0140));
        let merged32 = _mm_madd_epi16(merged16, _mm_set1_epi32(0x0001_1000));
        let shuf = _mm_setr_epi8(2, 1, 0, 6, 5, 4, 10, 9, 8, 14, 13, 12, -1, -1, -1, -1);
        let packed = _mm_shuffle_epi8(merged32, shuf);
        let mut tmp = [0u8; 16];
        _mm_storeu_si128(tmp.as_mut_ptr().cast(), packed);
        out12[..12].copy_from_slice(&tmp[..12]);
        true
    }
}

#[inline]
pub fn b64url_decode_slice(src: &[u8], dst: &mut [u8]) -> Option<usize> {
    if src.len() % 4 == 1 {
        return None;
    }
    let needed = (src.len() / 4) * 3
        + match src.len() % 4 {
            2 => 1,
            3 => 2,
            _ => 0,
        };
    if dst.len() < needed {
        return None;
    }
    let mut si = 0;
    let mut di = 0;
    #[cfg(target_arch = "x86_64")]
    if has_avx2() {
        while si + 16 <= src.len() {
            if !unsafe { b64url_decode_chunk16_ssse3(&src[si..si + 16], &mut dst[di..di + 12]) } {
                return None;
            }
            si += 16;
            di += 12;
        }
    }
    while si + 4 <= src.len() {
        let a = B64_URL_DEC[src[si] as usize];
        let b = B64_URL_DEC[src[si + 1] as usize];
        let c = B64_URL_DEC[src[si + 2] as usize];
        let d = B64_URL_DEC[src[si + 3] as usize];
        if (a | b | c | d) & 0x80 != 0 {
            return None;
        }
        let n = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6) | (d as u32);
        dst[di] = (n >> 16) as u8;
        dst[di + 1] = (n >> 8) as u8;
        dst[di + 2] = n as u8;
        si += 4;
        di += 3;
    }
    let rem = src.len() - si;
    if rem == 2 {
        let a = B64_URL_DEC[src[si] as usize];
        let b = B64_URL_DEC[src[si + 1] as usize];
        if (a | b) & 0x80 != 0 || (b & 0x0f) != 0 {
            return None;
        }
        dst[di] = (a << 2) | (b >> 4);
        di += 1;
    } else if rem == 3 {
        let a = B64_URL_DEC[src[si] as usize];
        let b = B64_URL_DEC[src[si + 1] as usize];
        let c = B64_URL_DEC[src[si + 2] as usize];
        if (a | b | c) & 0x80 != 0 || (c & 0x03) != 0 {
            return None;
        }
        let n = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6);
        dst[di] = (n >> 16) as u8;
        dst[di + 1] = (n >> 8) as u8;
        di += 2;
    }
    Some(di)
}

pub fn b64url_decode_vec(src: &[u8]) -> Option<Vec<u8>> {
    let cap = (src.len() * 3) / 4 + 3;
    let mut out = vec![0u8; cap];
    let n = b64url_decode_slice(src, &mut out)?;
    out.truncate(n);
    Some(out)
}

pub fn b64std_encode(src: &[u8]) -> String {
    let mut out = Vec::with_capacity(((src.len() + 2) / 3) * 4);
    let mut i = 0;
    while i + 3 <= src.len() {
        let n = ((src[i] as u32) << 16) | ((src[i + 1] as u32) << 8) | (src[i + 2] as u32);
        out.push(B64_STD_ENC[((n >> 18) & 0x3f) as usize]);
        out.push(B64_STD_ENC[((n >> 12) & 0x3f) as usize]);
        out.push(B64_STD_ENC[((n >> 6) & 0x3f) as usize]);
        out.push(B64_STD_ENC[(n & 0x3f) as usize]);
        i += 3;
    }
    let rem = src.len() - i;
    if rem == 1 {
        let n = (src[i] as u32) << 16;
        out.push(B64_STD_ENC[((n >> 18) & 0x3f) as usize]);
        out.push(B64_STD_ENC[((n >> 12) & 0x3f) as usize]);
        out.push(b'=');
        out.push(b'=');
    } else if rem == 2 {
        let n = ((src[i] as u32) << 16) | ((src[i + 1] as u32) << 8);
        out.push(B64_STD_ENC[((n >> 18) & 0x3f) as usize]);
        out.push(B64_STD_ENC[((n >> 12) & 0x3f) as usize]);
        out.push(B64_STD_ENC[((n >> 6) & 0x3f) as usize]);
        out.push(b'=');
    }
    unsafe { String::from_utf8_unchecked(out) }
}

pub fn b64std_decode(src: &str) -> Option<Vec<u8>> {
    let bytes = src.as_bytes();
    if bytes.is_empty() || bytes.len() % 4 != 0 {
        return Some(Vec::new()).filter(|_| bytes.is_empty());
    }
    let mut out = Vec::with_capacity((bytes.len() / 4) * 3);
    let mut i = 0;
    while i < bytes.len() {
        let a = B64_STD_DEC[bytes[i] as usize];
        let b = B64_STD_DEC[bytes[i + 1] as usize];
        if (a | b) & 0x80 != 0 {
            return None;
        }
        let c_raw = bytes[i + 2];
        let d_raw = bytes[i + 3];
        if c_raw == b'=' {
            if d_raw != b'=' || i + 4 != bytes.len() || (b & 0x0f) != 0 {
                return None;
            }
            out.push((a << 2) | (b >> 4));
            break;
        }
        let c = B64_STD_DEC[c_raw as usize];
        if c & 0x80 != 0 {
            return None;
        }
        if d_raw == b'=' {
            if i + 4 != bytes.len() || (c & 0x03) != 0 {
                return None;
            }
            let n = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6);
            out.push((n >> 16) as u8);
            out.push((n >> 8) as u8);
            break;
        }
        let d = B64_STD_DEC[d_raw as usize];
        if d & 0x80 != 0 {
            return None;
        }
        let n = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6) | (d as u32);
        out.push((n >> 16) as u8);
        out.push((n >> 8) as u8);
        out.push(n as u8);
        i += 4;
    }
    Some(out)
}

#[derive(Clone, Debug, PartialEq)]
pub enum JsonVal {
    Null,
    Bool(bool),
    Number(f64),
    Str(String),
    Array(Vec<JsonVal>),
    Object(JsonMap),
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct JsonMap {
    entries: Vec<(String, JsonVal)>,
}

impl JsonMap {
    pub fn get(&self, key: &str) -> Option<&JsonVal> {
        self.entries.iter().rev().find(|(k, _)| k == key).map(|(_, v)| v)
    }

    pub fn remove(&mut self, key: &str) -> Option<JsonVal> {
        let pos = self.entries.iter().rposition(|(k, _)| k == key)?;
        let val = self.entries.remove(pos).1;
        self.entries.retain(|(k, _)| k != key);
        Some(val)
    }

    pub fn values(&self) -> impl Iterator<Item = &JsonVal> {
        self.entries.iter().map(|(_, v)| v)
    }

    pub fn insert(&mut self, k: String, v: JsonVal) {
        if let Some((_, existing)) = self.entries.iter_mut().find(|(ek, _)| *ek == k) {
            *existing = v;
        } else {
            self.entries.push((k, v));
        }
    }
}

impl JsonVal {
    pub fn as_str(&self) -> Option<&str> {
        match self {
            JsonVal::Str(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match *self {
            JsonVal::Number(n) => Some(n),
            _ => None,
        }
    }

    pub fn as_object(&self) -> Option<&JsonMap> {
        match self {
            JsonVal::Object(m) => Some(m),
            _ => None,
        }
    }

    pub fn get(&self, key: &str) -> Option<&JsonVal> {
        self.as_object()?.get(key)
    }
}

pub fn parse_json(src: &[u8]) -> Option<JsonVal> {
    let mut p = JsonParser { src, pos: 0 };
    let val = p.parse_value(0)?;
    p.skip_ws();
    if p.pos != p.src.len() {
        return None;
    }
    Some(val)
}

struct JsonParser<'a> {
    src: &'a [u8],
    pos: usize,
}

impl<'a> JsonParser<'a> {
    #[inline]
    fn skip_ws(&mut self) {
        while self.pos < self.src.len() && matches!(self.src[self.pos], b' ' | b'\t' | b'\r' | b'\n') {
            self.pos += 1;
        }
    }

    fn parse_value(&mut self, depth: usize) -> Option<JsonVal> {
        if depth > 64 {
            return None;
        }
        self.skip_ws();
        let b = *self.src.get(self.pos)?;
        match b {
            b'"' => self.parse_string().map(JsonVal::Str),
            b'{' => self.parse_object(depth + 1).map(JsonVal::Object),
            b'[' => self.parse_array(depth + 1).map(JsonVal::Array),
            b't' => {
                if self.src.get(self.pos..self.pos + 4)? == b"true" {
                    self.pos += 4;
                    Some(JsonVal::Bool(true))
                } else {
                    None
                }
            }
            b'f' => {
                if self.src.get(self.pos..self.pos + 5)? == b"false" {
                    self.pos += 5;
                    Some(JsonVal::Bool(false))
                } else {
                    None
                }
            }
            b'n' => {
                if self.src.get(self.pos..self.pos + 4)? == b"null" {
                    self.pos += 4;
                    Some(JsonVal::Null)
                } else {
                    None
                }
            }
            b'-' | b'0'..=b'9' => self.parse_number().map(JsonVal::Number),
            _ => None,
        }
    }

    fn parse_string(&mut self) -> Option<String> {
        self.pos += 1;
        let start = self.pos;
        #[cfg(target_arch = "x86_64")]
        if self.src.len() - self.pos >= 32 && has_avx2() {
            self.pos += unsafe { scan_clean_avx2(&self.src[self.pos..]) };
        }
        while self.pos < self.src.len() {
            let c = self.src[self.pos];
            if c == b'"' {
                let s = std::str::from_utf8(&self.src[start..self.pos]).ok()?.to_owned();
                self.pos += 1;
                return Some(s);
            }
            if c == b'\\' {
                return self.parse_string_escaped(start);
            }
            if c < 0x20 {
                return None;
            }
            self.pos += 1;
        }
        None
    }

    fn parse_string_escaped(&mut self, start: usize) -> Option<String> {
        let mut out = std::str::from_utf8(&self.src[start..self.pos]).ok()?.to_owned();
        while self.pos < self.src.len() {
            let c = self.src[self.pos];
            if c == b'"' {
                self.pos += 1;
                return Some(out);
            }
            if c < 0x20 {
                return None;
            }
            if c != b'\\' {
                let seg_start = self.pos;
                self.pos += 1;
                #[cfg(target_arch = "x86_64")]
                if self.src.len() - self.pos >= 32 && has_avx2() {
                    self.pos += unsafe { scan_clean_avx2(&self.src[self.pos..]) };
                }
                while self.pos < self.src.len() {
                    let b = self.src[self.pos];
                    if b == b'"' || b == b'\\' || b < 0x20 {
                        break;
                    }
                    self.pos += 1;
                }
                out.push_str(std::str::from_utf8(&self.src[seg_start..self.pos]).ok()?);
                continue;
            }
            self.pos += 1;
            let esc = *self.src.get(self.pos)?;
            self.pos += 1;
            match esc {
                b'"' => out.push('"'),
                b'\\' => out.push('\\'),
                b'/' => out.push('/'),
                b'b' => out.push('\x08'),
                b'f' => out.push('\x0c'),
                b'n' => out.push('\n'),
                b'r' => out.push('\r'),
                b't' => out.push('\t'),
                b'u' => {
                    let u1 = self.read_hex4()?;
                    let code = if (0xD800..=0xDBFF).contains(&u1) {
                        if self.src.get(self.pos..self.pos + 2)? != b"\\u" {
                            return None;
                        }
                        self.pos += 2;
                        let u2 = self.read_hex4()?;
                        if !(0xDC00..=0xDFFF).contains(&u2) {
                            return None;
                        }
                        0x10000 + (((u1 - 0xD800) as u32) << 10) + ((u2 - 0xDC00) as u32)
                    } else if (0xDC00..=0xDFFF).contains(&u1) {
                        return None;
                    } else {
                        u1 as u32
                    };
                    out.push(char::from_u32(code)?);
                }
                _ => return None,
            }
        }
        None
    }

    fn read_hex4(&mut self) -> Option<u16> {
        let hex = self.src.get(self.pos..self.pos + 4)?;
        self.pos += 4;
        let mut val = 0u16;
        for &b in hex {
            let d = match b {
                b'0'..=b'9' => b - b'0',
                b'a'..=b'f' => b - b'a' + 10,
                b'A'..=b'F' => b - b'A' + 10,
                _ => return None,
            };
            val = (val << 4) | (d as u16);
        }
        Some(val)
    }

    fn parse_number(&mut self) -> Option<f64> {
        let start = self.pos;
        if self.src.get(self.pos) == Some(&b'-') {
            self.pos += 1;
        }
        let first = *self.src.get(self.pos)?;
        if first == b'0' {
            self.pos += 1;
            if self.src.get(self.pos).is_some_and(|b| b.is_ascii_digit()) {
                return None;
            }
        } else if first.is_ascii_digit() {
            while self.src.get(self.pos).is_some_and(|b| b.is_ascii_digit()) {
                self.pos += 1;
            }
        } else {
            return None;
        }
        if self.src.get(self.pos) == Some(&b'.') {
            self.pos += 1;
            let frac_start = self.pos;
            while self.src.get(self.pos).is_some_and(|b| b.is_ascii_digit()) {
                self.pos += 1;
            }
            if self.pos == frac_start {
                return None;
            }
        }
        if matches!(self.src.get(self.pos), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.src.get(self.pos), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            let exp_start = self.pos;
            while self.src.get(self.pos).is_some_and(|b| b.is_ascii_digit()) {
                self.pos += 1;
            }
            if self.pos == exp_start {
                return None;
            }
        }
        let s = std::str::from_utf8(&self.src[start..self.pos]).ok()?;
        let v: f64 = s.parse().ok()?;
        if v.is_finite() { Some(v) } else { None }
    }

    fn parse_array(&mut self, depth: usize) -> Option<Vec<JsonVal>> {
        self.pos += 1;
        self.skip_ws();
        let mut arr = Vec::new();
        if self.src.get(self.pos) == Some(&b']') {
            self.pos += 1;
            return Some(arr);
        }
        loop {
            arr.push(self.parse_value(depth)?);
            self.skip_ws();
            match *self.src.get(self.pos)? {
                b',' => self.pos += 1,
                b']' => {
                    self.pos += 1;
                    return Some(arr);
                }
                _ => return None,
            }
        }
    }

    fn parse_object(&mut self, depth: usize) -> Option<JsonMap> {
        self.pos += 1;
        self.skip_ws();
        let mut map = JsonMap::default();
        if self.src.get(self.pos) == Some(&b'}') {
            self.pos += 1;
            return Some(map);
        }
        loop {
            self.skip_ws();
            if *self.src.get(self.pos)? != b'"' {
                return None;
            }
            let key = self.parse_string()?;
            self.skip_ws();
            if *self.src.get(self.pos)? != b':' {
                return None;
            }
            self.pos += 1;
            let val = self.parse_value(depth)?;
            map.insert(key, val);
            self.skip_ws();
            match *self.src.get(self.pos)? {
                b',' => self.pos += 1,
                b'}' => {
                    self.pos += 1;
                    return Some(map);
                }
                _ => return None,
            }
        }
    }
}

#[inline]
pub fn contains_gzip_token(val: &[u8]) -> bool {
    if val.eq_ignore_ascii_case(b"gzip") {
        return true;
    }
    for part in val.split(|&b| b == b',') {
        let mut s = part;
        while let [b' ' | b'\t', rest @ ..] = s {
            s = rest;
        }
        while let [rest @ .., b' ' | b'\t'] = s {
            s = rest;
        }
        let mut iter = s.splitn(2, |&b| b == b';');
        let coding = iter.next().unwrap_or(b"");
        let mut ctrim = coding;
        while let [rest @ .., b' ' | b'\t'] = ctrim {
            ctrim = rest;
        }
        if !ctrim.eq_ignore_ascii_case(b"gzip") {
            continue;
        }
        if let Some(params) = iter.next() {
            let mut p = params;
            while let [b' ' | b'\t', rest @ ..] = p {
                p = rest;
            }
            if p.len() >= 3 && p[..2].eq_ignore_ascii_case(b"q=") && p[2] == b'0' {
                let rest = &p[3..];
                let all_zero = rest.iter().all(|&b| b == b'.' || b == b'0' || b == b' ' || b == b'\t');
                if all_zero {
                    continue;
                }
            }
        }
        return true;
    }
    false
}

const CRC32_SLICE4: [[u32; 256]; 4] = {
    let mut t = [[0u32; 256]; 4];
    let mut i = 0;
    while i < 256 {
        let mut c = i as u32;
        let mut k = 0;
        while k < 8 {
            c = if (c & 1) != 0 {
                (c >> 1) ^ 0xEDB8_8320
            } else {
                c >> 1
            };
            k += 1;
        }
        t[0][i] = c;
        i += 1;
    }
    let mut i = 0;
    while i < 256 {
        let mut c = t[0][i];
        let mut s = 1;
        while s < 4 {
            c = (c >> 8) ^ t[0][(c & 0xff) as usize];
            t[s][i] = c;
            s += 1;
        }
        i += 1;
    }
    t
};

#[inline]
fn crc32_slice4(mut crc: u32, data: &[u8]) -> u32 {
    let mut i = 0;
    while i + 4 <= data.len() {
        let w = crc ^ u32::from_le_bytes([data[i], data[i + 1], data[i + 2], data[i + 3]]);
        crc = CRC32_SLICE4[3][(w & 0xff) as usize]
            ^ CRC32_SLICE4[2][((w >> 8) & 0xff) as usize]
            ^ CRC32_SLICE4[1][((w >> 16) & 0xff) as usize]
            ^ CRC32_SLICE4[0][(w >> 24) as usize];
        i += 4;
    }
    while i < data.len() {
        crc = (crc >> 8) ^ CRC32_SLICE4[0][((crc as u8) ^ data[i]) as usize];
        i += 1;
    }
    crc
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "pclmulqdq,sse4.1")]
unsafe fn crc32_pclmul(data: &[u8]) -> u32 {
    use std::arch::x86_64::*;
    if data.len() < 64 {
        return !crc32_slice4(!0u32, data);
    }
    unsafe {
        let ptr = data.as_ptr();
        let mut x0 = _mm_loadu_si128(ptr.cast());
        let mut x1 = _mm_loadu_si128(ptr.add(16).cast());
        let mut x2 = _mm_loadu_si128(ptr.add(32).cast());
        let mut x3 = _mm_loadu_si128(ptr.add(48).cast());
        x0 = _mm_xor_si128(x0, _mm_cvtsi32_si128(!0i32));

        let k1k2 = _mm_set_epi64x(0x1c6e_4159_6i64, 0x1544_42bd_4i64);
        let mut pos = 64usize;
        #[cfg(all(target_feature = "vpclmulqdq", target_feature = "avx2"))]
        if data.len() >= 128 {
            let mut v0 = _mm256_inserti128_si256(_mm256_castsi128_si256(x0), x1, 1);
            let mut v1 = _mm256_inserti128_si256(_mm256_castsi128_si256(x2), x3, 1);
            let vk1k2 = _mm256_broadcastsi128_si256(k1k2);
            while pos + 64 <= data.len() {
                let vy0 = _mm256_loadu_si256(ptr.add(pos).cast());
                let vy1 = _mm256_loadu_si256(ptr.add(pos + 32).cast());
                v0 = _mm256_xor_si256(
                    _mm256_xor_si256(
                        _mm256_clmulepi64_epi128(v0, vk1k2, 0x00),
                        _mm256_clmulepi64_epi128(v0, vk1k2, 0x11),
                    ),
                    vy0,
                );
                v1 = _mm256_xor_si256(
                    _mm256_xor_si256(
                        _mm256_clmulepi64_epi128(v1, vk1k2, 0x00),
                        _mm256_clmulepi64_epi128(v1, vk1k2, 0x11),
                    ),
                    vy1,
                );
                pos += 64;
            }
            x0 = _mm256_castsi256_si128(v0);
            x1 = _mm256_extracti128_si256(v0, 1);
            x2 = _mm256_castsi256_si128(v1);
            x3 = _mm256_extracti128_si256(v1, 1);
        }
        while pos + 64 <= data.len() {
            let y0 = _mm_loadu_si128(ptr.add(pos).cast());
            let y1 = _mm_loadu_si128(ptr.add(pos + 16).cast());
            let y2 = _mm_loadu_si128(ptr.add(pos + 32).cast());
            let y3 = _mm_loadu_si128(ptr.add(pos + 48).cast());

            x0 = _mm_xor_si128(
                _mm_xor_si128(_mm_clmulepi64_si128(x0, k1k2, 0x00), _mm_clmulepi64_si128(x0, k1k2, 0x11)),
                y0,
            );
            x1 = _mm_xor_si128(
                _mm_xor_si128(_mm_clmulepi64_si128(x1, k1k2, 0x00), _mm_clmulepi64_si128(x1, k1k2, 0x11)),
                y1,
            );
            x2 = _mm_xor_si128(
                _mm_xor_si128(_mm_clmulepi64_si128(x2, k1k2, 0x00), _mm_clmulepi64_si128(x2, k1k2, 0x11)),
                y2,
            );
            x3 = _mm_xor_si128(
                _mm_xor_si128(_mm_clmulepi64_si128(x3, k1k2, 0x00), _mm_clmulepi64_si128(x3, k1k2, 0x11)),
                y3,
            );
            pos += 64;
        }

        let k3k4 = _mm_set_epi64x(0x0cca_a009_ei64, 0x1751_997d_0i64);
        x0 = _mm_xor_si128(
            _mm_xor_si128(_mm_clmulepi64_si128(x0, k3k4, 0x00), _mm_clmulepi64_si128(x0, k3k4, 0x11)),
            x1,
        );
        x0 = _mm_xor_si128(
            _mm_xor_si128(_mm_clmulepi64_si128(x0, k3k4, 0x00), _mm_clmulepi64_si128(x0, k3k4, 0x11)),
            x2,
        );
        x0 = _mm_xor_si128(
            _mm_xor_si128(_mm_clmulepi64_si128(x0, k3k4, 0x00), _mm_clmulepi64_si128(x0, k3k4, 0x11)),
            x3,
        );

        while pos + 16 <= data.len() {
            let y = _mm_loadu_si128(ptr.add(pos).cast());
            x0 = _mm_xor_si128(
                _mm_xor_si128(_mm_clmulepi64_si128(x0, k3k4, 0x00), _mm_clmulepi64_si128(x0, k3k4, 0x11)),
                y,
            );
            pos += 16;
        }

        let k4 = _mm_set_epi64x(0, 0x0cca_a009_ei64);
        let t0 = _mm_clmulepi64_si128(x0, k4, 0x00);
        x0 = _mm_xor_si128(_mm_srli_si128(x0, 8), t0);

        let k5 = _mm_set_epi64x(0, 0x163c_d612_4i64);
        let t1 = _mm_clmulepi64_si128(_mm_and_si128(x0, _mm_set_epi32(0, 0, 0, -1)), k5, 0x00);
        x0 = _mm_xor_si128(_mm_srli_si128(x0, 4), t1);

        let poly_mu = _mm_set_epi64x(0x1db7_1064_1i64, 0x1f70_1164_1i64);
        let mask32 = _mm_set_epi32(0, 0, 0, -1);
        let q = _mm_clmulepi64_si128(_mm_and_si128(x0, mask32), poly_mu, 0x00);
        let r = _mm_clmulepi64_si128(_mm_and_si128(q, mask32), poly_mu, 0x10);
        let crc = _mm_extract_epi32(_mm_xor_si128(x0, r), 1) as u32;

        if pos < data.len() {
            !crc32_slice4(crc, &data[pos..])
        } else {
            !crc
        }
    }
}

#[inline]
pub fn crc32_ieee(data: &[u8]) -> u32 {
    #[cfg(all(target_arch = "x86_64", target_feature = "pclmulqdq", target_feature = "sse4.1"))]
    {
        unsafe { crc32_pclmul(data) }
    }
    #[cfg(not(all(target_arch = "x86_64", target_feature = "pclmulqdq", target_feature = "sse4.1")))]
    {
        #[cfg(target_arch = "x86_64")]
        if data.len() >= 64 {
            use std::sync::atomic::{AtomicU8, Ordering};
            static HAS_PCLMUL: AtomicU8 = AtomicU8::new(0);
            let st = HAS_PCLMUL.load(Ordering::Relaxed);
            let ok = if st != 0 {
                st == 2
            } else {
                let d = std::is_x86_feature_detected!("pclmulqdq")
                    && std::is_x86_feature_detected!("sse4.1");
                HAS_PCLMUL.store(if d { 2 } else { 1 }, Ordering::Relaxed);
                d
            };
            if ok {
                return unsafe { crc32_pclmul(data) };
            }
        }
        !crc32_slice4(!0u32, data)
    }
}

const fn rev_bits(mut v: u16, n: u8) -> u16 {
    let mut r = 0u16;
    let mut i = 0;
    while i < n {
        r = (r << 1) | (v & 1);
        v >>= 1;
        i += 1;
    }
    r
}

const FIXED_LIT: [(u16, u8); 256] = {
    let mut t = [(0u16, 0u8); 256];
    let mut s = 0;
    while s < 144 {
        t[s] = (rev_bits(0x30 + s as u16, 8), 8);
        s += 1;
    }
    while s < 256 {
        t[s] = (rev_bits(0x190 + (s - 144) as u16, 9), 9);
        s += 1;
    }
    t
};

const FIXED_PAIR: [u32; 65536] = {
    let mut t = [0u32; 65536];
    let mut x = 0usize;
    while x < 256 {
        let (cx, lx) = FIXED_LIT[x];
        let mut y = 0usize;
        while y < 256 {
            let (cy, ly) = FIXED_LIT[y];
            let code = (cx as u32) | ((cy as u32) << lx);
            let len = (lx + ly) as u32;
            t[x | (y << 8)] = code | (len << 20) | ((lx as u32) << 26);
            y += 1;
        }
        x += 1;
    }
    t
};

const FIXED_LEN: [(u16, u8); 259] = {
    const BASE: [u16; 29] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115,
        131, 163, 195, 227, 258,
    ];
    const EXTRA: [u8; 29] = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ];
    let mut t = [(0u16, 0u8); 259];
    let mut l = 3usize;
    while l <= 258 {
        let mut idx = 0usize;
        while idx + 1 < 29 && (l as u16) >= BASE[idx + 1] {
            idx += 1;
        }
        let sym = 257 + idx;
        let (hcode, hbits) = if sym <= 279 {
            (rev_bits((sym - 256) as u16, 7), 7u8)
        } else {
            (rev_bits((0xc0 + (sym - 280)) as u16, 8), 8u8)
        };
        let extra = (l as u16) - BASE[idx];
        let ebits = EXTRA[idx];
        t[l] = (hcode | (extra << hbits), hbits + ebits);
        l += 1;
    }
    t
};

const DIST_SYM_REV: [u16; 30] = {
    let mut t = [0u16; 30];
    let mut i = 0;
    while i < 30 {
        t[i] = rev_bits(i as u16, 5);
        i += 1;
    }
    t
};

#[inline(always)]
fn put_bits(dst: &mut Vec<u8>, bit_buf: &mut u64, bit_cnt: &mut u32, bits: u64, nbits: u8) {
    *bit_buf |= bits << *bit_cnt;
    *bit_cnt += nbits as u32;
    if *bit_cnt >= 32 {
        dst.extend_from_slice(&(*bit_buf as u32).to_le_bytes());
        *bit_buf >>= 32;
        *bit_cnt -= 32;
    }
}

#[inline(always)]
fn emit_literal_run(
    src: &[u8],
    mut pos: usize,
    end: usize,
    dst: &mut Vec<u8>,
    bit_buf: &mut u64,
    bit_cnt: &mut u32,
) {
    while pos + 2 <= end {
        let p0 = u16::from_le_bytes([src[pos], src[pos + 1]]) as usize;
        let e0 = FIXED_PAIR[p0];
        put_bits(
            dst,
            bit_buf,
            bit_cnt,
            (e0 & 0x3ffff) as u64,
            ((e0 >> 20) & 0x3f) as u8,
        );
        pos += 2;
    }
    if pos < end {
        let (lit_c, lit_b) = FIXED_LIT[src[pos] as usize];
        put_bits(dst, bit_buf, bit_cnt, lit_c as u64, lit_b);
    }
}

#[derive(Default, Clone, Copy)]
pub struct HwBuildHasher;

pub struct HwHasher(u64);

impl std::hash::BuildHasher for HwBuildHasher {
    type Hasher = HwHasher;

    #[inline(always)]
    fn build_hasher(&self) -> HwHasher {
        HwHasher(0x517c_c1b7_2722_0a95)
    }
}

impl std::hash::Hasher for HwHasher {
    #[inline(always)]
    fn finish(&self) -> u64 {
        let mut x = self.0.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        x = (x ^ (x >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        x ^ (x >> 27)
    }

    #[inline(always)]
    fn write(&mut self, bytes: &[u8]) {
        let mut h = self.0;
        let mut i = 0;
        #[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
        unsafe {
            use std::arch::x86_64::*;
            while i + 8 <= bytes.len() {
                let w = u64::from_ne_bytes(bytes[i..i + 8].try_into().unwrap());
                h = _mm_crc32_u64(h, w);
                i += 8;
            }
            if i + 4 <= bytes.len() {
                let w = u32::from_ne_bytes(bytes[i..i + 4].try_into().unwrap());
                h = _mm_crc32_u32(h as u32, w) as u64;
                i += 4;
            }
            while i < bytes.len() {
                h = _mm_crc32_u8(h as u32, bytes[i]) as u64;
                i += 1;
            }
            self.0 = h;
            return;
        }
        #[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
        {
            while i + 8 <= bytes.len() {
                let w = u64::from_ne_bytes(bytes[i..i + 8].try_into().unwrap());
                h = (h ^ w).wrapping_mul(0x9E37_79B9_7F4A_7C15);
                i += 8;
            }
            while i < bytes.len() {
                h = (h ^ (bytes[i] as u64)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
                i += 1;
            }
            self.0 = h;
        }
    }

    #[inline(always)]
    fn write_u8(&mut self, v: u8) {
        #[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
        unsafe {
            self.0 = std::arch::x86_64::_mm_crc32_u8(self.0 as u32, v) as u64;
            return;
        }
        #[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
        {
            self.0 = (self.0 ^ (v as u64)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }

    #[inline(always)]
    fn write_i8(&mut self, v: i8) {
        self.write_u8(v as u8);
    }

    #[inline(always)]
    fn write_u16(&mut self, v: u16) {
        #[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
        unsafe {
            self.0 = std::arch::x86_64::_mm_crc32_u16(self.0 as u32, v) as u64;
            return;
        }
        #[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
        {
            self.0 = (self.0 ^ (v as u64)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }

    #[inline(always)]
    fn write_i16(&mut self, v: i16) {
        self.write_u16(v as u16);
    }

    #[inline(always)]
    fn write_i32(&mut self, v: i32) {
        self.write_u32(v as u32);
    }

    #[inline(always)]
    fn write_u32(&mut self, v: u32) {
        #[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
        unsafe {
            self.0 = std::arch::x86_64::_mm_crc32_u32(self.0 as u32, v) as u64;
            return;
        }
        #[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
        {
            self.0 = (self.0 ^ (v as u64)).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }

    #[inline(always)]
    fn write_i64(&mut self, v: i64) {
        self.write_u64(v as u64);
    }

    #[inline(always)]
    fn write_u64(&mut self, v: u64) {
        #[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
        unsafe {
            self.0 = std::arch::x86_64::_mm_crc32_u64(self.0, v);
            return;
        }
        #[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
        {
            self.0 = (self.0 ^ v).wrapping_mul(0x9E37_79B9_7F4A_7C15);
        }
    }

    #[inline(always)]
    fn write_usize(&mut self, v: usize) {
        self.write_u64(v as u64);
    }

    #[inline(always)]
    fn write_isize(&mut self, v: isize) {
        self.write_u64(v as u64);
    }
}

#[inline(always)]
fn hash4(v: u32) -> usize {
    #[cfg(all(target_arch = "x86_64", target_feature = "sse4.2"))]
    unsafe {
        return (std::arch::x86_64::_mm_crc32_u32(0, v) as usize) & 0xfff;
    }
    #[cfg(not(all(target_arch = "x86_64", target_feature = "sse4.2")))]
    {
        (v.wrapping_mul(0x9E37_79B1) >> 20) as usize
    }
}

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "avx2")]
unsafe fn match_len_at_avx2(src: &[u8], ip: usize, cand: usize, max_ml: usize) -> usize {
    unsafe {
        use std::arch::x86_64::*;
        let mut m = 4usize;
        while m + 32 <= max_ml {
            let va = _mm256_loadu_si256(src.as_ptr().add(ip + m).cast());
            let vb = _mm256_loadu_si256(src.as_ptr().add(cand + m).cast());
            let eq = _mm256_movemask_epi8(_mm256_cmpeq_epi8(va, vb)) as u32;
            if eq != 0xffff_ffff {
                m += (!eq).trailing_zeros() as usize;
                return m.min(max_ml);
            }
            m += 32;
        }
        while m + 8 <= max_ml {
            let a = u64::from_le_bytes(src[ip + m..ip + m + 8].try_into().unwrap());
            let b = u64::from_le_bytes(src[cand + m..cand + m + 8].try_into().unwrap());
            let d = a ^ b;
            if d != 0 {
                m += (d.trailing_zeros() >> 3) as usize;
                return m.min(max_ml);
            }
            m += 8;
        }
        while m < max_ml && src[ip + m] == src[cand + m] {
            m += 1;
        }
        m
    }
}

#[inline(always)]
fn match_len_at(src: &[u8], ip: usize, cand: usize, max_ml: usize) -> usize {
    #[cfg(target_arch = "x86_64")]
    if max_ml >= 36 && has_avx2() {
        return unsafe { match_len_at_avx2(src, ip, cand, max_ml) };
    }
    let mut m = 4usize;
    while m + 8 <= max_ml {
        let a = u64::from_le_bytes(src[ip + m..ip + m + 8].try_into().unwrap());
        let b = u64::from_le_bytes(src[cand + m..cand + m + 8].try_into().unwrap());
        let d = a ^ b;
        if d != 0 {
            m += (d.trailing_zeros() >> 3) as usize;
            return m.min(max_ml);
        }
        m += 8;
    }
    while m < max_ml && src[ip + m] == src[cand + m] {
        m += 1;
    }
    m
}

#[inline(always)]
fn resolve_cand(ip: usize, raw: u16, len: usize) -> Option<usize> {
    if raw == 0 {
        return None;
    }
    let base_hi = ip & !0xffff;
    let mut cand = base_hi | (raw.wrapping_sub(1) as usize);
    if cand >= ip && cand >= 0x10000 {
        cand -= 0x10000;
    }
    if cand < ip && ip - cand <= 32768 && cand + 4 <= len {
        Some(cand)
    } else {
        None
    }
}

pub fn gzip_compress_fast(src: &[u8], dst: &mut Vec<u8>) {
    dst.clear();
    dst.reserve((src.len() >> 1) + 64);
    dst.extend_from_slice(&[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x03]);

    let len = src.len();
    let mut bit_buf: u64 = 0b011;
    let mut bit_cnt: u32 = 3;
    let mut htab = [0u32; 4096];

    let mut ip = 0usize;
    let mut lit_start = 0usize;

    while ip + 8 <= len {
        let cur4 = u32::from_le_bytes(src[ip..ip + 4].try_into().unwrap());
        let h = hash4(cur4);
        let pair = htab[h];
        let raw0 = pair as u16;
        let raw1 = (pair >> 16) as u16;
        let ip_tag = (ip as u16).wrapping_add(1);
        htab[h] = ((raw0 as u32) << 16) | (ip_tag as u32);

        let max_ml = (len - ip).min(258);
        let mut best_cand = 0usize;
        let mut best_ml = 0usize;

        if let Some(c0) = resolve_cand(ip, raw0, len) {
            if u32::from_le_bytes(src[c0..c0 + 4].try_into().unwrap()) == cur4 {
                best_cand = c0;
                best_ml = match_len_at(src, ip, c0, max_ml);
            }
        }
        if best_ml < 32 {
            if let Some(c1) = resolve_cand(ip, raw1, len) {
                if u32::from_le_bytes(src[c1..c1 + 4].try_into().unwrap()) == cur4 {
                    let ml1 = match_len_at(src, ip, c1, max_ml);
                    if ml1 > best_ml + 1 {
                        best_cand = c1;
                        best_ml = ml1;
                    }
                }
            }
        }

        if best_ml >= 4 && (best_ml >= 5 || ip - best_cand <= 4096) {
            if lit_start < ip {
                emit_literal_run(src, lit_start, ip, dst, &mut bit_buf, &mut bit_cnt);
            }

            let dist = ip - best_cand;
            let (dcode, dbits) = if dist <= 4 {
                (DIST_SYM_REV[dist - 1] as u64, 5u8)
            } else {
                let d = (dist - 1) as u32;
                let msb = 31 - d.leading_zeros();
                let eb = msb - 1;
                let sym = ((msb << 1) + ((d >> eb) & 1)) as usize;
                let extra = d & ((1u32 << eb) - 1);
                (
                    (DIST_SYM_REV[sym] as u64) | ((extra as u64) << 5),
                    (5 + eb) as u8,
                )
            };

            let mut probe = ip;
            let mut ml = best_ml;
            loop {
                let (lcode, lbits) = FIXED_LEN[ml];
                let combined = (lcode as u64) | (dcode << lbits);
                let clen = lbits + dbits;
                bit_buf |= combined << bit_cnt;
                bit_cnt += clen as u32;
                if bit_cnt >= 32 {
                    dst.extend_from_slice(&(bit_buf as u32).to_le_bytes());
                    bit_buf >>= 32;
                    bit_cnt -= 32;
                }

                let next_ip = probe + ml;
                let idx_limit = next_ip.min(len.saturating_sub(4));
                let mut k = probe + 2;
                let step_k = if ml > 64 { 4 } else { 2 };
                while k < idx_limit {
                    let w4 = u32::from_le_bytes(src[k..k + 4].try_into().unwrap());
                    let hk = hash4(w4);
                    let pk = htab[hk];
                    let kt = (k as u16).wrapping_add(1);
                    htab[hk] = ((pk & 0xffff) << 16) | (kt as u32);
                    k += step_k;
                }

                ip = next_ip;
                lit_start = ip;
                if ml == 258 && ip + 8 <= len {
                    let c_next = ip - dist;
                    if u32::from_le_bytes(src[ip..ip + 4].try_into().unwrap())
                        == u32::from_le_bytes(src[c_next..c_next + 4].try_into().unwrap())
                    {
                        probe = ip;
                        ml = match_len_at(src, ip, c_next, (len - ip).min(258));
                        continue;
                    }
                }
                break;
            }
            continue;
        }

        ip += 1 + ((ip - lit_start) >> 7);
    }

    if lit_start < len {
        emit_literal_run(src, lit_start, len, dst, &mut bit_buf, &mut bit_cnt);
    }
    put_bits(dst, &mut bit_buf, &mut bit_cnt, 0, 7);
    while bit_cnt > 0 {
        dst.push(bit_buf as u8);
        bit_buf >>= 8;
        bit_cnt = bit_cnt.saturating_sub(8);
    }

    let crc = crc32_ieee(src);
    dst.extend_from_slice(&crc.to_le_bytes());
    dst.extend_from_slice(&(len as u32).to_le_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamp_formatting() {
        let mut buf = Vec::new();
        write_timestamp(&mut buf, 0);
        assert_eq!(buf, b"\"2000-01-01T00:00:00.000Z\"");

        buf.clear();
        let us = (1_743_508_800i64 * 1_000_000 + 123_999) - 946_684_800_000_000;
        write_timestamp(&mut buf, us);
        assert_eq!(buf, b"\"2025-04-01T12:00:00.123Z\"");

        buf.clear();
        write_timestamp(&mut buf, -1);
        assert_eq!(buf, b"\"1999-12-31T23:59:59.999Z\"");
    }

    #[test]
    fn string_escaping() {
        let mut buf = Vec::new();
        write_str(&mut buf, b"a\"b\\c\n\x01\xc3\xa9");
        assert_eq!(buf, b"\"a\\\"b\\\\c\\n\\u0001\xc3\xa9\"");
    }

    #[test]
    fn integer_and_b64_codecs() {
        let mut buf = Vec::new();
        write_i64(&mut buf, -9876543210);
        assert_eq!(buf, b"-9876543210");

        let mut u = String::new();
        let raw = b"hello world!?>>>";
        b64url_encode_append(raw, &mut u);
        let mut dec = [0u8; 32];
        let n = b64url_decode_slice(u.as_bytes(), &mut dec).unwrap();
        assert_eq!(&dec[..n], raw);

        let std_s = b64std_encode(raw);
        assert_eq!(b64std_decode(&std_s).unwrap(), raw);
    }

    #[test]
    fn json_parser_compliance() {
        let j = br#"{"user":{"username":"a\"b\u0041","bio":null,"n":-12.5e2,"tags":["x","y"]}}"#;
        let v = parse_json(j).unwrap();
        let u = v.get("user").unwrap();
        assert_eq!(u.get("username").unwrap().as_str(), Some("a\"bA"));
        assert_eq!(u.get("bio"), Some(&JsonVal::Null));
        assert_eq!(u.get("n").unwrap().as_f64(), Some(-1250.0));
        assert!(parse_json(br#"{"unclosed": 1"#).is_none());
        assert!(parse_json(br#"{"bad_num": 01}"#).is_none());
    }

    #[test]
    fn gzip_and_crc32_compliance() {
        assert_eq!(crc32_ieee(b"123456789"), 0xCBF4_3926);
        let mut sample = Vec::with_capacity(2048);
        for i in 0..2048u32 {
            sample.push((i.wrapping_mul(1664525).wrapping_add(1013904223) >> 24) as u8);
            let exp = !crc32_slice4(!0u32, &sample);
            assert_eq!(crc32_ieee(&sample), exp);
        }
        assert!(contains_gzip_token(b"gzip"));
        assert!(contains_gzip_token(b"deflate, gzip;q=0.9, br"));
        assert!(!contains_gzip_token(b"gzip;q=0"));
        assert!(!contains_gzip_token(b"br, deflate"));

        for count in [8usize, 40usize] {
            let mut payload = Vec::new();
            for i in 0..count {
                payload.extend_from_slice(br#"{"slug":"how-to-train-your-dragon-"#);
                write_i64(&mut payload, i as i64);
                payload.extend_from_slice("\",\"title\":\"How to train your dragon\",\"description\":\"Conformance comment <b>&</b> \\\"quoted\\\" ünïcode 🚀\",\"tagList\":[\"dragons\",\"training\"],\"createdAt\":\"2026-01-01T00:00:00.000Z\",\"updatedAt\":\"2026-01-01T00:00:00.000Z\",\"favorited\":false,\"favoritesCount\":42,\"author\":{\"username\":\"jake\",\"bio\":null,\"image\":null,\"following\":false}},".as_bytes());
            }
            let mut gz = Vec::new();
            gzip_compress_fast(&payload, &mut gz);
            assert!(gz.len() * 2 < payload.len());
            let mut child = std::process::Command::new("gzip")
                .arg("-dc")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .spawn()
                .unwrap();
            use std::io::Write;
            child.stdin.as_mut().unwrap().write_all(&gz).unwrap();
            let out = child.wait_with_output().unwrap();
            assert!(out.status.success());
            assert_eq!(out.stdout, payload);
        }

        let mut high_bytes = Vec::with_capacity(4096);
        for i in 0..4096u32 {
            high_bytes.push(144 + ((i.wrapping_mul(1103515245).wrapping_add(12345) >> 16) % 112) as u8);
        }
        let mut gz_hi = Vec::new();
        gzip_compress_fast(&high_bytes, &mut gz_hi);
        let mut child = std::process::Command::new("gzip")
            .arg("-dc")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write;
        child.stdin.as_mut().unwrap().write_all(&gz_hi).unwrap();
        let out = child.wait_with_output().unwrap();
        assert!(out.status.success());
        assert_eq!(out.stdout, high_bytes);
    }
}
