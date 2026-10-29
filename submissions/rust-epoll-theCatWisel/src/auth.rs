use crate::codec::{self, JsonVal};

const SHA256_H0: [u32; 8] = [
    0x6a09_e667,
    0xbb67_ae85,
    0x3c6e_f372,
    0xa54f_f53a,
    0x510e_527f,
    0x9b05_688c,
    0x1f83_d9ab,
    0x5be0_cd19,
];

const SHA256_K: [u32; 64] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
];

#[cfg(target_arch = "x86_64")]
#[target_feature(enable = "sha,sse4.1,ssse3")]
unsafe fn compress_words_shani(state: &mut [u32; 8], w: [u32; 16]) {
    unsafe {
        use std::arch::x86_64::*;

        let s0 = _mm_loadu_si128(state.as_ptr().cast());
        let s1 = _mm_loadu_si128(state.as_ptr().add(4).cast());
        let tmp = _mm_shuffle_epi32(s0, 0xB1);
        let efgh = _mm_shuffle_epi32(s1, 0x1B);
        let mut abef = _mm_alignr_epi8(tmp, efgh, 8);
        let mut cdgh = _mm_blend_epi16(efgh, tmp, 0xF0);
        let abef_save = abef;
        let cdgh_save = cdgh;

        let load_w = |idx: usize| -> __m128i {
            _mm_set_epi32(
                w[idx + 3] as i32,
                w[idx + 2] as i32,
                w[idx + 1] as i32,
                w[idx] as i32,
            )
        };
        let load_k = |idx: usize| -> __m128i {
            _mm_loadu_si128(SHA256_K.as_ptr().add(idx).cast())
        };

        let mut m0 = load_w(0);
        let mut m1 = load_w(4);
        let mut m2 = load_w(8);
        let mut m3 = load_w(12);

        macro_rules! rnd4 {
            ($m_cur:ident, $k_idx:expr) => {{
                let wk = _mm_add_epi32($m_cur, load_k($k_idx));
                cdgh = _mm_sha256rnds2_epu32(cdgh, abef, wk);
                abef = _mm_sha256rnds2_epu32(abef, cdgh, _mm_shuffle_epi32(wk, 0x0E));
            }};
            ($m0:ident, $m1:ident, $m2:ident, $m3:ident, $k_idx:expr) => {{
                let wk = _mm_add_epi32($m0, load_k($k_idx));
                cdgh = _mm_sha256rnds2_epu32(cdgh, abef, wk);
                $m0 = _mm_sha256msg1_epu32($m0, $m1);
                abef = _mm_sha256rnds2_epu32(abef, cdgh, _mm_shuffle_epi32(wk, 0x0E));
                $m0 = _mm_add_epi32($m0, _mm_alignr_epi8($m3, $m2, 4));
                $m0 = _mm_sha256msg2_epu32($m0, $m3);
            }};
        }

        rnd4!(m0, m1, m2, m3, 0);
        rnd4!(m1, m2, m3, m0, 4);
        rnd4!(m2, m3, m0, m1, 8);
        rnd4!(m3, m0, m1, m2, 12);
        rnd4!(m0, m1, m2, m3, 16);
        rnd4!(m1, m2, m3, m0, 20);
        rnd4!(m2, m3, m0, m1, 24);
        rnd4!(m3, m0, m1, m2, 28);
        rnd4!(m0, m1, m2, m3, 32);
        rnd4!(m1, m2, m3, m0, 36);
        rnd4!(m2, m3, m0, m1, 40);
        rnd4!(m3, m0, m1, m2, 44);
        rnd4!(m0, 48);
        rnd4!(m1, 52);
        rnd4!(m2, 56);
        rnd4!(m3, 60);

        abef = _mm_add_epi32(abef, abef_save);
        cdgh = _mm_add_epi32(cdgh, cdgh_save);

        let feba = _mm_shuffle_epi32(abef, 0x1B);
        let dchg = _mm_shuffle_epi32(cdgh, 0xB1);
        let out0 = _mm_blend_epi16(feba, dchg, 0xF0);
        let out1 = _mm_alignr_epi8(dchg, feba, 8);
        _mm_storeu_si128(state.as_mut_ptr().cast(), out0);
        _mm_storeu_si128(state.as_mut_ptr().add(4).cast(), out1);
    }
}

#[inline(always)]
fn compress_words(state: &mut [u32; 8], w: [u32; 16]) {
    #[cfg(all(
        target_arch = "x86_64",
        target_feature = "sha",
        target_feature = "sse4.1",
        target_feature = "ssse3"
    ))]
    {
        unsafe { compress_words_shani(state, w) };
        return;
    }
    #[cfg(all(
        target_arch = "x86_64",
        not(all(
            target_feature = "sha",
            target_feature = "sse4.1",
            target_feature = "ssse3"
        ))
    ))]
    if std::is_x86_feature_detected!("sha")
        && std::is_x86_feature_detected!("sse4.1")
        && std::is_x86_feature_detected!("ssse3")
    {
        unsafe { compress_words_shani(state, w) };
        return;
    }
    #[cfg(not(all(
        target_arch = "x86_64",
        target_feature = "sha",
        target_feature = "sse4.1",
        target_feature = "ssse3"
    )))]
    compress_words_scalar(state, w);
}

#[cfg(not(all(
    target_arch = "x86_64",
    target_feature = "sha",
    target_feature = "sse4.1",
    target_feature = "ssse3"
)))]
#[inline(always)]
fn compress_words_scalar(state: &mut [u32; 8], mut w: [u32; 16]) {
    let mut a = state[0];
    let mut b = state[1];
    let mut c = state[2];
    let mut d = state[3];
    let mut e = state[4];
    let mut f = state[5];
    let mut g = state[6];
    let mut h = state[7];

    for i in 0..64 {
        if i >= 16 {
            let w15 = w[(i + 1) & 15];
            let w2 = w[(i + 14) & 15];
            let s0 = w15.rotate_right(7) ^ w15.rotate_right(18) ^ (w15 >> 3);
            let s1 = w2.rotate_right(17) ^ w2.rotate_right(19) ^ (w2 >> 10);
            w[i & 15] = w[i & 15]
                .wrapping_add(s0)
                .wrapping_add(w[(i + 9) & 15])
                .wrapping_add(s1);
        }
        let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
        let ch = (e & f) ^ ((!e) & g);
        let temp1 = h
            .wrapping_add(s1)
            .wrapping_add(ch)
            .wrapping_add(SHA256_K[i])
            .wrapping_add(w[i & 15]);
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
fn compress_block(state: &mut [u32; 8], block: &[u8; 64]) {
    let w: [u32; 16] = std::array::from_fn(|i| {
        u32::from_be_bytes([block[4 * i], block[4 * i + 1], block[4 * i + 2], block[4 * i + 3]])
    });
    compress_words(state, w);
}

#[inline]
fn sha256_with_state(mut state: [u32; 8], prior_bytes: u64, data: &[u8]) -> [u32; 8] {
    let mut chunks = data.chunks_exact(64);
    for chunk in &mut chunks {
        compress_block(&mut state, chunk.try_into().unwrap());
    }
    let rem = chunks.remainder();
    let total_bits = (prior_bytes + data.len() as u64) * 8;
    let mut tail = [0u8; 64];
    tail[..rem.len()].copy_from_slice(rem);
    tail[rem.len()] = 0x80;
    if rem.len() >= 56 {
        compress_block(&mut state, &tail);
        tail = [0u8; 64];
    }
    tail[56..64].copy_from_slice(&total_bits.to_be_bytes());
    compress_block(&mut state, &tail);
    state
}

#[inline(always)]
fn state_to_bytes(state: &[u32; 8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    for (i, &w) in state.iter().enumerate() {
        out[4 * i..4 * i + 4].copy_from_slice(&w.to_be_bytes());
    }
    out
}

pub fn sha256_digest(data: &[u8]) -> [u8; 32] {
    state_to_bytes(&sha256_with_state(SHA256_H0, 0, data))
}

pub fn hmac_sha256_oneshot(key: &[u8], data: &[u8]) -> [u8; 32] {
    TokenSigner::new(key).sign_bytes(data)
}

const JWT_HDR_STD: &[u8] = b"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
const JWT_HDR_ALT: &[u8] = b"eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9";
const JWT_HDR_MIN: &[u8] = b"eyJhbGciOiJIUzI1NiJ9";

// Precomputed SHA-256 ipad/opad midstates for the server JWT secret.
#[derive(Clone, Copy)]
pub struct TokenSigner {
    ipad_state: [u32; 8],
    opad_state: [u32; 8],
}

#[inline]
fn unix_now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[inline]
fn unix_now_f64() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

#[inline]
fn skip_ascii_ws(buf: &[u8], mut pos: usize) -> usize {
    while pos < buf.len() && matches!(buf[pos], b' ' | b'\t' | b'\r' | b'\n') {
        pos += 1;
    }
    pos
}

// Fast path for flat JWT payloads without escapes or nested values.
#[inline]
fn scan_flat_claims(buf: &[u8], now: f64) -> Option<Option<i64>> {
    if codec::find_byte(buf, b'\\').is_some() {
        return None;
    }
    let mut i = skip_ascii_ws(buf, 0);
    if i >= buf.len() || buf[i] != b'{' {
        return Some(None);
    }
    i = skip_ascii_ws(buf, i + 1);
    if i < buf.len() && buf[i] == b'}' {
        return Some(None);
    }

    let mut sub_uid: Option<i64> = None;
    let mut exp_ts: Option<f64> = None;
    let mut nbf_ts: Option<f64> = None;

    loop {
        if i >= buf.len() || buf[i] != b'"' {
            return None;
        }
        i += 1;
        let k0 = i;
        while i < buf.len() && buf[i] != b'"' {
            if buf[i] < 0x20 {
                return Some(None);
            }
            i += 1;
        }
        if i >= buf.len() {
            return Some(None);
        }
        let key = &buf[k0..i];
        i = skip_ascii_ws(buf, i + 1);
        if i >= buf.len() || buf[i] != b':' {
            return Some(None);
        }
        i = skip_ascii_ws(buf, i + 1);
        if i >= buf.len() {
            return Some(None);
        }

        match key {
            b"sub" => {
                if buf[i] != b'"' {
                    return Some(None);
                }
                i += 1;
                let v0 = i;
                let mut uid: i64 = 0;
                while i < buf.len() && buf[i] != b'"' {
                    let ch = buf[i];
                    if !ch.is_ascii_digit() {
                        return Some(None);
                    }
                    uid = uid.checked_mul(10)?.checked_add((ch - b'0') as i64)?;
                    i += 1;
                }
                if i >= buf.len() || i == v0 || uid <= 0 {
                    return Some(None);
                }
                i += 1;
                sub_uid = Some(uid);
            }
            b"exp" | b"nbf" | b"iat" => {
                let v0 = i;
                if buf[i] == b'-' {
                    i += 1;
                }
                let d0 = i;
                while i < buf.len() && buf[i].is_ascii_digit() {
                    i += 1;
                }
                if i == d0 {
                    return Some(None);
                }
                if i < buf.len() && matches!(buf[i], b'.' | b'e' | b'E') {
                    return None;
                }
                let num_str = std::str::from_utf8(&buf[v0..i]).ok()?;
                let val = num_str.parse::<i64>().ok()? as f64;
                if key == b"exp" {
                    exp_ts = Some(val);
                } else if key == b"nbf" {
                    nbf_ts = Some(val);
                }
            }
            _ => return None,
        }

        i = skip_ascii_ws(buf, i);
        if i >= buf.len() {
            return Some(None);
        }
        if buf[i] == b',' {
            i = skip_ascii_ws(buf, i + 1);
            continue;
        } else if buf[i] == b'}' {
            i = skip_ascii_ws(buf, i + 1);
            if i != buf.len() {
                return Some(None);
            }
            break;
        } else {
            return None;
        }
    }

    let Some(exp) = exp_ts else { return Some(None) };
    if !(now < exp) {
        return Some(None);
    }
    if let Some(nbf) = nbf_ts {
        if now < nbf {
            return Some(None);
        }
    }
    Some(sub_uid)
}

#[inline(always)]
fn ct_eq_32(a: &[u8; 32], b: &[u8]) -> bool {
    if b.len() != 32 {
        return false;
    }
    let mut diff = 0u8;
    for i in 0..32 {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

impl TokenSigner {
    pub fn new(secret: &[u8]) -> Self {
        let mut k_block = [0u8; 64];
        if secret.len() > 64 {
            let hashed = sha256_digest(secret);
            k_block[..32].copy_from_slice(&hashed);
        } else {
            k_block[..secret.len()].copy_from_slice(secret);
        }
        let mut ipad = [0x36u8; 64];
        let mut opad = [0x5cu8; 64];
        for i in 0..64 {
            ipad[i] ^= k_block[i];
            opad[i] ^= k_block[i];
        }
        let mut ipad_state = SHA256_H0;
        let mut opad_state = SHA256_H0;
        compress_block(&mut ipad_state, &ipad);
        compress_block(&mut opad_state, &opad);
        TokenSigner { ipad_state, opad_state }
    }

    #[inline]
    pub fn sign_bytes(&self, data: &[u8]) -> [u8; 32] {
        let inner = sha256_with_state(self.ipad_state, 64, data);
        let outer_w: [u32; 16] = [
            inner[0], inner[1], inner[2], inner[3], inner[4], inner[5], inner[6], inner[7],
            0x8000_0000, 0, 0, 0, 0, 0, 0, 768,
        ];
        let mut outer = self.opad_state;
        compress_words(&mut outer, outer_w);
        state_to_bytes(&outer)
    }

    pub fn verify(&self, token: &[u8]) -> Option<i64> {
        let dot1 = codec::find_byte(token, b'.')?;
        let dot2 = dot1 + 1 + codec::find_byte(&token[dot1 + 1..], b'.')?;
        let (hdr_b64, pay_b64, sig_b64) = (&token[..dot1], &token[dot1 + 1..dot2], &token[dot2 + 1..]);
        if codec::find_byte(sig_b64, b'.').is_some() {
            return None;
        }

        let mut sig = [0u8; 48];
        if codec::b64url_decode_slice(sig_b64, &mut sig)? != 32 {
            return None;
        }
        let expected = self.sign_bytes(&token[..dot2]);
        if !ct_eq_32(&expected, &sig[..32]) {
            return None;
        }

        if hdr_b64 != JWT_HDR_STD && hdr_b64 != JWT_HDR_ALT && hdr_b64 != JWT_HDR_MIN {
            if hdr_b64.len() > 340 {
                return None;
            }
            let mut hbuf = [0u8; 256];
            let hn = codec::b64url_decode_slice(hdr_b64, &mut hbuf)?;
            let hv: JsonVal = codec::parse_json(&hbuf[..hn])?;
            if hv.get("alg")?.as_str()? != "HS256" {
                return None;
            }
        }

        let mut pbuf = [0u8; 512];
        let heap_pay;
        let payload: &[u8] = if pay_b64.len() <= 680 {
            let pn = codec::b64url_decode_slice(pay_b64, &mut pbuf)?;
            &pbuf[..pn]
        } else {
            heap_pay = codec::b64url_decode_vec(pay_b64)?;
            &heap_pay
        };

        let now = unix_now_f64();
        if let Some(res) = scan_flat_claims(payload, now) {
            return res;
        }

        let pv: JsonVal = codec::parse_json(payload)?;
        let obj = pv.as_object()?;
        let exp = obj.get("exp")?.as_f64()?;
        if !(now < exp) {
            return None;
        }
        if let Some(nbf) = obj.get("nbf") {
            if now < nbf.as_f64()? {
                return None;
            }
        }
        if let Some(iat) = obj.get("iat") {
            iat.as_f64()?;
        }
        let sub = obj.get("sub")?.as_str()?;
        if sub.is_empty() || !sub.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let uid: i64 = sub.parse().ok()?;
        if uid <= 0 {
            return None;
        }
        Some(uid)
    }

    pub fn issue(&self, user_id: i64) -> String {
        let iat = unix_now_secs();
        let exp = iat + 30 * 86_400;
        let mut pbuf = [0u8; 96];
        let mut plen = 0usize;
        let mut push = |s: &[u8]| {
            pbuf[plen..plen + s.len()].copy_from_slice(s);
            plen += s.len();
        };
        let mut num_buf = [0u8; 20];
        push(b"{\"exp\":");
        push(codec::format_u64_into(exp as u64, &mut num_buf));
        push(b",\"iat\":");
        push(codec::format_u64_into(iat as u64, &mut num_buf));
        push(b",\"sub\":\"");
        push(codec::format_u64_into(user_id as u64, &mut num_buf));
        push(b"\"}");

        let mut tok = String::with_capacity(160);
        tok.push_str("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.");
        codec::b64url_encode_append(&pbuf[..plen], &mut tok);
        let sig = self.sign_bytes(tok.as_bytes());
        tok.push('.');
        codec::b64url_encode_append(&sig, &mut tok);
        tok
    }
}

const BF_P: [u32; 18] = [
    0x243f_6a88, 0x85a3_08d3, 0x1319_8a2e, 0x0370_7344, 0xa409_3822, 0x299f_31d0,
    0x082e_fa98, 0xec4e_6c89, 0x4528_21e6, 0x38d0_1377, 0xbe54_66cf, 0x34e9_0c6c,
    0xc0ac_29b7, 0xc97c_50dd, 0x3f84_d5b5, 0xb547_0917, 0x9216_d5d9, 0x8979_fb1b,
];

const BF_S: [[u32; 256]; 4] = [
    [
        0xd131_0ba6, 0x98df_b5ac, 0x2ffd_72db, 0xd01a_dfb7, 0xb8e1_afed, 0x6a26_7e96, 0xba7c_9045, 0xf12c_7f99,
        0x24a1_9947, 0xb391_6cf7, 0x0801_f2e2, 0x858e_fc16, 0x6369_20d8, 0x7157_4e69, 0xa458_fea3, 0xf493_3d7e,
        0x0d95_748f, 0x728e_b658, 0x718b_cd58, 0x8215_4aee, 0x7b54_a41d, 0xc25a_59b5, 0x9c30_d539, 0x2af2_6013,
        0xc5d1_b023, 0x2860_85f0, 0xca41_7918, 0xb8db_38ef, 0x8e79_dcb0, 0x603a_180e, 0x6c9e_0e8b, 0xb01e_8a3e,
        0xd715_77c1, 0xbd31_4b27, 0x78af_2fda, 0x5560_5c60, 0xe655_25f3, 0xaa55_ab94, 0x5748_9862, 0x63e8_1440,
        0x55ca_396a, 0x2aab_10b6, 0xb4cc_5c34, 0x1141_e8ce, 0xa154_86af, 0x7c72_e993, 0xb3ee_1411, 0x636f_bc2a,
        0x2ba9_c55d, 0x7418_31f6, 0xce5c_3e16, 0x9b87_931e, 0xafd6_ba33, 0x6c24_cf5c, 0x7a32_5381, 0x2895_8677,
        0x3b8f_4898, 0x6b4b_b9af, 0xc4bf_e81b, 0x6628_2193, 0x61d8_09cc, 0xfb21_a991, 0x487c_ac60, 0x5dec_8032,
        0xef84_5d5d, 0xe985_75b1, 0xdc26_2302, 0xeb65_1b88, 0x2389_3e81, 0xd396_acc5, 0x0f6d_6ff3, 0x83f4_4239,
        0x2e0b_4482, 0xa484_2004, 0x69c8_f04a, 0x9e1f_9b5e, 0x21c6_6842, 0xf6e9_6c9a, 0x670c_9c61, 0xabd3_88f0,
        0x6a51_a0d2, 0xd854_2f68, 0x960f_a728, 0xab51_33a3, 0x6eef_0b6c, 0x137a_3be4, 0xba3b_f050, 0x7efb_2a98,
        0xa1f1_651d, 0x39af_0176, 0x66ca_593e, 0x8243_0e88, 0x8cee_8619, 0x456f_9fb4, 0x7d84_a5c3, 0x3b8b_5ebe,
        0xe06f_75d8, 0x85c1_2073, 0x401a_449f, 0x56c1_6aa6, 0x4ed3_aa62, 0x363f_7706, 0x1bfe_df72, 0x429b_023d,
        0x37d0_d724, 0xd00a_1248, 0xdb0f_ead3, 0x49f1_c09b, 0x0753_72c9, 0x8099_1b7b, 0x25d4_79d8, 0xf6e8_def7,
        0xe3fe_501a, 0xb679_4c3b, 0x976c_e0bd, 0x04c0_06ba, 0xc1a9_4fb6, 0x409f_60c4, 0x5e5c_9ec2, 0x196a_2463,
        0x68fb_6faf, 0x3e6c_53b5, 0x1339_b2eb, 0x3b52_ec6f, 0x6dfc_511f, 0x9b30_952c, 0xcc81_4544, 0xaf5e_bd09,
        0xbee3_d004, 0xde33_4afd, 0x660f_2807, 0x192e_4bb3, 0xc0cb_a857, 0x45c8_740f, 0xd20b_5f39, 0xb9d3_fbdb,
        0x5579_c0bd, 0x1a60_320a, 0xd6a1_00c6, 0x402c_7279, 0x679f_25fe, 0xfb1f_a3cc, 0x8ea5_e9f8, 0xdb32_22f8,
        0x3c75_16df, 0xfd61_6b15, 0x2f50_1ec8, 0xad05_52ab, 0x323d_b5fa, 0xfd23_8760, 0x5331_7b48, 0x3e00_df82,
        0x9e5c_57bb, 0xca6f_8ca0, 0x1a87_562e, 0xdf17_69db, 0xd542_a8f6, 0x287e_ffc3, 0xac67_32c6, 0x8c4f_5573,
        0x695b_27b0, 0xbbca_58c8, 0xe1ff_a35d, 0xb8f0_11a0, 0x10fa_3d98, 0xfd21_83b8, 0x4afc_b56c, 0x2dd1_d35b,
        0x9a53_e479, 0xb6f8_4565, 0xd28e_49bc, 0x4bfb_9790, 0xe1dd_f2da, 0xa4cb_7e33, 0x62fb_1341, 0xcee4_c6e8,
        0xef20_cada, 0x3677_4c01, 0xd07e_9efe, 0x2bf1_1fb4, 0x95db_da4d, 0xae90_9198, 0xeaad_8e71, 0x6b93_d5a0,
        0xd08e_d1d0, 0xafc7_25e0, 0x8e3c_5b2f, 0x8e75_94b7, 0x8ff6_e2fb, 0xf212_2b64, 0x8888_b812, 0x900d_f01c,
        0x4fad_5ea0, 0x688f_c31c, 0xd1cf_f191, 0xb3a8_c1ad, 0x2f2f_2218, 0xbe0e_1777, 0xea75_2dfe, 0x8b02_1fa1,
        0xe5a0_cc0f, 0xb56f_74e8, 0x18ac_f3d6, 0xce89_e299, 0xb4a8_4fe0, 0xfd13_e0b7, 0x7cc4_3b81, 0xd2ad_a8d9,
        0x165f_a266, 0x8095_7705, 0x93cc_7314, 0x211a_1477, 0xe6ad_2065, 0x77b5_fa86, 0xc754_42f5, 0xfb9d_35cf,
        0xebcd_af0c, 0x7b3e_89a0, 0xd641_1bd3, 0xae1e_7e49, 0x0025_0e2d, 0x2071_b35e, 0x2268_00bb, 0x57b8_e0af,
        0x2464_369b, 0xf009_b91e, 0x5563_911d, 0x59df_a6aa, 0x78c1_4389, 0xd95a_537f, 0x207d_5ba2, 0x02e5_b9c5,
        0x8326_0376, 0x6295_cfa9, 0x11c8_1968, 0x4e73_4a41, 0xb347_2dca, 0x7b14_a94a, 0x1b51_0052, 0x9a53_2915,
        0xd60f_573f, 0xbc9b_c6e4, 0x2b60_a476, 0x81e6_7400, 0x08ba_6fb5, 0x571b_e91f, 0xf296_ec6b, 0x2a0d_d915,
        0xb663_6521, 0xe7b9_f9b6, 0xff34_052e, 0xc585_5664, 0x53b0_2d5d, 0xa99f_8fa1, 0x08ba_4799, 0x6e85_076a,
    ],
    [
        0x4b7a_70e9, 0xb5b3_2944, 0xdb75_092e, 0xc419_2623, 0xad6e_a6b0, 0x49a7_df7d, 0x9cee_60b8, 0x8fed_b266,
        0xecaa_8c71, 0x699a_17ff, 0x5664_526c, 0xc2b1_9ee1, 0x1936_02a5, 0x7509_4c29, 0xa059_1340, 0xe418_3a3e,
        0x3f54_989a, 0x5b42_9d65, 0x6b8f_e4d6, 0x99f7_3fd6, 0xa1d2_9c07, 0xefe8_30f5, 0x4d2d_38e6, 0xf025_5dc1,
        0x4cdd_2086, 0x8470_eb26, 0x6382_e9c6, 0x021e_cc5e, 0x0968_6b3f, 0x3eba_efc9, 0x3c97_1814, 0x6b6a_70a1,
        0x687f_3584, 0x52a0_e286, 0xb79c_5305, 0xaa50_0737, 0x3e07_841c, 0x7fde_ae5c, 0x8e7d_44ec, 0x5716_f2b8,
        0xb03a_da37, 0xf050_0c0d, 0xf01c_1f04, 0x0200_b3ff, 0xae0c_f51a, 0x3cb5_74b2, 0x2583_7a58, 0xdc09_21bd,
        0xd191_13f9, 0x7ca9_2ff6, 0x9432_4773, 0x22f5_4701, 0x3ae5_e581, 0x37c2_dadc, 0xc8b5_7634, 0x9af3_dda7,
        0xa944_6146, 0x0fd0_030e, 0xecc8_c73e, 0xa475_1e41, 0xe238_cd99, 0x3bea_0e2f, 0x3280_bba1, 0x183e_b331,
        0x4e54_8b38, 0x4f6d_b908, 0x6f42_0d03, 0xf60a_04bf, 0x2cb8_1290, 0x2497_7c79, 0x5679_b072, 0xbcaf_89af,
        0xde9a_771f, 0xd993_0810, 0xb38b_ae12, 0xdccf_3f2e, 0x5512_721f, 0x2e6b_7124, 0x501a_dde6, 0x9f84_cd87,
        0x7a58_4718, 0x7408_da17, 0xbc9f_9abc, 0xe94b_7d8c, 0xec7a_ec3a, 0xdb85_1dfa, 0x6309_4366, 0xc464_c3d2,
        0xef1c_1847, 0x3215_d908, 0xdd43_3b37, 0x24c2_ba16, 0x12a1_4d43, 0x2a65_c451, 0x5094_0002, 0x133a_e4dd,
        0x71df_f89e, 0x1031_4e55, 0x81ac_77d6, 0x5f11_199b, 0x0435_56f1, 0xd7a3_c76b, 0x3c11_183b, 0x5924_a509,
        0xf28f_e6ed, 0x97f1_fbfa, 0x9eba_bf2c, 0x1e15_3c6e, 0x86e3_4570, 0xeae9_6fb1, 0x860e_5e0a, 0x5a3e_2ab3,
        0x771f_e71c, 0x4e3d_06fa, 0x2965_dcb9, 0x99e7_1d0f, 0x803e_89d6, 0x5266_c825, 0x2e4c_c978, 0x9c10_b36a,
        0xc615_0eba, 0x94e2_ea78, 0xa5fc_3c53, 0x1e0a_2df4, 0xf2f7_4ea7, 0x361d_2b3d, 0x1939_260f, 0x19c2_7960,
        0x5223_a708, 0xf713_12b6, 0xebad_fe6e, 0xeac3_1f66, 0xe3bc_4595, 0xa67b_c883, 0xb17f_37d1, 0x018c_ff28,
        0xc332_ddef, 0xbe6c_5aa5, 0x6558_2185, 0x68ab_9802, 0xeece_a50f, 0xdb2f_953b, 0x2aef_7dad, 0x5b6e_2f84,
        0x1521_b628, 0x2907_6170, 0xecdd_4775, 0x619f_1510, 0x13cc_a830, 0xeb61_bd96, 0x0334_fe1e, 0xaa03_63cf,
        0xb573_5c90, 0x4c70_a239, 0xd59e_9e0b, 0xcbaa_de14, 0xeecc_86bc, 0x6062_2ca7, 0x9cab_5cab, 0xb2f3_846e,
        0x648b_1eaf, 0x19bd_f0ca, 0xa023_69b9, 0x655a_bb50, 0x4068_5a32, 0x3c2a_b4b3, 0x319e_e9d5, 0xc021_b8f7,
        0x9b54_0b19, 0x875f_a099, 0x95f7_997e, 0x623d_7da8, 0xf837_889a, 0x97e3_2d77, 0x11ed_935f, 0x1668_1281,
        0x0e35_8829, 0xc7e6_1fd6, 0x96de_dfa1, 0x7858_ba99, 0x57f5_84a5, 0x1b22_7263, 0x9b83_c3ff, 0x1ac2_4696,
        0xcdb3_0aeb, 0x532e_3054, 0x8fd9_48e4, 0x6dbc_3128, 0x58eb_f2ef, 0x34c6_ffea, 0xfe28_ed61, 0xee7c_3c73,
        0x5d4a_14d9, 0xe864_b7e3, 0x4210_5d14, 0x203e_13e0, 0x45ee_e2b6, 0xa3aa_abea, 0xdb6c_4f15, 0xfacb_4fd0,
        0xc742_f442, 0xef6a_bbb5, 0x654f_3b1d, 0x41cd_2105, 0xd81e_799e, 0x8685_4dc7, 0xe44b_476a, 0x3d81_6250,
        0xcf62_a1f2, 0x5b8d_2646, 0xfc88_83a0, 0xc1c7_b6a3, 0x7f15_24c3, 0x69cb_7492, 0x4784_8a0b, 0x5692_b285,
        0x095b_bf00, 0xad19_489d, 0x1462_b174, 0x2382_0e00, 0x5842_8d2a, 0x0c55_f5ea, 0x1dad_f43e, 0x233f_7061,
        0x3372_f092, 0x8d93_7e41, 0xd65f_ecf1, 0x6c22_3bdb, 0x7cde_3759, 0xcbee_7460, 0x4085_f2a7, 0xce77_326e,
        0xa607_8084, 0x19f8_509e, 0xe8ef_d855, 0x61d9_9735, 0xa969_a7aa, 0xc50c_06c2, 0x5a04_abfc, 0x800b_cadc,
        0x9e44_7a2e, 0xc345_3484, 0xfdd5_6705, 0x0e1e_9ec9, 0xdb73_dbd3, 0x1055_88cd, 0x675f_da79, 0xe367_4340,
        0xc5c4_3465, 0x713e_38d8, 0x3d28_f89e, 0xf16d_ff20, 0x153e_21e7, 0x8fb0_3d4a, 0xe6e3_9f2b, 0xdb83_adf7,
    ],
    [
        0xe93d_5a68, 0x9481_40f7, 0xf64c_261c, 0x9469_2934, 0x4115_20f7, 0x7602_d4f7, 0xbcf4_6b2e, 0xd4a2_0068,
        0xd408_2471, 0x3320_f46a, 0x43b7_d4b7, 0x5000_61af, 0x1e39_f62e, 0x9724_4546, 0x1421_4f74, 0xbf8b_8840,
        0x4d95_fc1d, 0x96b5_91af, 0x70f4_ddd3, 0x66a0_2f45, 0xbfbc_09ec, 0x03bd_9785, 0x7fac_6dd0, 0x31cb_8504,
        0x96eb_27b3, 0x55fd_3941, 0xda25_47e6, 0xabca_0a9a, 0x2850_7825, 0x5304_29f4, 0x0a2c_86da, 0xe9b6_6dfb,
        0x68dc_1462, 0xd748_6900, 0x680e_c0a4, 0x27a1_8dee, 0x4f3f_fea2, 0xe887_ad8c, 0xb58c_e006, 0x7af4_d6b6,
        0xaace_1e7c, 0xd337_5fec, 0xce78_a399, 0x406b_2a42, 0x20fe_9e35, 0xd9f3_85b9, 0xee39_d7ab, 0x3b12_4e8b,
        0x1dc9_faf7, 0x4b6d_1856, 0x26a3_6631, 0xeae3_97b2, 0x3a6e_fa74, 0xdd5b_4332, 0x6841_e7f7, 0xca78_20fb,
        0xfb0a_f54e, 0xd8fe_b397, 0x4540_56ac, 0xba48_9527, 0x5553_3a3a, 0x2083_8d87, 0xfe6b_a9b7, 0xd096_954b,
        0x55a8_67bc, 0xa115_9a58, 0xcca9_2963, 0x99e1_db33, 0xa62a_4a56, 0x3f31_25f9, 0x5ef4_7e1c, 0x9029_317c,
        0xfdf8_e802, 0x0427_2f70, 0x80bb_155c, 0x0528_2ce3, 0x95c1_1548, 0xe4c6_6d22, 0x48c1_133f, 0xc70f_86dc,
        0x07f9_c9ee, 0x4104_1f0f, 0x4047_79a4, 0x5d88_6e17, 0x325f_51eb, 0xd59b_c0d1, 0xf2bc_c18f, 0x4111_3564,
        0x257b_7834, 0x602a_9c60, 0xdff8_e8a3, 0x1f63_6c1b, 0x0e12_b4c2, 0x02e1_329e, 0xaf66_4fd1, 0xcad1_8115,
        0x6b23_95e0, 0x333e_92e1, 0x3b24_0b62, 0xeebe_b922, 0x85b2_a20e, 0xe6ba_0d99, 0xde72_0c8c, 0x2da2_f728,
        0xd012_7845, 0x95b7_94fd, 0x647d_0862, 0xe7cc_f5f0, 0x5449_a36f, 0x877d_48fa, 0xc39d_fd27, 0xf33e_8d1e,
        0x0a47_6341, 0x992e_ff74, 0x3a6f_6eab, 0xf4f8_fd37, 0xa812_dc60, 0xa1eb_ddf8, 0x991b_e14c, 0xdb6e_6b0d,
        0xc67b_5510, 0x6d67_2c37, 0x2765_d43b, 0xdcd0_e804, 0xf129_0dc7, 0xcc00_ffa3, 0xb539_0f92, 0x690f_ed0b,
        0x667b_9ffb, 0xcedb_7d9c, 0xa091_cf0b, 0xd915_5ea3, 0xbb13_2f88, 0x515b_ad24, 0x7b94_79bf, 0x763b_d6eb,
        0x3739_2eb3, 0xcc11_5979, 0x8026_e297, 0xf42e_312d, 0x6842_ada7, 0xc66a_2b3b, 0x1275_4ccc, 0x782e_f11c,
        0x6a12_4237, 0xb792_51e7, 0x06a1_bbe6, 0x4bfb_6350, 0x1a6b_1018, 0x11ca_edfa, 0x3d25_bdd8, 0xe2e1_c3c9,
        0x4442_1659, 0x0a12_1386, 0xd90c_ec6e, 0xd5ab_ea2a, 0x64af_674e, 0xda86_a85f, 0xbebf_e988, 0x64e4_c3fe,
        0x9dbc_8057, 0xf0f7_c086, 0x6078_7bf8, 0x6003_604d, 0xd1fd_8346, 0xf638_1fb0, 0x7745_ae04, 0xd736_fccc,
        0x8342_6b33, 0xf01e_ab71, 0xb080_4187, 0x3c00_5e5f, 0x77a0_57be, 0xbde8_ae24, 0x5546_4299, 0xbf58_2e61,
        0x4e58_f48f, 0xf2dd_fda2, 0xf474_ef38, 0x8789_bdc2, 0x5366_f9c3, 0xc8b3_8e74, 0xb475_f255, 0x46fc_d9b9,
        0x7aeb_2661, 0x8b1d_df84, 0x846a_0e79, 0x915f_95e2, 0x466e_598e, 0x20b4_5770, 0x8cd5_5591, 0xc902_de4c,
        0xb90b_ace1, 0xbb82_05d0, 0x11a8_6248, 0x7574_a99e, 0xb77f_19b6, 0xe0a9_dc09, 0x662d_09a1, 0xc432_4633,
        0xe85a_1f02, 0x09f0_be8c, 0x4a99_a025, 0x1d6e_fe10, 0x1ab9_3d1d, 0x0ba5_a4df, 0xa186_f20f, 0x2868_f169,
        0xdcb7_da83, 0x5739_06fe, 0xa1e2_ce9b, 0x4fcd_7f52, 0x5011_5e01, 0xa706_83fa, 0xa002_b5c4, 0x0de6_d027,
        0x9af8_8c27, 0x773f_8641, 0xc360_4c06, 0x61a8_06b5, 0xf017_7a28, 0xc0f5_86e0, 0x0060_58aa, 0x30dc_7d62,
        0x11e6_9ed7, 0x2338_ea63, 0x53c2_dd94, 0xc2c2_1634, 0xbbcb_ee56, 0x90bc_b6de, 0xebfc_7da1, 0xce59_1d76,
        0x6f05_e409, 0x4b7c_0188, 0x3972_0a3d, 0x7c92_7c24, 0x86e3_725f, 0x724d_9db9, 0x1ac1_5bb4, 0xd39e_b8fc,
        0xed54_5578, 0x08fc_a5b5, 0xd83d_7cd3, 0x4dad_0fc4, 0x1e50_ef5e, 0xb161_e6f8, 0xa285_14d9, 0x6c51_133c,
        0x6fd5_c7e7, 0x56e1_4ec4, 0x362a_bfce, 0xddc6_c837, 0xd79a_3234, 0x9263_8212, 0x670e_fa8e, 0x4060_00e0,
    ],
    [
        0x3a39_ce37, 0xd3fa_f5cf, 0xabc2_7737, 0x5ac5_2d1b, 0x5cb0_679e, 0x4fa3_3742, 0xd382_2740, 0x99bc_9bbe,
        0xd511_8e9d, 0xbf0f_7315, 0xd62d_1c7e, 0xc700_c47b, 0xb78c_1b6b, 0x21a1_9045, 0xb26e_b1be, 0x6a36_6eb4,
        0x5748_ab2f, 0xbc94_6e79, 0xc6a3_76d2, 0x6549_c2c8, 0x530f_f8ee, 0x468d_de7d, 0xd573_0a1d, 0x4cd0_4dc6,
        0x2939_bbdb, 0xa9ba_4650, 0xac95_26e8, 0xbe5e_e304, 0xa1fa_d5f0, 0x6a2d_519a, 0x63ef_8ce2, 0x9a86_ee22,
        0xc089_c2b8, 0x4324_2ef6, 0xa51e_03aa, 0x9cf2_d0a4, 0x83c0_61ba, 0x9be9_6a4d, 0x8fe5_1550, 0xba64_5bd6,
        0x2826_a2f9, 0xa73a_3ae1, 0x4ba9_9586, 0xef55_62e9, 0xc72f_efd3, 0xf752_f7da, 0x3f04_6f69, 0x77fa_0a59,
        0x80e4_a915, 0x87b0_8601, 0x9b09_e6ad, 0x3b3e_e593, 0xe990_fd5a, 0x9e34_d797, 0x2cf0_b7d9, 0x022b_8b51,
        0x96d5_ac3a, 0x017d_a67d, 0xd1cf_3ed6, 0x7c7d_2d28, 0x1f9f_25cf, 0xadf2_b89b, 0x5ad6_b472, 0x5a88_f54c,
        0xe029_ac71, 0xe019_a5e6, 0x47b0_acfd, 0xed93_fa9b, 0xe8d3_c48d, 0x283b_57cc, 0xf8d5_6629, 0x7913_2e28,
        0x785f_0191, 0xed75_6055, 0xf796_0e44, 0xe3d3_5e8c, 0x1505_6dd4, 0x88f4_6dba, 0x03a1_6125, 0x0564_f0bd,
        0xc3eb_9e15, 0x3c90_57a2, 0x9727_1aec, 0xa93a_072a, 0x1b3f_6d9b, 0x1e63_21f5, 0xf59c_66fb, 0x26dc_f319,
        0x7533_d928, 0xb155_fdf5, 0x0356_3482, 0x8aba_3cbb, 0x2851_7711, 0xc20a_d9f8, 0xabcc_5167, 0xccad_925f,
        0x4de8_1751, 0x3830_dc8e, 0x379d_5862, 0x9320_f991, 0xea7a_90c2, 0xfb3e_7bce, 0x5121_ce64, 0x774f_be32,
        0xa8b6_e37e, 0xc329_3d46, 0x48de_5369, 0x6413_e680, 0xa2ae_0810, 0xdd6d_b224, 0x6985_2dfd, 0x0907_2166,
        0xb39a_460a, 0x6445_c0dd, 0x586c_decf, 0x1c20_c8ae, 0x5bbe_f7dd, 0x1b58_8d40, 0xccd2_017f, 0x6bb4_e3bb,
        0xdda2_6a7e, 0x3a59_ff45, 0x3e35_0a44, 0xbcb4_cdd5, 0x72ea_cea8, 0xfa64_84bb, 0x8d66_12ae, 0xbf3c_6f47,
        0xd29b_e463, 0x542f_5d9e, 0xaec2_771b, 0xf64e_6370, 0x740e_0d8d, 0xe75b_1357, 0xf872_1671, 0xaf53_7d5d,
        0x4040_cb08, 0x4eb4_e2cc, 0x34d2_466a, 0x0115_af84, 0xe1b0_0428, 0x9598_3a1d, 0x06b8_9fb4, 0xce6e_a048,
        0x6f3f_3b82, 0x3520_ab82, 0x011a_1d4b, 0x2772_27f8, 0x6115_60b1, 0xe793_3fdc, 0xbb3a_792b, 0x3445_25bd,
        0xa088_39e1, 0x51ce_794b, 0x2f32_c9b7, 0xa01f_bac9, 0xe01c_c87e, 0xbcc7_d1f6, 0xcf01_11c3, 0xa1e8_aac7,
        0x1a90_8749, 0xd44f_bd9a, 0xd0da_decb, 0xd50a_da38, 0x0339_c32a, 0xc691_3667, 0x8df9_317c, 0xe0b1_2b4f,
        0xf79e_59b7, 0x43f5_bb3a, 0xf2d5_19ff, 0x27d9_459c, 0xbf97_222c, 0x15e6_fc2a, 0x0f91_fc71, 0x9b94_1525,
        0xfae5_9361, 0xceb6_9ceb, 0xc2a8_6459, 0x12ba_a8d1, 0xb6c1_075e, 0xe305_6a0c, 0x10d2_5065, 0xcb03_a442,
        0xe0ec_6e0e, 0x1698_db3b, 0x4c98_a0be, 0x3278_e964, 0x9f1f_9532, 0xe0d3_92df, 0xd3a0_342b, 0x8971_f21e,
        0x1b0a_7441, 0x4ba3_348c, 0xc5be_7120, 0xc376_32d8, 0xdf35_9f8d, 0x9b99_2f2e, 0xe60b_6f47, 0x0fe3_f11d,
        0xe54c_da54, 0x1eda_d891, 0xce62_79cf, 0xcd3e_7e6f, 0x1618_b166, 0xfd2c_1d05, 0x848f_d2c5, 0xf6fb_2299,
        0xf523_f357, 0xa632_7623, 0x93a8_3531, 0x56cc_cd02, 0xacf0_8162, 0x5a75_ebb5, 0x6e16_3697, 0x88d2_73cc,
        0xde96_6292, 0x81b9_49d0, 0x4c50_901b, 0x71c6_5614, 0xe6c6_c7bd, 0x327a_140a, 0x45e1_d006, 0xc3f2_7b9a,
        0xc9aa_53fd, 0x62a8_0f00, 0xbb25_bfe2, 0x35bd_d2f6, 0x7112_6905, 0xb204_0222, 0xb6cb_cf7c, 0xcd76_9c2b,
        0x5311_3ec0, 0x1640_e3d3, 0x38ab_bd60, 0x2547_adf0, 0xba38_209c, 0xf746_ce76, 0x77af_a1c5, 0x2075_6060,
        0x85cb_fe4e, 0x8ae8_8dd8, 0x7aaa_f9b0, 0x4cf9_aa7e, 0x1948_c25c, 0x02fb_8a8c, 0x01c3_6ae4, 0xd6eb_e1f9,
        0x90d4_f869, 0xa65c_dea0, 0x3f09_252d, 0xc208_e69f, 0xb74e_6132, 0xce77_e25b, 0x578f_dfe3, 0x3ac3_72e6,
    ],
];

const BCRYPT_B64: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const BCRYPT_CTEXT: [u32; 6] = [
    0x4f72_7068,
    0x6561_6e42,
    0x6568_6f6c,
    0x6465_7253,
    0x6372_7944,
    0x6f75_6274,
];

const BCRYPT_DEC: [u8; 256] = {
    let mut lut = [0xffu8; 256];
    let mut i = 0;
    while i < 64 {
        lut[BCRYPT_B64[i] as usize] = i as u8;
        i += 1;
    }
    lut
};

#[derive(Clone, Copy)]
#[repr(align(64))]
struct BfState {
    p: [u32; 18],
    s: [[u32; 256]; 4],
    _pad: [u32; 14],
}

#[inline(always)]
fn feistel(s: &[[u32; 256]; 4], x: u32) -> u32 {
    let a = s[0][(x >> 24) as usize];
    let b = s[1][((x >> 16) & 0xff) as usize];
    let c = s[2][((x >> 8) & 0xff) as usize];
    let d = s[3][(x & 0xff) as usize];
    (a.wrapping_add(b) ^ c).wrapping_add(d)
}

// Interleaves 16-round Blowfish encryption across N independent states to overlap S-box loads.
#[inline(always)]
fn encipher_lanes<const N: usize>(st: &[BfState; N], l: &mut [u32; N], r: &mut [u32; N]) {
    for round_pair in 0..8 {
        for k in 0..N {
            l[k] ^= st[k].p[2 * round_pair];
            r[k] ^= feistel(&st[k].s, l[k]);
        }
        for k in 0..N {
            r[k] ^= st[k].p[2 * round_pair + 1];
            l[k] ^= feistel(&st[k].s, r[k]);
        }
    }
    for k in 0..N {
        let nl = r[k] ^ st[k].p[17];
        let nr = l[k] ^ st[k].p[16];
        l[k] = nl;
        r[k] = nr;
    }
}

#[inline(always)]
fn next_be_word(src: &[u8], cursor: &mut usize) -> u32 {
    let mut w = 0u32;
    for _ in 0..4 {
        if *cursor >= src.len() {
            *cursor = 0;
        }
        w = (w << 8) | src[*cursor] as u32;
        *cursor += 1;
    }
    w
}

#[derive(Clone, Copy)]
struct KeyMaterial {
    key_p: [u32; 18],
    salt4: [u32; 4],
    salt18: [u32; 18],
}

impl KeyMaterial {
    fn from_pw_salt(pw: &[u8], salt: &[u8; 16]) -> Self {
        let mut nul_pw = [0u8; 73];
        let len = pw.len().min(72);
        nul_pw[..len].copy_from_slice(&pw[..len]);
        let key_slice = &nul_pw[..len + 1];

        let mut kc = 0;
        let mut key_p = [0u32; 18];
        for w in &mut key_p {
            *w = next_be_word(key_slice, &mut kc);
        }

        let mut sc = 0;
        let mut salt4 = [0u32; 4];
        for w in &mut salt4 {
            *w = next_be_word(salt, &mut sc);
        }

        let mut salt18 = [0u32; 18];
        for (i, w) in salt18.iter_mut().enumerate() {
            *w = salt4[i & 3];
        }
        KeyMaterial { key_p, salt4, salt18 }
    }
}

#[inline(always)]
fn eks_expand<const N: usize, const WITH_SALT: bool>(
    st: &mut [BfState; N],
    xor_words: &[[u32; 18]; N],
    salt4: &[[u32; 4]; N],
) {
    for k in 0..N {
        for i in 0..18 {
            st[k].p[i] ^= xor_words[k][i];
        }
    }
    let mut l = [0u32; N];
    let mut r = [0u32; N];
    let mut s_idx = 0usize;

    for i in 0..9 {
        if WITH_SALT {
            for k in 0..N {
                l[k] ^= salt4[k][s_idx & 3];
                r[k] ^= salt4[k][(s_idx + 1) & 3];
            }
            s_idx += 2;
        }
        encipher_lanes(st, &mut l, &mut r);
        for k in 0..N {
            st[k].p[2 * i] = l[k];
            st[k].p[2 * i + 1] = r[k];
        }
    }
    for box_idx in 0..4 {
        for pair in 0..128 {
            if WITH_SALT {
                for k in 0..N {
                    l[k] ^= salt4[k][s_idx & 3];
                    r[k] ^= salt4[k][(s_idx + 1) & 3];
                }
                s_idx += 2;
            }
            encipher_lanes(st, &mut l, &mut r);
            for k in 0..N {
                st[k].s[box_idx][2 * pair] = l[k];
                st[k].s[box_idx][2 * pair + 1] = r[k];
            }
        }
    }
}

pub struct BcryptInput<'a> {
    pub password: &'a [u8],
    pub salt: [u8; 16],
}

pub fn bcrypt_lanes<const N: usize>(inputs: &[BcryptInput; N], cost: u32) -> [[u8; 23]; N] {
    let mats: [KeyMaterial; N] = std::array::from_fn(|k| KeyMaterial::from_pw_salt(inputs[k].password, &inputs[k].salt));
    let key_p: [[u32; 18]; N] = std::array::from_fn(|k| mats[k].key_p);
    let salt_p: [[u32; 18]; N] = std::array::from_fn(|k| mats[k].salt18);
    let salt4: [[u32; 4]; N] = std::array::from_fn(|k| mats[k].salt4);

    let mut st: [BfState; N] = [BfState {
        p: BF_P,
        s: BF_S,
        _pad: [0; 14],
    }; N];

    eks_expand::<N, true>(&mut st, &key_p, &salt4);
    let rounds = 1u64 << cost;
    for _ in 0..rounds {
        eks_expand::<N, false>(&mut st, &key_p, &salt4);
        eks_expand::<N, false>(&mut st, &salt_p, &salt4);
    }

    let mut ctext: [[u32; 6]; N] = [BCRYPT_CTEXT; N];
    for _ in 0..64 {
        for blk in 0..3 {
            let mut l: [u32; N] = std::array::from_fn(|k| ctext[k][2 * blk]);
            let mut r: [u32; N] = std::array::from_fn(|k| ctext[k][2 * blk + 1]);
            encipher_lanes(&st, &mut l, &mut r);
            for k in 0..N {
                ctext[k][2 * blk] = l[k];
                ctext[k][2 * blk + 1] = r[k];
            }
        }
    }

    let mut digests = [[0u8; 23]; N];
    for k in 0..N {
        let mut raw = [0u8; 24];
        for (i, w) in ctext[k].iter().enumerate() {
            raw[4 * i..4 * i + 4].copy_from_slice(&w.to_be_bytes());
        }
        digests[k].copy_from_slice(&raw[..23]);
    }
    digests
}

pub fn detect_l1d_kb() -> usize {
    if let Ok(raw) = std::fs::read_to_string("/sys/devices/system/cpu/cpu0/cache/index0/size") {
        let s = raw.trim();
        if let Some(num) = s.strip_suffix('K').or_else(|| s.strip_suffix('k')) {
            if let Ok(kb) = num.parse::<usize>() {
                if kb >= 16 && kb <= 512 {
                    return kb;
                }
            }
        }
    }
    32
}

pub fn calibrate_bcrypt_hardware() -> (usize, usize, usize) {
    let l1d_kb = detect_l1d_kb();
    let warm_in = [BcryptInput {
        password: b"calibrate-warmup",
        salt: [0x5au8; 16],
    }];
    std::hint::black_box(bcrypt_lanes::<1>(&warm_in, 5));

    macro_rules! probe_n {
        ($n:literal) => {{
            let inputs: [BcryptInput; $n] = std::array::from_fn(|k| BcryptInput {
                password: b"calibrate-benchmark-pw",
                salt: [(k as u8).wrapping_mul(17).wrapping_add(3); 16],
            });
            let t0 = std::time::Instant::now();
            std::hint::black_box(bcrypt_lanes::<$n>(&inputs, 8));
            let us_cost8 = t0.elapsed().as_micros() as usize;
            let us_cost10 = (us_cost8 * 4).max(1_000);
            let per_hash_us = us_cost10 / $n;
            ($n, us_cost10, per_hash_us)
        }};
    }

    let candidates = [probe_n!(2), probe_n!(3), probe_n!(4), probe_n!(6)];
    let mut best = candidates[0];
    for cand in &candidates[1..] {
        let state_kb = (cand.0 * std::mem::size_of::<BfState>()) / 1024;
        if state_kb <= l1d_kb && cand.2 * 103 < best.2 * 100 {
            best = *cand;
        }
    }
    (best.0, best.1, l1d_kb)
}

fn encode_bcrypt_b64(src: &[u8], dst: &mut Vec<u8>) {
    let mut i = 0;
    while i < src.len() {
        let b0 = src[i];
        i += 1;
        dst.push(BCRYPT_B64[(b0 >> 2) as usize]);
        let mut v = (b0 & 0x03) << 4;
        if i >= src.len() {
            dst.push(BCRYPT_B64[v as usize]);
            break;
        }
        let b1 = src[i];
        i += 1;
        v |= b1 >> 4;
        dst.push(BCRYPT_B64[v as usize]);
        v = (b1 & 0x0f) << 2;
        if i >= src.len() {
            dst.push(BCRYPT_B64[v as usize]);
            break;
        }
        let b2 = src[i];
        i += 1;
        v |= b2 >> 6;
        dst.push(BCRYPT_B64[v as usize]);
        dst.push(BCRYPT_B64[(b2 & 0x3f) as usize]);
    }
}

#[inline(always)]
fn dec_b64_char(c: u8) -> Option<u8> {
    let v = BCRYPT_DEC[c as usize];
    if v == 0xff { None } else { Some(v) }
}

fn decode_bcrypt_b64<const N: usize>(src: &[u8]) -> Option<[u8; N]> {
    let mut out = [0u8; N];
    let mut o = 0;
    let mut i = 0;
    while o < N {
        let c1 = dec_b64_char(*src.get(i)?)?;
        let c2 = dec_b64_char(*src.get(i + 1)?)?;
        out[o] = (c1 << 2) | ((c2 & 0x30) >> 4);
        o += 1;
        if o >= N {
            break;
        }
        let c3 = dec_b64_char(*src.get(i + 2)?)?;
        out[o] = ((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2);
        o += 1;
        if o >= N {
            break;
        }
        let c4 = dec_b64_char(*src.get(i + 3)?)?;
        out[o] = ((c3 & 0x03) << 6) | c4;
        o += 1;
        i += 4;
    }
    Some(out)
}

pub struct ParsedBcrypt {
    pub cost: u32,
    pub salt: [u8; 16],
    pub digest: [u8; 23],
}

pub fn parse_bcrypt(encoded: &[u8]) -> Option<ParsedBcrypt> {
    if encoded.len() != 60
        || encoded[0] != b'$'
        || encoded[1] != b'2'
        || encoded[3] != b'$'
        || encoded[6] != b'$'
    {
        return None;
    }
    if !matches!(encoded[2], b'a' | b'b' | b'y') {
        return None;
    }
    let cost = (encoded[4] as char).to_digit(10)? * 10 + (encoded[5] as char).to_digit(10)?;
    if !(4..=31).contains(&cost) {
        return None;
    }
    let salt = decode_bcrypt_b64::<16>(&encoded[7..29])?;
    let digest = decode_bcrypt_b64::<23>(&encoded[29..60])?;
    Some(ParsedBcrypt { cost, salt, digest })
}

pub fn format_bcrypt(cost: u32, salt: &[u8; 16], digest: &[u8; 23]) -> String {
    let mut out = Vec::with_capacity(60);
    out.extend_from_slice(b"$2a$");
    out.push(b'0' + (cost / 10) as u8);
    out.push(b'0' + (cost % 10) as u8);
    out.push(b'$');
    encode_bcrypt_b64(salt, &mut out);
    encode_bcrypt_b64(digest, &mut out);
    String::from_utf8(out).expect("valid ASCII")
}

#[inline]
pub fn ct_digest_eq(a: &[u8; 23], b: &[u8; 23]) -> bool {
    let mut diff = 0u8;
    for i in 0..23 {
        diff |= a[i] ^ b[i];
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_and_jwt_roundtrip() {
        let abc = sha256_digest(b"abc");
        assert_eq!(
            abc,
            [
                0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad
            ]
        );

        let signer = TokenSigner::new(b"secret");
        let tok = signer.issue(42);
        assert_eq!(signer.verify(tok.as_bytes()), Some(42));
        let mut tampered = tok.clone().into_bytes();
        let last = tampered.len() - 2;
        tampered[last] ^= 1;
        assert_eq!(signer.verify(&tampered), None);
        assert_eq!(TokenSigner::new(b"wrong").verify(tok.as_bytes()), None);
    }

    #[test]
    fn bcrypt_matches_openbsd_vectors() {
        let vectors: &[(&[u8], &[u8])] = &[
            (b"U*U", b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
            (b"U*U*", b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"),
            (b"U*U*U", b"$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"),
            (b"", b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy"),
        ];
        for &(pw, expected) in vectors {
            let parsed = parse_bcrypt(expected).unwrap();
            let d = bcrypt_lanes::<1>(&[BcryptInput { password: pw, salt: parsed.salt }], parsed.cost)[0];
            assert_eq!(d, parsed.digest);
            assert_eq!(format_bcrypt(parsed.cost, &parsed.salt, &d).as_bytes(), expected);
        }
    }

    #[test]
    fn bcrypt_multi_lane_equivalence() {
        let pws: [&[u8]; 6] = [b"a", b"bb", b"password123", b"test4", b"test5", b"zzzzzzzzzzzzzzzzzzzz"];
        let salts: [[u8; 16]; 6] = std::array::from_fn(|i| [i as u8 * 7 + 1; 16]);
        let jobs: [BcryptInput; 6] = std::array::from_fn(|i| BcryptInput { password: pws[i], salt: salts[i] });
        let multi = bcrypt_lanes::<6>(&jobs, 4);
        for i in 0..6 {
            let single = bcrypt_lanes::<1>(&[BcryptInput { password: pws[i], salt: salts[i] }], 4)[0];
            assert_eq!(multi[i], single);
        }
    }
}
