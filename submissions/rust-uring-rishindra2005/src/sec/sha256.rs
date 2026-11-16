//! Hardware-accelerated SHA-256 using Intel/AMD SHA-NI extensions with portable scalar fallback.
//! Runtime CPUID dispatch detects SHA, SSE4.1, and SSSE3 extensions automatically.
#![allow(unsafe_op_in_unsafe_fn)]

pub const SHA256_H0: [u32; 8] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
];

pub const SHA256_K: [u32; 64] = [
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
pub unsafe fn compress_words_shani(state: &mut [u32; 8], w: [u32; 16]) {
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
        _mm_loadu_si128(w.as_ptr().add(idx).cast())
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

#[inline(always)]
pub fn compress_words_scalar(state: &mut [u32; 8], mut w: [u32; 16]) {
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
pub fn compress_words(state: &mut [u32; 8], w: [u32; 16]) {
    #[cfg(target_arch = "x86_64")]
    if std::is_x86_feature_detected!("sha")
        && std::is_x86_feature_detected!("sse4.1")
        && std::is_x86_feature_detected!("ssse3")
    {
        unsafe { compress_words_shani(state, w) };
        return;
    }
    compress_words_scalar(state, w);
}

#[inline(always)]
pub fn compress_block(state: &mut [u32; 8], block: &[u8; 64]) {
    let w: [u32; 16] = std::array::from_fn(|i| {
        u32::from_be_bytes([block[4 * i], block[4 * i + 1], block[4 * i + 2], block[4 * i + 3]])
    });
    compress_words(state, w);
}

#[inline]
pub fn sha256_with_state(mut state: [u32; 8], prior_bytes: u64, data: &[u8]) -> [u32; 8] {
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
pub fn state_to_bytes(state: &[u32; 8]) -> [u8; 32] {
    let mut out = [0u8; 32];
    for (i, &w) in state.iter().enumerate() {
        out[4 * i..4 * i + 4].copy_from_slice(&w.to_be_bytes());
    }
    out
}

/// Computes SHA-256 digest of data.
#[inline]
pub fn sha256_digest(data: &[u8]) -> [u8; 32] {
    state_to_bytes(&sha256_with_state(SHA256_H0, 0, data))
}

/// Standard SHA-256 export for crate::sec::sha256.
#[inline]
pub fn sha256(data: &[u8]) -> [u8; 32] {
    sha256_digest(data)
}
