//! High-throughput Bcrypt (cost=10) password hashing and verification.

use super::blowfish::BlowfishState;

const BCRYPT_RADIX64: &[u8; 64] =
    b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

const ORPHEAN_WORDS: [u32; 6] = [
    0x4f727068, // "Orph"
    0x65616e42, // "eanB"
    0x65686f6c, // "ehol"
    0x64657253, // "derS"
    0x63727944, // "cryD"
    0x6f756274, // "oubt"
];

fn b64_char_to_val(c: u8) -> Result<u8, ()> {
    match c {
        b'.' => Ok(0),
        b'/' => Ok(1),
        b'A'..=b'Z' => Ok(c - b'A' + 2),
        b'a'..=b'z' => Ok(c - b'a' + 28),
        b'0'..=b'9' => Ok(c - b'0' + 54),
        _ => Err(()),
    }
}

/// Decodes 22 bcrypt base64 chars into 16 bytes of salt.
pub fn decode_salt(b64: &[u8]) -> Result<[u8; 16], ()> {
    if b64.len() != 22 {
        return Err(());
    }

    let mut out = [0u8; 16];
    let mut v = [0u8; 22];
    for (i, &c) in b64.iter().enumerate() {
        v[i] = b64_char_to_val(c)?;
    }

    let mut out_idx = 0;
    let mut in_idx = 0;
    while in_idx + 4 <= 20 {
        let b0 = v[in_idx];
        let b1 = v[in_idx + 1];
        let b2 = v[in_idx + 2];
        let b3 = v[in_idx + 3];

        out[out_idx] = (b0 << 2) | (b1 >> 4);
        out[out_idx + 1] = ((b1 & 0xf) << 4) | (b2 >> 2);
        out[out_idx + 2] = ((b2 & 0x3) << 6) | b3;

        out_idx += 3;
        in_idx += 4;
    }

    let b0 = v[20];
    let b1 = v[21];
    out[15] = (b0 << 2) | (b1 >> 4);

    Ok(out)
}

/// Encodes 16 bytes of salt into 22 bcrypt base64 chars.
pub fn encode_salt(salt: &[u8; 16]) -> [u8; 22] {
    let mut out = [0u8; 22];
    let mut out_idx = 0;
    let mut in_idx = 0;

    while in_idx + 3 <= 15 {
        let c0 = salt[in_idx];
        let c1 = salt[in_idx + 1];
        let c2 = salt[in_idx + 2];

        out[out_idx] = BCRYPT_RADIX64[(c0 >> 2) as usize];
        out[out_idx + 1] = BCRYPT_RADIX64[(((c0 & 0x3) << 4) | (c1 >> 4)) as usize];
        out[out_idx + 2] = BCRYPT_RADIX64[(((c1 & 0xf) << 2) | (c2 >> 6)) as usize];
        out[out_idx + 3] = BCRYPT_RADIX64[(c2 & 0x3f) as usize];

        out_idx += 4;
        in_idx += 3;
    }

    let c0 = salt[15];
    out[20] = BCRYPT_RADIX64[(c0 >> 2) as usize];
    out[21] = BCRYPT_RADIX64[((c0 & 0x3) << 4) as usize];

    out
}

/// Encodes 24 ciphertext bytes (6 words) into 31 bcrypt base64 chars.
fn encode_ciphertext(words: &[u32; 6]) -> [u8; 31] {
    let mut raw = [0u8; 24];
    for (i, &w) in words.iter().enumerate() {
        raw[i * 4] = (w >> 24) as u8;
        raw[i * 4 + 1] = (w >> 16) as u8;
        raw[i * 4 + 2] = (w >> 8) as u8;
        raw[i * 4 + 3] = w as u8;
    }

    let mut out = [0u8; 31];
    let mut out_idx = 0;
    let mut in_idx = 0;

    while in_idx < 24 {
        let c0 = raw[in_idx];
        let c1 = raw[in_idx + 1];
        let c2 = if in_idx + 2 < 24 { raw[in_idx + 2] } else { 0 };

        out[out_idx] = BCRYPT_RADIX64[(c0 >> 2) as usize];
        out[out_idx + 1] = BCRYPT_RADIX64[(((c0 & 0x3) << 4) | (c1 >> 4)) as usize];
        if in_idx + 2 < 24 {
            out[out_idx + 2] = BCRYPT_RADIX64[(((c1 & 0xf) << 2) | (c2 >> 6)) as usize];
            out[out_idx + 3] = BCRYPT_RADIX64[(c2 & 0x3f) as usize];
            out_idx += 4;
        } else {
            out[out_idx + 2] = BCRYPT_RADIX64[((c1 & 0xf) << 2) as usize];
            out_idx += 3;
        }
        in_idx += 3;
    }

    out
}

/// Computes the bcrypt digest for the given password, cost, and 16-byte salt.
pub fn compute_digest(password: &[u8], salt: &[u8; 16], cost: u32) -> [u8; 31] {
    let mut key = Vec::with_capacity(password.len().min(71) + 1);
    key.extend_from_slice(&password[..password.len().min(72)]);
    if key.len() < 72 {
        key.push(0);
    }

    let mut state = BlowfishState::new();
    state.expand_key(salt, &key);

    let rounds = 1u32 << cost;
    for _ in 0..rounds {
        state.expand_key(&[], &key);
        state.expand_key(&[], salt);
    }

    let mut w = ORPHEAN_WORDS;
    for _ in 0..64 {
        let (nl0, nr0) = state.enc(w[0], w[1]);
        w[0] = nl0;
        w[1] = nr0;

        let (nl1, nr1) = state.enc(w[2], w[3]);
        w[2] = nl1;
        w[3] = nr1;

        let (nl2, nr2) = state.enc(w[4], w[5]);
        w[4] = nl2;
        w[5] = nr2;
    }

    encode_ciphertext(&w)
}

/// Hashes password with cost=10 and a secure random 16-byte salt.
pub fn hash_password(password: &str) -> String {
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).expect("RNG failure");

    let salt_b64 = encode_salt(&salt);
    let cipher_b64 = compute_digest(password.as_bytes(), &salt, 10);

    let mut out = String::with_capacity(60);
    out.push_str("$2b$10$");
    out.push_str(std::str::from_utf8(&salt_b64).unwrap());
    out.push_str(std::str::from_utf8(&cipher_b64).unwrap());
    out
}

/// Verifies a password against a standard modular crypt bcrypt hash ($2a$ / $2b$).
pub fn verify_password(password: &str, stored_hash: &str) -> bool {
    let bytes = stored_hash.as_bytes();
    if bytes.len() != 60 || &bytes[0..4] != b"$2a$" && &bytes[0..4] != b"$2b$" {
        return false;
    }

    let cost_str = std::str::from_utf8(&bytes[4..6]).unwrap_or("");
    let cost: u32 = match cost_str.parse() {
        Ok(c) if (4..=31).contains(&c) => c,
        _ => return false,
    };

    if bytes[6] != b'$' {
        return false;
    }

    let salt_slice = &bytes[7..29];
    let cipher_slice = &bytes[29..60];

    let salt = match decode_salt(salt_slice) {
        Ok(s) => s,
        Err(_) => return false,
    };

    let computed = compute_digest(password.as_bytes(), &salt, cost);

    // Constant-time slice comparison
    let mut diff = 0u8;
    for (a, b) in computed.iter().zip(cipher_slice.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}
