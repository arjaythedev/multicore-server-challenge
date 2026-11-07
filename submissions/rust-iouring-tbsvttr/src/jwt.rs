#![allow(dead_code)]

use crate::buf::put_int;
use crate::json;

const SHA256_INIT: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

#[inline(always)]
fn compress_words_scalar(state: &mut [u32; 8], w_in: &[u32; 16]) {
    let mut w = *w_in;
    let mut a = state[0];
    let mut b = state[1];
    let mut c = state[2];
    let mut d = state[3];
    let mut e = state[4];
    let mut f = state[5];
    let mut g = state[6];
    let mut h = state[7];

    for i in 0..64 {
        let wi = if i < 16 {
            w[i]
        } else {
            let w15 = w[(i - 15) & 15];
            let w2 = w[(i - 2) & 15];
            let s0 = w15.rotate_right(7) ^ w15.rotate_right(18) ^ (w15 >> 3);
            let s1 = w2.rotate_right(17) ^ w2.rotate_right(19) ^ (w2 >> 10);
            let v = w[i & 15]
                .wrapping_add(s0)
                .wrapping_add(w[(i - 7) & 15])
                .wrapping_add(s1);
            w[i & 15] = v;
            v
        };
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = (e & f) ^ ((!e) & g);
        let temp1 = h
            .wrapping_add(s1)
            .wrapping_add(ch)
            .wrapping_add(SHA256_K[i])
            .wrapping_add(wi);
        let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
        let maj = (a & b) ^ (a & c) ^ (b & c);
        let temp2 = s0.wrapping_add(maj);

        h = g;
        g = f;
        f = e;
        e = d.wrapping_add(temp1);
        d = c;
        c = b;
        b = a;
        a = temp1.wrapping_add(temp2);
    }

    state[0] = state[0].wrapping_add(a);
    state[1] = state[1].wrapping_add(b);
    state[2] = state[2].wrapping_add(c);
    state[3] = state[3].wrapping_add(d);
    state[4] = state[4].wrapping_add(e);
    state[5] = state[5].wrapping_add(f);
    state[6] = state[6].wrapping_add(g);
    state[7] = state[7].wrapping_add(h);
}

#[inline(always)]
fn compress_words(state: &mut [u32; 8], w: &[u32; 16]) {
    compress_words_scalar(state, w);
}

#[inline(always)]
fn sha256_compress(state: &mut [u32; 8], block: &[u8; 64]) {
    let mut w = [0u32; 16];
    for i in 0..16 {
        let j = i * 4;
        w[i] = u32::from_be_bytes([block[j], block[j + 1], block[j + 2], block[j + 3]]);
    }
    compress_words(state, &w);
}

#[derive(Clone, Copy)]
pub struct Sha256 {
    state: [u32; 8],
    buf: [u8; 64],
    buf_len: usize,
    total_len: u64,
}

impl Sha256 {
    #[inline]
    pub fn new() -> Self {
        Self {
            state: SHA256_INIT,
            buf: [0u8; 64],
            buf_len: 0,
            total_len: 0,
        }
    }

    #[inline]
    pub fn from_midstate(state: [u32; 8], total_len: u64) -> Self {
        Self {
            state,
            buf: [0u8; 64],
            buf_len: 0,
            total_len,
        }
    }

    #[inline]
    pub fn update(&mut self, mut data: &[u8]) {
        self.total_len += data.len() as u64;
        if self.buf_len > 0 {
            let need = 64 - self.buf_len;
            if data.len() < need {
                self.buf[self.buf_len..self.buf_len + data.len()].copy_from_slice(data);
                self.buf_len += data.len();
                return;
            }
            self.buf[self.buf_len..64].copy_from_slice(&data[..need]);
            let block = self.buf;
            sha256_compress(&mut self.state, &block);
            self.buf_len = 0;
            data = &data[need..];
        }
        while data.len() >= 64 {
            let block: &[u8; 64] = data[..64].try_into().unwrap();
            sha256_compress(&mut self.state, block);
            data = &data[64..];
        }
        if !data.is_empty() {
            self.buf[..data.len()].copy_from_slice(data);
            self.buf_len = data.len();
        }
    }

    #[inline]
    pub fn finalize_words(mut self) -> [u32; 8] {
        let bit_len = self.total_len * 8;
        self.buf[self.buf_len] = 0x80;
        self.buf_len += 1;
        if self.buf_len > 56 {
            self.buf[self.buf_len..64].fill(0);
            let block = self.buf;
            sha256_compress(&mut self.state, &block);
            self.buf_len = 0;
        }
        self.buf[self.buf_len..56].fill(0);
        self.buf[56..64].copy_from_slice(&bit_len.to_be_bytes());
        let block = self.buf;
        sha256_compress(&mut self.state, &block);
        self.state
    }

    #[inline]
    pub fn finalize(self) -> [u8; 32] {
        let state = self.finalize_words();
        let mut out = [0u8; 32];
        for (i, &w) in state.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&w.to_be_bytes());
        }
        out
    }
}

#[inline]
pub fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(data);
    h.finalize()
}

pub fn hmac_sha256(key: &[u8], data: &[u8]) -> [u8; 32] {
    let mut k_block = [0u8; 64];
    if key.len() > 64 {
        let kh = sha256(key);
        k_block[..32].copy_from_slice(&kh);
    } else {
        k_block[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_block[i];
        opad[i] ^= k_block[i];
    }
    let mut inner = Sha256::new();
    inner.update(&ipad);
    inner.update(data);
    let inner_words = inner.finalize_words();

    let mut outer_state = SHA256_INIT;
    sha256_compress(&mut outer_state, &opad);
    let outer_block: [u32; 16] = [
        inner_words[0],
        inner_words[1],
        inner_words[2],
        inner_words[3],
        inner_words[4],
        inner_words[5],
        inner_words[6],
        inner_words[7],
        0x8000_0000,
        0,
        0,
        0,
        0,
        0,
        0,
        768,
    ];
    compress_words(&mut outer_state, &outer_block);
    let mut out = [0u8; 32];
    for (i, &w) in outer_state.iter().enumerate() {
        out[i * 4..i * 4 + 4].copy_from_slice(&w.to_be_bytes());
    }
    out
}

pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut salt_blk = Vec::with_capacity(salt.len() + 4);
    salt_blk.extend_from_slice(salt);
    salt_blk.extend_from_slice(&1u32.to_be_bytes());
    let mut u = hmac_sha256(password, &salt_blk);
    let mut out = u;
    for _ in 1..iterations {
        u = hmac_sha256(password, &u);
        for i in 0..32 {
            out[i] ^= u[i];
        }
    }
    out
}

#[inline]
pub fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..a.len() {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

const B64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const B64STD: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

const B64URL_DEC: [i8; 256] = {
    let mut t = [-1i8; 256];
    let mut i = 0usize;
    while i < 26 {
        t[b'A' as usize + i] = i as i8;
        t[b'a' as usize + i] = (i + 26) as i8;
        i += 1;
    }
    let mut d = 0usize;
    while d < 10 {
        t[b'0' as usize + d] = (d + 52) as i8;
        d += 1;
    }
    t[b'-' as usize] = 62;
    t[b'_' as usize] = 63;
    t
};

#[inline(always)]
fn b64url_encode_32(mac: &[u8; 32], out: &mut [u8; 43]) {
    let mut i = 0usize;
    let mut o = 0usize;
    while i < 30 {
        let v = ((mac[i] as u32) << 16) | ((mac[i + 1] as u32) << 8) | (mac[i + 2] as u32);
        out[o] = B64URL[((v >> 18) & 63) as usize];
        out[o + 1] = B64URL[((v >> 12) & 63) as usize];
        out[o + 2] = B64URL[((v >> 6) & 63) as usize];
        out[o + 3] = B64URL[(v & 63) as usize];
        i += 3;
        o += 4;
    }
    let v = ((mac[30] as u32) << 16) | ((mac[31] as u32) << 8);
    out[40] = B64URL[((v >> 18) & 63) as usize];
    out[41] = B64URL[((v >> 12) & 63) as usize];
    out[42] = B64URL[((v >> 6) & 63) as usize];
}

pub fn b64url_encode(p: &[u8], out: &mut Vec<u8>) {
    out.reserve((p.len() * 4) / 3 + 4);
    let mut i = 0usize;
    while i + 3 <= p.len() {
        let v = ((p[i] as u32) << 16) | ((p[i + 1] as u32) << 8) | (p[i + 2] as u32);
        out.push(B64URL[((v >> 18) & 63) as usize]);
        out.push(B64URL[((v >> 12) & 63) as usize]);
        out.push(B64URL[((v >> 6) & 63) as usize]);
        out.push(B64URL[(v & 63) as usize]);
        i += 3;
    }
    let rem = p.len() - i;
    if rem == 1 {
        let v = (p[i] as u32) << 16;
        out.push(B64URL[((v >> 18) & 63) as usize]);
        out.push(B64URL[((v >> 12) & 63) as usize]);
    } else if rem == 2 {
        let v = ((p[i] as u32) << 16) | ((p[i + 1] as u32) << 8);
        out.push(B64URL[((v >> 18) & 63) as usize]);
        out.push(B64URL[((v >> 12) & 63) as usize]);
        out.push(B64URL[((v >> 6) & 63) as usize]);
    }
}

#[inline(always)]
fn b64url_val(c: u8) -> i32 {
    B64URL_DEC[c as usize] as i32
}

#[inline]
pub fn b64url_decode_slice(p: &[u8], out: &mut [u8]) -> Option<usize> {
    let n = p.len();
    if n % 4 == 1 {
        return None;
    }
    let need = (n / 4) * 3
        + match n % 4 {
            2 => 1,
            3 => 2,
            _ => 0,
        };
    if need > out.len() {
        return None;
    }
    let mut i = 0usize;
    let mut o = 0usize;
    while i + 4 <= n {
        let a = b64url_val(p[i]);
        let b = b64url_val(p[i + 1]);
        let c = b64url_val(p[i + 2]);
        let d = b64url_val(p[i + 3]);
        if (a | b | c | d) < 0 {
            return None;
        }
        let v = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6) | (d as u32);
        out[o] = ((v >> 16) & 0xFF) as u8;
        out[o + 1] = ((v >> 8) & 0xFF) as u8;
        out[o + 2] = (v & 0xFF) as u8;
        i += 4;
        o += 3;
    }
    let rem = n - i;
    if rem == 2 {
        let a = b64url_val(p[i]);
        let b = b64url_val(p[i + 1]);
        if (a | b) < 0 {
            return None;
        }
        out[o] = (((a << 2) | (b >> 4)) & 0xFF) as u8;
        o += 1;
    } else if rem == 3 {
        let a = b64url_val(p[i]);
        let b = b64url_val(p[i + 1]);
        let c = b64url_val(p[i + 2]);
        if (a | b | c) < 0 {
            return None;
        }
        let v = ((a as u32) << 12) | ((b as u32) << 6) | (c as u32);
        out[o] = ((v >> 10) & 0xFF) as u8;
        out[o + 1] = ((v >> 2) & 0xFF) as u8;
        o += 2;
    }
    Some(o)
}

pub fn b64url_decode(p: &[u8], out: &mut Vec<u8>) -> bool {
    out.clear();
    let n = p.len();
    if n % 4 == 1 {
        return false;
    }
    let need = (n / 4) * 3
        + match n % 4 {
            2 => 1,
            3 => 2,
            _ => 0,
        };
    out.resize(need, 0);
    if b64url_decode_slice(p, out).is_some() {
        true
    } else {
        out.clear();
        false
    }
}

pub fn b64std_encode(p: &[u8]) -> String {
    let mut out = Vec::with_capacity(((p.len() + 2) / 3) * 4);
    let mut i = 0usize;
    while i + 3 <= p.len() {
        let v = ((p[i] as u32) << 16) | ((p[i + 1] as u32) << 8) | (p[i + 2] as u32);
        out.push(B64STD[((v >> 18) & 63) as usize]);
        out.push(B64STD[((v >> 12) & 63) as usize]);
        out.push(B64STD[((v >> 6) & 63) as usize]);
        out.push(B64STD[(v & 63) as usize]);
        i += 3;
    }
    let rem = p.len() - i;
    if rem == 1 {
        let v = (p[i] as u32) << 16;
        out.push(B64STD[((v >> 18) & 63) as usize]);
        out.push(B64STD[((v >> 12) & 63) as usize]);
        out.push(b'=');
        out.push(b'=');
    } else if rem == 2 {
        let v = ((p[i] as u32) << 16) | ((p[i + 1] as u32) << 8);
        out.push(B64STD[((v >> 18) & 63) as usize]);
        out.push(B64STD[((v >> 12) & 63) as usize]);
        out.push(B64STD[((v >> 6) & 63) as usize]);
        out.push(b'=');
    }
    unsafe { String::from_utf8_unchecked(out) }
}

pub fn fill_scram_nonce() -> String {
    let mut raw = [0u8; 18];
    let _ = crate::sys::fill_random(&mut raw);
    b64std_encode(&raw)
}

pub fn b64std_decode(mut p: &[u8]) -> Option<Vec<u8>> {
    while !p.is_empty() && p[p.len() - 1] == b'=' {
        p = &p[..p.len() - 1];
    }
    let mut out = Vec::with_capacity((p.len() * 3) / 4 + 3);
    let val = |c: u8| -> i32 {
        match c {
            b'A'..=b'Z' => (c - b'A') as i32,
            b'a'..=b'z' => (c - b'a' + 26) as i32,
            b'0'..=b'9' => (c - b'0' + 52) as i32,
            b'+' => 62,
            b'/' => 63,
            _ => -1,
        }
    };
    let n = p.len();
    if n % 4 == 1 {
        return None;
    }
    let mut i = 0usize;
    while i + 4 <= n {
        let a = val(p[i]);
        let b = val(p[i + 1]);
        let c = val(p[i + 2]);
        let d = val(p[i + 3]);
        if (a | b | c | d) < 0 {
            return None;
        }
        let v = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6) | (d as u32);
        out.push(((v >> 16) & 0xFF) as u8);
        out.push(((v >> 8) & 0xFF) as u8);
        out.push((v & 0xFF) as u8);
        i += 4;
    }
    let rem = n - i;
    if rem == 2 {
        let a = val(p[i]);
        let b = val(p[i + 1]);
        if (a | b) < 0 {
            return None;
        }
        out.push((((a << 2) | (b >> 4)) & 0xFF) as u8);
    } else if rem == 3 {
        let a = val(p[i]);
        let b = val(p[i + 1]);
        let c = val(p[i + 2]);
        if (a | b | c) < 0 {
            return None;
        }
        let v = ((a as u32) << 12) | ((b as u32) << 6) | (c as u32);
        out.push(((v >> 10) & 0xFF) as u8);
        out.push(((v >> 2) & 0xFF) as u8);
    }
    Some(out)
}

#[derive(Clone, Copy)]
pub struct JwtKey {
    ipad_state: [u32; 8],
    opad_state: [u32; 8],
}

impl JwtKey {
    pub fn new(secret: &[u8]) -> Self {
        let mut k_block = [0u8; 64];
        if secret.len() > 64 {
            let kh = sha256(secret);
            k_block[..32].copy_from_slice(&kh);
        } else {
            k_block[..secret.len()].copy_from_slice(secret);
        }
        let mut ipad = [0x36u8; 64];
        let mut opad = [0x5cu8; 64];
        for i in 0..64 {
            ipad[i] ^= k_block[i];
            opad[i] ^= k_block[i];
        }
        let mut ipad_state = SHA256_INIT;
        sha256_compress(&mut ipad_state, &ipad);
        let mut opad_state = SHA256_INIT;
        sha256_compress(&mut opad_state, &opad);
        Self {
            ipad_state,
            opad_state,
        }
    }

    #[inline]
    pub fn mac(&self, data: &[u8]) -> [u8; 32] {
        let mut inner = Sha256::from_midstate(self.ipad_state, 64);
        inner.update(data);
        let inner_words = inner.finalize_words();

        let mut outer_state = self.opad_state;
        let outer_block: [u32; 16] = [
            inner_words[0],
            inner_words[1],
            inner_words[2],
            inner_words[3],
            inner_words[4],
            inner_words[5],
            inner_words[6],
            inner_words[7],
            0x8000_0000,
            0,
            0,
            0,
            0,
            0,
            0,
            768,
        ];
        compress_words(&mut outer_state, &outer_block);
        let mut out = [0u8; 32];
        for (i, &w) in outer_state.iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&w.to_be_bytes());
        }
        out
    }

    #[inline]
    pub fn sign(&self, id: i64, now: i64, out: &mut Vec<u8>) {
        sign(id, now, self, out);
    }

    #[inline]
    pub fn verify(&self, token: &[u8], now: i64) -> i64 {
        verify(token, now, self)
    }

    #[inline]
    pub fn verify_with_exp(&self, token: &[u8], now: i64) -> (i64, i64) {
        verify_with_exp(token, now, self)
    }
}

const HEADER: &[u8] = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

pub fn sign(id: i64, now: i64, key: &JwtKey, out: &mut Vec<u8>) {
    let mut payload = Vec::with_capacity(64);
    payload.extend_from_slice(b"{\"sub\":\"");
    put_int(&mut payload, id);
    payload.extend_from_slice(b"\",\"iat\":");
    put_int(&mut payload, now);
    payload.extend_from_slice(b",\"exp\":");
    put_int(&mut payload, now + 2_592_000);
    payload.push(b'}');

    let start = out.len();
    out.extend_from_slice(HEADER);
    out.push(b'.');
    b64url_encode(&payload, out);
    let mac = key.mac(&out[start..]);
    out.push(b'.');
    let mut mac_text = [0u8; 43];
    b64url_encode_32(&mac, &mut mac_text);
    out.extend_from_slice(&mac_text);
}

/// Parses a positive integer `1..=2^53` as plain ASCII digits (user IDs in tokens, comment IDs in paths), or `-1`.
#[inline]
pub fn parse_id(p: &[u8]) -> i64 {
    if p.is_empty() || p.len() > 16 {
        return -1;
    }
    let mut v = 0i64;
    for &c in p {
        if !c.is_ascii_digit() {
            return -1;
        }
        v = v * 10 + (c - b'0') as i64;
    }
    if !(1..=9_007_199_254_740_992).contains(&v) {
        return -1;
    }
    v
}

/// Zero-allocation fast-path claim scanner for flat JWT payloads such as `{"sub":"42","iat":1750000000,"exp":1752592000}`.
/// Returns `Some((sub_id, exp))` if the payload is a flat object with valid integer `exp` (and optional `nbf`/`iat`)
/// and valid `sub`, or `None` if fallback full JSON parsing is needed.
#[inline]
fn scan_flat_claims(pay: &[u8]) -> Option<(i64, i64, Option<i64>)> {
    let n = pay.len();
    let mut i = 0usize;
    while i < n && matches!(pay[i], b' ' | b'\t' | b'\r' | b'\n') {
        i += 1;
    }
    if i >= n || pay[i] != b'{' {
        return None;
    }
    i += 1;
    let mut sub_id: Option<i64> = None;
    let mut exp_val: Option<i64> = None;
    let mut nbf_val: Option<i64> = None;

    loop {
        while i < n && matches!(pay[i], b' ' | b'\t' | b'\r' | b'\n') {
            i += 1;
        }
        if i >= n || pay[i] != b'"' {
            return None;
        }
        i += 1;
        let ks = i;
        while i < n && pay[i] != b'"' {
            if pay[i] == b'\\' || pay[i] < 0x20 {
                return None;
            }
            i += 1;
        }
        if i >= n {
            return None;
        }
        let key = &pay[ks..i];
        i += 1;
        while i < n && matches!(pay[i], b' ' | b'\t' | b'\r' | b'\n') {
            i += 1;
        }
        if i >= n || pay[i] != b':' {
            return None;
        }
        i += 1;
        while i < n && matches!(pay[i], b' ' | b'\t' | b'\r' | b'\n') {
            i += 1;
        }
        if i >= n {
            return None;
        }

        if key == b"sub" {
            if pay[i] != b'"' {
                return None;
            }
            i += 1;
            let vs = i;
            while i < n && pay[i] != b'"' {
                if pay[i] == b'\\' || pay[i] < 0x20 {
                    return None;
                }
                i += 1;
            }
            if i >= n {
                return None;
            }
            sub_id = Some(parse_id(&pay[vs..i]));
            i += 1;
        } else if key == b"exp" || key == b"nbf" || key == b"iat" {
            if !pay[i].is_ascii_digit() {
                return None;
            }
            if pay[i] == b'0' && i + 1 < n && pay[i + 1].is_ascii_digit() {
                return None;
            }
            let mut v = 0i64;
            let mut digits = 0usize;
            while i < n && pay[i].is_ascii_digit() {
                v = v.checked_mul(10)?.checked_add((pay[i] - b'0') as i64)?;
                i += 1;
                digits += 1;
            }
            if digits == 0 || (i < n && matches!(pay[i], b'.' | b'e' | b'E')) {
                return None;
            }
            if key == b"exp" {
                exp_val = Some(v);
            } else if key == b"nbf" {
                nbf_val = Some(v);
            }
        } else {
            return None;
        }

        while i < n && matches!(pay[i], b' ' | b'\t' | b'\r' | b'\n') {
            i += 1;
        }
        if i < n && pay[i] == b',' {
            i += 1;
        } else if i < n && pay[i] == b'}' {
            i += 1;
            break;
        } else {
            return None;
        }
    }
    while i < n && matches!(pay[i], b' ' | b'\t' | b'\r' | b'\n') {
        i += 1;
    }
    if i != n {
        return None;
    }
    Some((sub_id?, exp_val?, nbf_val))
}

/// Verifies an HS256 JWT and returns `(user_id, exp_secs)` if valid (`user_id > 0`), or `(-1, 0)` if invalid/expired.
pub fn verify_with_exp(token: &[u8], now: i64, key: &JwtKey) -> (i64, i64) {
    let n = token.len();
    if n == 0 || n > 4096 {
        return (-1, 0);
    }
    let mut d1: Option<usize> = None;
    let mut d2: Option<usize> = None;
    for (i, &b) in token.iter().enumerate() {
        if b == b'.' {
            if d1.is_none() {
                d1 = Some(i);
            } else if d2.is_none() {
                d2 = Some(i);
            } else {
                return (-1, 0);
            }
        }
    }
    let (Some(d1), Some(d2)) = (d1, d2) else {
        return (-1, 0);
    };
    if n - (d2 + 1) != 43 {
        return (-1, 0);
    }

    let mac = key.mac(&token[..d2]);
    let mut mac_text = [0u8; 43];
    b64url_encode_32(&mac, &mut mac_text);
    if !ct_eq(&mac_text, &token[d2 + 1..]) {
        return (-1, 0);
    }

    let hdr_b64 = &token[..d1];
    if hdr_b64 != HEADER
        && hdr_b64 != b"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9"
        && hdr_b64 != b"eyJhbGciOiJIUzI1NiJ9"
    {
        let mut hdr_buf = [0u8; 512];
        let Some(hlen) = b64url_decode_slice(hdr_b64, &mut hdr_buf) else {
            return (-1, 0);
        };
        let hdr = &hdr_buf[..hlen];
        if !json::valid(hdr) {
            return (-1, 0);
        }
        let Some((as_, ae)) = json::find(hdr, b"alg") else {
            return (-1, 0);
        };
        if &hdr[as_..ae] != b"\"HS256\"" {
            return (-1, 0);
        }
    }

    let pay_b64 = &token[d1 + 1..d2];
    let mut pay_stack = [0u8; 512];
    let mut pay_vec = Vec::new();
    let pay: &[u8] = if let Some(plen) = b64url_decode_slice(pay_b64, &mut pay_stack) {
        &pay_stack[..plen]
    } else if b64url_decode(pay_b64, &mut pay_vec) {
        &pay_vec
    } else {
        return (-1, 0);
    };

    if let Some((id, exp, nbf_opt)) = scan_flat_claims(pay) {
        if id <= 0 || exp <= now {
            return (-1, 0);
        }
        if let Some(nbf) = nbf_opt {
            if nbf > now {
                return (-1, 0);
            }
        }
        return (id, exp);
    }

    if !json::valid(pay) {
        return (-1, 0);
    }
    let now_f = now as f64;
    let Some((es, ee)) = json::find(pay, b"exp") else {
        return (-1, 0);
    };
    let Some(exp) = json::number(pay, es, ee) else {
        return (-1, 0);
    };
    if exp <= now_f {
        return (-1, 0);
    }
    if let Some((ns, ne)) = json::find(pay, b"nbf") {
        let Some(nbf) = json::number(pay, ns, ne) else {
            return (-1, 0);
        };
        if nbf > now_f {
            return (-1, 0);
        }
    }
    let Some((ss, se)) = json::find(pay, b"sub") else {
        return (-1, 0);
    };
    let mut sub_buf = Vec::with_capacity(24);
    if json::decode_string(pay, ss, se, &mut sub_buf).is_none() {
        return (-1, 0);
    }
    let id = parse_id(&sub_buf);
    if id <= 0 {
        return (-1, 0);
    }
    (id, exp.floor().clamp(0.0, i64::MAX as f64) as i64)
}

#[inline]
pub fn verify(token: &[u8], now: i64, key: &JwtKey) -> i64 {
    verify_with_exp(token, now, key).0
}
