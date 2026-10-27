const MASK_LO: u64 = 0x0101_0101_0101_0101;
const MASK_HI: u64 = 0x8080_8080_8080_8080;

const DEC_DIGITS_LUT: &[u8; 200] = b"\
0001020304050607080910111213141516171819\
2021222324252627282930313233343536373839\
4041424344454647484950515253545556575859\
6061626364656667686970717273747576777879\
8081828384858687888990919293949596979899";

#[inline(always)]
pub fn find_byte(haystack: &[u8], needle: u8) -> Option<usize> {
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

    let out: [u8; 26] = [
        b'"',
        b'0' + ((y / 1000) % 10) as u8,
        b'0' + ((y / 100) % 10) as u8,
        b'0' + ((y / 10) % 10) as u8,
        b'0' + (y % 10) as u8,
        b'-',
        b'0' + (month / 10) as u8,
        b'0' + (month % 10) as u8,
        b'-',
        b'0' + (day / 10) as u8,
        b'0' + (day % 10) as u8,
        b'T',
        b'0' + (hh / 10) as u8,
        b'0' + (hh % 10) as u8,
        b':',
        b'0' + (mm / 10) as u8,
        b'0' + (mm % 10) as u8,
        b':',
        b'0' + (ss / 10) as u8,
        b'0' + (ss % 10) as u8,
        b'.',
        b'0' + (millis / 100) as u8,
        b'0' + ((millis / 10) % 10) as u8,
        b'0' + (millis % 10) as u8,
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
        out.push(B64_URL_ENC[((n >> 18) & 0x3f) as usize]);
        out.push(B64_URL_ENC[((n >> 12) & 0x3f) as usize]);
        out.push(B64_URL_ENC[((n >> 6) & 0x3f) as usize]);
        out.push(B64_URL_ENC[(n & 0x3f) as usize]);
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
}
