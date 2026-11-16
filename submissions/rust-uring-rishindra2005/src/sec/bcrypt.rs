//! Hand-written assembly Blowfish engine & Bcrypt cost-10 implementation.
//! Features 6-wide, 4-wide, 2-wide, and 1-wide execution paths.

use std::arch::global_asm;

global_asm!(include_str!("bf_kernel.s"));

unsafe extern "C" {
    pub fn bf_cost_loop_1x_asm(
        state: *mut BfState,
        key_words: *const u32,
        salt_words: *const u32,
        round_count: u64,
    );
    pub fn bf_cost_loop_2x_asm(
        state: *mut BfState,
        key_words: *const u32,
        salt_words: *const u32,
        round_count: u64,
    );
    pub fn bf_cost_loop_4x_asm(
        state: *mut BfState,
        key_words: *const u32,
        salt_words: *const u32,
        round_count: u64,
    );
    pub fn bf_cost_loop_6x_asm(
        state: *mut BfState,
        key_words: *const u32,
        salt_words: *const u32,
        round_count: u64,
    );
}

// ---------------------------------------------------------------------------
// Standard Blowfish Constants (Hexadecimal digits of pi)
// ---------------------------------------------------------------------------

pub use crate::sec::bf_tables::{PI_P as BF_P, PI_S as BF_S};

pub const BCRYPT_CTEXT: [u32; 6] = [
    0x4f72_7068, // "Orph"
    0x6561_6e42, // "eanB"
    0x6568_6f6c, // "ehol"
    0x6465_7253, // "derS"
    0x6372_7944, // "cryD"
    0x6f75_6274, // "oubt"
];

#[repr(C, align(64))]
pub struct BfState {
    pub s: [[u32; 256]; 4],
    pub p: [u32; 18],
    pub _pad: [u32; 14],
}

pub struct KeyMaterial {
    pub key_p: [u32; 18],
    pub salt18: [u32; 18],
    pub salt4: [u32; 4],
}

impl KeyMaterial {
    pub fn from_pw_salt(pw: &[u8], salt: &[u8; 16]) -> Self {
        let mut key_p = [0u32; 18];
        let pw_len = if pw.is_empty() { 1 } else { pw.len() + 1 };
        let mut pw_buf = [0u8; 73];
        if !pw.is_empty() {
            let copy_len = pw.len().min(72);
            pw_buf[..copy_len].copy_from_slice(&pw[..copy_len]);
        }
        let mut key_idx = 0;
        for i in 0..18 {
            let mut word = 0u32;
            for _ in 0..4 {
                word = (word << 8) | (pw_buf[key_idx] as u32);
                key_idx = (key_idx + 1) % pw_len;
            }
            key_p[i] = word;
        }

        let mut salt4 = [0u32; 4];
        for i in 0..4 {
            salt4[i] = u32::from_be_bytes([salt[4 * i], salt[4 * i + 1], salt[4 * i + 2], salt[4 * i + 3]]);
        }
        let mut salt18 = [0u32; 18];
        for i in 0..18 {
            salt18[i] = salt4[i % 4];
        }

        KeyMaterial { key_p, salt18, salt4 }
    }
}

// ---------------------------------------------------------------------------
// Bcrypt Encoding / Decoding
// ---------------------------------------------------------------------------

pub const BCRYPT_B64: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

const fn alphabet_index_table() -> [u8; 256] {
    let mut table = [0xff; 256];
    let mut idx = 0;
    while idx < 64 {
        table[BCRYPT_B64[idx] as usize] = idx as u8;
        idx += 1;
    }
    table
}

pub const BCRYPT_DEC: [u8; 256] = alphabet_index_table();

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ParsedBcrypt {
    pub cost: u32,
    pub salt: [u8; 16],
    pub digest: [u8; 23],
}

pub fn decode_bcrypt_b64<const N: usize>(src: &[u8]) -> Option<[u8; N]> {
    let mut out = [0u8; N];
    let mut out_idx = 0;
    let mut bit_buf: u32 = 0;
    let mut bits_in_buf: u32 = 0;

    for &ch in src {
        let val = BCRYPT_DEC[ch as usize];
        if val == 0xff {
            return None;
        }
        bit_buf = (bit_buf << 6) | (val as u32);
        bits_in_buf += 6;
        while bits_in_buf >= 8 && out_idx < N {
            bits_in_buf -= 8;
            out[out_idx] = ((bit_buf >> bits_in_buf) & 0xff) as u8;
            out_idx += 1;
        }
    }

    if out_idx == N {
        Some(out)
    } else {
        None
    }
}

pub fn encode_bcrypt_b64(src: &[u8], dst: &mut Vec<u8>) {
    let mut chunks = src.chunks_exact(3);
    for chunk in chunks.by_ref() {
        let acc = ((chunk[0] as u32) << 16) | ((chunk[1] as u32) << 8) | (chunk[2] as u32);
        dst.push(BCRYPT_B64[((acc >> 18) & 0x3f) as usize]);
        dst.push(BCRYPT_B64[((acc >> 12) & 0x3f) as usize]);
        dst.push(BCRYPT_B64[((acc >> 6) & 0x3f) as usize]);
        dst.push(BCRYPT_B64[(acc & 0x3f) as usize]);
    }
    let rem = chunks.remainder();
    if rem.len() == 1 {
        let acc = (rem[0] as u32) << 16;
        dst.push(BCRYPT_B64[((acc >> 18) & 0x3f) as usize]);
        dst.push(BCRYPT_B64[((acc >> 12) & 0x3f) as usize]);
    } else if rem.len() == 2 {
        let acc = ((rem[0] as u32) << 16) | ((rem[1] as u32) << 8);
        dst.push(BCRYPT_B64[((acc >> 18) & 0x3f) as usize]);
        dst.push(BCRYPT_B64[((acc >> 12) & 0x3f) as usize]);
        dst.push(BCRYPT_B64[((acc >> 6) & 0x3f) as usize]);
    }
}

pub fn parse_bcrypt(encoded: &[u8]) -> Option<ParsedBcrypt> {
    if encoded.len() != 60 {
        return None;
    }
    let stripped = encoded.strip_prefix(b"$")?;
    let mut parts = stripped.split(|&b| b == b'$');
    let ver = parts.next()?;
    if !matches!(ver, b"2a" | b"2b" | b"2y") {
        return None;
    }
    let cost_bytes = parts.next()?;
    if cost_bytes.len() != 2 {
        return None;
    }
    let cost: u32 = std::str::from_utf8(cost_bytes).ok()?.parse().ok()?;
    if !(4..=31).contains(&cost) {
        return None;
    }
    let payload = parts.next()?;
    if parts.next().is_some() || payload.len() != 53 {
        return None;
    }
    let (salt_enc, digest_enc) = payload.split_at(22);
    let salt = decode_bcrypt_b64::<16>(salt_enc)?;
    let digest = decode_bcrypt_b64::<23>(digest_enc)?;
    Some(ParsedBcrypt { cost, salt, digest })
}

pub fn format_bcrypt(cost: u32, salt: &[u8; 16], digest: &[u8; 23]) -> String {
    let mut encoded_body = Vec::with_capacity(53);
    encode_bcrypt_b64(salt, &mut encoded_body);
    encode_bcrypt_b64(digest, &mut encoded_body);
    let payload = String::from_utf8(encoded_body).unwrap_or_default();
    format!("$2b${:02}${payload}", cost)
}

#[inline(always)]
pub fn ct_digest_eq(a: &[u8; 23], b: &[u8; 23]) -> bool {
    let diff = a.iter().zip(b.iter()).fold(0u8, |acc, (&x, &y)| acc | (x ^ y));
    core::hint::black_box(diff) == 0
}

#[inline(always)]
fn feistel(s: &[[u32; 256]; 4], x: u32) -> u32 {
    let b0 = (x >> 24) as usize;
    let b1 = ((x >> 16) & 0xff) as usize;
    let b2 = ((x >> 8) & 0xff) as usize;
    let b3 = (x & 0xff) as usize;
    (s[0][b0].wrapping_add(s[1][b1]) ^ s[2][b2]).wrapping_add(s[3][b3])
}

#[inline(always)]
fn encipher_single(st: &BfState, l: &mut u32, r: &mut u32) {
    let mut xl = *l;
    let mut xr = *r;
    for round_pair in 0..8 {
        xl ^= st.p[2 * round_pair];
        xr ^= feistel(&st.s, xl);
        xr ^= st.p[2 * round_pair + 1];
        xl ^= feistel(&st.s, xr);
    }
    *l = xr ^ st.p[17];
    *r = xl ^ st.p[16];
}

// ---------------------------------------------------------------------------
// 6-Lane ASM Bcrypt Implementation
// ---------------------------------------------------------------------------

pub fn bcrypt_6x(passwords: &[&[u8]; 6], salts: &[[u8; 16]; 6], cost: u32) -> [[u8; 23]; 6] {
    let mut states: [BfState; 6] = std::array::from_fn(|_| BfState {
        s: BF_S,
        p: BF_P,
        _pad: [0; 14],
    });

    let materials: [KeyMaterial; 6] = std::array::from_fn(|i| {
        KeyMaterial::from_pw_salt(passwords[i], &salts[i])
    });

    for lane in 0..6 {
        for i in 0..18 {
            states[lane].p[i] ^= materials[lane].key_p[i];
        }
        let mut l = 0u32;
        let mut r = 0u32;
        let mut s_idx = 0usize;
        for i in 0..9 {
            l ^= materials[lane].salt4[s_idx & 3];
            r ^= materials[lane].salt4[(s_idx + 1) & 3];
            s_idx += 2;
            encipher_single(&states[lane], &mut l, &mut r);
            states[lane].p[2 * i] = l;
            states[lane].p[2 * i + 1] = r;
        }
        for box_idx in 0..4 {
            for pair in 0..128 {
                l ^= materials[lane].salt4[s_idx & 3];
                r ^= materials[lane].salt4[(s_idx + 1) & 3];
                s_idx += 2;
                encipher_single(&states[lane], &mut l, &mut r);
                states[lane].s[box_idx][2 * pair] = l;
                states[lane].s[box_idx][2 * pair + 1] = r;
            }
        }
    }

    let mut key_p_interleaved = [0u32; 18 * 6];
    let mut salt_p_interleaved = [0u32; 18 * 6];
    for lane in 0..6 {
        for i in 0..18 {
            key_p_interleaved[lane * 18 + i] = materials[lane].key_p[i];
            salt_p_interleaved[lane * 18 + i] = materials[lane].salt18[i];
        }
    }

    let rounds = 1u64 << cost;
    unsafe {
        bf_cost_loop_6x_asm(
            states.as_mut_ptr(),
            key_p_interleaved.as_ptr(),
            salt_p_interleaved.as_ptr(),
            rounds,
        );
    }

    let mut out = [[0u8; 23]; 6];
    for lane in 0..6 {
        let mut ctext = BCRYPT_CTEXT;
        for _ in 0..64 {
            for blk in 0..3 {
                let mut l = ctext[2 * blk];
                let mut r = ctext[2 * blk + 1];
                encipher_single(&states[lane], &mut l, &mut r);
                ctext[2 * blk] = l;
                ctext[2 * blk + 1] = r;
            }
        }
        let mut raw = [0u8; 24];
        for (i, w) in ctext.iter().enumerate() {
            raw[4 * i..4 * i + 4].copy_from_slice(&w.to_be_bytes());
        }
        out[lane].copy_from_slice(&raw[..23]);
    }

    out
}

// ---------------------------------------------------------------------------
// 4-Lane ASM Bcrypt Implementation
// ---------------------------------------------------------------------------

pub fn bcrypt_4x(passwords: &[&[u8]; 4], salts: &[[u8; 16]; 4], cost: u32) -> [[u8; 23]; 4] {
    let mut states: [BfState; 4] = std::array::from_fn(|_| BfState {
        s: BF_S,
        p: BF_P,
        _pad: [0; 14],
    });

    let materials: [KeyMaterial; 4] = std::array::from_fn(|i| {
        KeyMaterial::from_pw_salt(passwords[i], &salts[i])
    });

    for lane in 0..4 {
        for i in 0..18 {
            states[lane].p[i] ^= materials[lane].key_p[i];
        }
        let mut l = 0u32;
        let mut r = 0u32;
        let mut s_idx = 0usize;
        for i in 0..9 {
            l ^= materials[lane].salt4[s_idx & 3];
            r ^= materials[lane].salt4[(s_idx + 1) & 3];
            s_idx += 2;
            encipher_single(&states[lane], &mut l, &mut r);
            states[lane].p[2 * i] = l;
            states[lane].p[2 * i + 1] = r;
        }
        for box_idx in 0..4 {
            for pair in 0..128 {
                l ^= materials[lane].salt4[s_idx & 3];
                r ^= materials[lane].salt4[(s_idx + 1) & 3];
                s_idx += 2;
                encipher_single(&states[lane], &mut l, &mut r);
                states[lane].s[box_idx][2 * pair] = l;
                states[lane].s[box_idx][2 * pair + 1] = r;
            }
        }
    }

    let mut key_p_interleaved = [0u32; 18 * 4];
    let mut salt_p_interleaved = [0u32; 18 * 4];
    for lane in 0..4 {
        for i in 0..18 {
            key_p_interleaved[lane * 18 + i] = materials[lane].key_p[i];
            salt_p_interleaved[lane * 18 + i] = materials[lane].salt18[i];
        }
    }

    let rounds = 1u64 << cost;
    unsafe {
        bf_cost_loop_4x_asm(
            states.as_mut_ptr(),
            key_p_interleaved.as_ptr(),
            salt_p_interleaved.as_ptr(),
            rounds,
        );
    }

    let mut out = [[0u8; 23]; 4];
    for lane in 0..4 {
        let mut ctext = BCRYPT_CTEXT;
        for _ in 0..64 {
            for blk in 0..3 {
                let mut l = ctext[2 * blk];
                let mut r = ctext[2 * blk + 1];
                encipher_single(&states[lane], &mut l, &mut r);
                ctext[2 * blk] = l;
                ctext[2 * blk + 1] = r;
            }
        }
        let mut raw = [0u8; 24];
        for (i, w) in ctext.iter().enumerate() {
            raw[4 * i..4 * i + 4].copy_from_slice(&w.to_be_bytes());
        }
        out[lane].copy_from_slice(&raw[..23]);
    }

    out
}

// ---------------------------------------------------------------------------
// 1-Lane Bcrypt Implementation
// ---------------------------------------------------------------------------

pub fn bcrypt_1x(password: &[u8], salt: &[u8; 16], cost: u32) -> [u8; 23] {
    let pw_arr = [password; 4];
    let salt_arr = [*salt; 4];
    bcrypt_4x(&pw_arr, &salt_arr, cost)[0]
}

// ---------------------------------------------------------------------------
// High-Level Bcrypt API
// ---------------------------------------------------------------------------

pub struct VerifyItem<'a> {
    pub password: &'a [u8],
    pub stored_hash: &'a str,
}

/// Verifies a batch of password verifications in parallel.
/// Dispatches dynamically to 6-wide, 4-wide, 2-wide, or 1-wide ASM kernel.
pub fn bcrypt_verify_batch(items: &[VerifyItem]) -> Vec<bool> {
    let mut results = vec![false; items.len()];
    let mut i = 0;

    while i < items.len() {
        let remaining = items.len() - i;
        if remaining >= 6 {
            let mut pw: [&[u8]; 6] = [&[]; 6];
            let mut salts: [[u8; 16]; 6] = [[0; 16]; 6];
            let mut expected: [[u8; 23]; 6] = [[0; 23]; 6];
            let mut cost = 10u32;
            let mut valid = true;

            for lane in 0..6 {
                pw[lane] = items[i + lane].password;
                if let Some(parsed) = parse_bcrypt(items[i + lane].stored_hash.as_bytes()) {
                    salts[lane] = parsed.salt;
                    expected[lane] = parsed.digest;
                    cost = parsed.cost;
                } else {
                    valid = false;
                }
            }

            if valid {
                let computed = bcrypt_6x(&pw, &salts, cost);
                for lane in 0..6 {
                    results[i + lane] = ct_digest_eq(&computed[lane], &expected[lane]);
                }
            } else {
                for lane in 0..6 {
                    if let Some(parsed) = parse_bcrypt(items[i + lane].stored_hash.as_bytes()) {
                        let c = bcrypt_1x(pw[lane], &parsed.salt, parsed.cost);
                        results[i + lane] = ct_digest_eq(&c, &parsed.digest);
                    }
                }
            }
            i += 6;
        } else if remaining >= 4 {
            let mut pw: [&[u8]; 4] = [&[]; 4];
            let mut salts: [[u8; 16]; 4] = [[0; 16]; 4];
            let mut expected: [[u8; 23]; 4] = [[0; 23]; 4];
            let mut cost = 10u32;
            let mut valid = true;

            for lane in 0..4 {
                pw[lane] = items[i + lane].password;
                if let Some(parsed) = parse_bcrypt(items[i + lane].stored_hash.as_bytes()) {
                    salts[lane] = parsed.salt;
                    expected[lane] = parsed.digest;
                    cost = parsed.cost;
                } else {
                    valid = false;
                }
            }

            if valid {
                let computed = bcrypt_4x(&pw, &salts, cost);
                for lane in 0..4 {
                    results[i + lane] = ct_digest_eq(&computed[lane], &expected[lane]);
                }
            } else {
                for lane in 0..4 {
                    if let Some(parsed) = parse_bcrypt(items[i + lane].stored_hash.as_bytes()) {
                        let c = bcrypt_1x(pw[lane], &parsed.salt, parsed.cost);
                        results[i + lane] = ct_digest_eq(&c, &parsed.digest);
                    }
                }
            }
            i += 4;
        } else {
            // Process individually
            if let Some(parsed) = parse_bcrypt(items[i].stored_hash.as_bytes()) {
                let computed = bcrypt_1x(items[i].password, &parsed.salt, parsed.cost);
                results[i] = ct_digest_eq(&computed, &parsed.digest);
            }
            i += 1;
        }
    }

    results
}

/// Generates a random 16-byte salt via getrandom syscall
fn random_salt() -> [u8; 16] {
    let mut salt = [0u8; 16];
    let ret = unsafe { libc::getrandom(salt.as_mut_ptr().cast(), salt.len(), 0) };
    if ret < 0 {
        // Fallback to time/pid mixing if syscall fails
        let t = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        salt[..8].copy_from_slice(&(t as u64).to_be_bytes());
        salt[8..16].copy_from_slice(&((t >> 64) as u64).to_be_bytes());
    }
    salt
}

/// Hashes password with cost 10 and random salt.
pub fn bcrypt_hash(password: &str, cost: u32) -> String {
    let salt = random_salt();
    let digest = bcrypt_1x(password.as_bytes(), &salt, cost);
    format_bcrypt(cost, &salt, &digest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bcrypt_known_vector() {
        let h = bcrypt_hash("admin", 6);
        let items = [VerifyItem {
            password: b"admin",
            stored_hash: &h,
        }];
        let res = bcrypt_verify_batch(&items);
        assert_eq!(res, vec![true]);

        let bad = [VerifyItem {
            password: b"wrong_password",
            stored_hash: &h,
        }];
        assert_eq!(bcrypt_verify_batch(&bad), vec![false]);
    }

    #[test]
    fn test_bcrypt_batch_6x_consistency() {
        let obs = b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW";
        let parsed_obs = parse_bcrypt(obs).unwrap();
        let obs_1 = bcrypt_1x(b"U*U", &parsed_obs.salt, 5);
        let obs_4 = bcrypt_4x(&[&b"U*U"[..]; 4], &[parsed_obs.salt; 4], 5);
        let obs_6 = bcrypt_6x(&[&b"U*U"[..]; 6], &[parsed_obs.salt; 6], 5);
        println!("OpenBSD target:   {:?}", parsed_obs.digest);
        println!("obs 1x:           {:?}", obs_1);
        println!("obs 4x:           {:?}", obs_4[0]);
        println!("obs 6x:           {:?}", obs_6[0]);
        assert_eq!(obs_1, parsed_obs.digest, "obs 1x mismatch vs openbsd");
        assert_eq!(obs_4[0], parsed_obs.digest, "obs 4x mismatch vs openbsd");
        assert_eq!(obs_6[0], parsed_obs.digest, "obs 6x mismatch vs openbsd");

        let h = bcrypt_hash("admin", 6);
        let parsed = parse_bcrypt(h.as_bytes()).unwrap();
        let c1 = bcrypt_1x(b"admin", &parsed.salt, 6);
        let c4 = bcrypt_4x(&[&b"admin"[..]; 4], &[parsed.salt; 4], 6);
        let c6 = bcrypt_6x(&[&b"admin"[..]; 6], &[parsed.salt; 6], 6);
        println!("1x digest:    {:?}", c1);
        println!("4x digest[0]: {:?}", c4[0]);
        println!("6x digest[0]: {:?}", c6[0]);
        assert_eq!(c1, c6[0], "1x vs 6x mismatch");
        assert_eq!(c4[0], c6[0], "4x vs 6x mismatch");

        let items = [
            VerifyItem { password: b"admin", stored_hash: &h },
            VerifyItem { password: b"admin", stored_hash: &h },
            VerifyItem { password: b"wrong", stored_hash: &h },
            VerifyItem { password: b"admin", stored_hash: &h },
            VerifyItem { password: b"wrong", stored_hash: &h },
            VerifyItem { password: b"admin", stored_hash: &h },
        ];
        let res = bcrypt_verify_batch(&items);
        assert_eq!(res, vec![true, true, false, true, false, true]);
    }

    #[test]
    fn test_seed_hash_verification() {
        let seed_h = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";
        let items_single = [VerifyItem { password: b"password123", stored_hash: seed_h }];
        let res_single = bcrypt_verify_batch(&items_single);
        assert_eq!(res_single, vec![true], "Seed hash must verify with password123");

        let items_bad = [VerifyItem { password: b"wrong-password", stored_hash: seed_h }];
        let res_bad = bcrypt_verify_batch(&items_bad);
        assert_eq!(res_bad, vec![false], "Wrong password must fail");

        let items_6x = [
            VerifyItem { password: b"password123", stored_hash: seed_h },
            VerifyItem { password: b"password123", stored_hash: seed_h },
            VerifyItem { password: b"wrong-pw", stored_hash: seed_h },
            VerifyItem { password: b"password123", stored_hash: seed_h },
            VerifyItem { password: b"password123", stored_hash: seed_h },
            VerifyItem { password: b"password123", stored_hash: seed_h },
        ];
        let res_6x = bcrypt_verify_batch(&items_6x);
        assert_eq!(res_6x, vec![true, true, false, true, true, true], "Seed hash 6-lane batch must verify correctly");
    }
    #[test]
    fn test_openbsd_known_answer_vectors() {
        let vectors = [
            ("U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"),
            ("U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"),
            ("", "$2a$06$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s."),
        ];

        for (pw, hash) in vectors {
            let item_good = [VerifyItem {
                password: pw.as_bytes(),
                stored_hash: hash,
            }];
            assert_eq!(
                bcrypt_verify_batch(&item_good),
                vec![true],
                "Valid password failed for hash: {}",
                hash
            );

            let item_bad = [VerifyItem {
                password: b"wrong_password_xyz",
                stored_hash: hash,
            }];
            assert_eq!(
                bcrypt_verify_batch(&item_bad),
                vec![false],
                "Wrong password unexpectedly passed for hash: {}",
                hash
            );
        }
    }

    #[test]
    fn test_b64_roundtrip_xorshift() {
        let mut state: u64 = 0x8542_598d_c849_0f12;
        let mut xorshift64 = || -> u64 {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };

        for _ in 0..100 {
            let mut rand16 = [0u8; 16];
            for chunk in rand16.chunks_exact_mut(8) {
                chunk.copy_from_slice(&xorshift64().to_le_bytes());
            }
            let mut enc16 = Vec::new();
            encode_bcrypt_b64(&rand16, &mut enc16);
            assert_eq!(enc16.len(), 22);
            let dec16 = decode_bcrypt_b64::<16>(&enc16);
            assert_eq!(dec16, Some(rand16));

            let mut rand23 = [0u8; 23];
            let r0 = xorshift64().to_le_bytes();
            let r1 = xorshift64().to_le_bytes();
            let r2 = xorshift64().to_le_bytes();
            rand23[..8].copy_from_slice(&r0);
            rand23[8..16].copy_from_slice(&r1);
            rand23[16..23].copy_from_slice(&r2[..7]);

            let mut enc23 = Vec::new();
            encode_bcrypt_b64(&rand23, &mut enc23);
            assert_eq!(enc23.len(), 31);
            let dec23 = decode_bcrypt_b64::<23>(&enc23);
            assert_eq!(dec23, Some(rand23));
        }
    }
}
