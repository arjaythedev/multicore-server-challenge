//! The EksBlowfish key schedule and the bcrypt digest, for `N` lanes in lockstep.
//!
//! All lanes in one call share the cost (they run the same number of rounds); passwords and salts differ.
//! Passwords longer than 72 bytes are truncated, as in OpenBSD and the `$2a$`/`$2b$` formats.

// Lane loops index several parallel per-lane arrays by the same constant `i`; this is clearer than zipping
// four iterators and compiles to the same unrolled code.
#![allow(clippy::needless_range_loop)]

use super::blowfish::{Lanes, P_WORDS, S_BOXES, S_WORDS};

/// Bytes of key material bcrypt uses: 18 P-array words.
const KEY_BYTES: usize = P_WORDS * 4;
/// Words in the 128-bit salt.
const SALT_WORDS: usize = 4;
/// Times the magic text is encrypted in ECB mode.
const CIPHER_ROUNDS: usize = 64;
/// "OrpheanBeholderScryDoubt" as six big-endian words.
const MAGIC: [u32; 6] = [
    0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274,
];
/// Digest length that bcrypt keeps of the 24 cipher bytes.
pub const DIGEST_BYTES: usize = 23;

/// Key words of one lane: key bytes extended cyclically to 72 bytes and read as big-endian words.
pub type KeyWords = [u32; P_WORDS];

/// Builds the key words for a password: `password || NUL`, truncated to 72 bytes, repeated to fill 72 bytes.
///
/// A password of 72 bytes or more has no room for the NUL, as in OpenBSD's `$2b$`. Embedded NULs in
/// the password are kept (the server stores passwords as UTF-8 strings, not C strings).
pub fn key_words(password: &[u8]) -> KeyWords {
    let used = password.len().min(KEY_BYTES);
    let key_len = (used + 1).min(KEY_BYTES); // password bytes plus the NUL, if it fits
    let mut words = [0u32; P_WORDS];
    let mut pos = 0;
    for word in &mut words {
        for _ in 0..4 {
            let byte = if pos < used { password[pos] } else { 0 };
            *word = (*word << 8) | u32::from(byte);
            pos = (pos + 1) % key_len;
        }
    }
    words
}

/// Salt as four big-endian words.
pub fn salt_words(salt: &[u8; 16]) -> [u32; SALT_WORDS] {
    let mut words = [0u32; SALT_WORDS];
    for (word, chunk) in words.iter_mut().zip(salt.as_chunks::<4>().0) {
        *word = u32::from_be_bytes(*chunk);
    }
    words
}

/// The salt stretched cyclically to 18 words: it acts as the "key" of the `ExpandKey(state, 0, salt)` step.
fn salt_as_key(salt: &[u32; SALT_WORDS]) -> KeyWords {
    let mut words = [0u32; P_WORDS];
    for (i, word) in words.iter_mut().enumerate() {
        *word = salt[i % SALT_WORDS];
    }
    words
}

/// `ExpandKey(state, salt, key)`: XOR the key into the P-array, then replace P and the S-boxes by a chain of
/// encryptions, where each plaintext block is the previous ciphertext XOR two salt words (alternating pairs).
/// A salt of zero gives the plain Blowfish key schedule.
pub fn expand_key<const N: usize>(
    st: &mut Lanes<N>,
    key: &[KeyWords; N],
    salt: &[[u32; SALT_WORDS]; N],
) {
    for i in 0..N {
        for w in 0..P_WORDS {
            st.p[i][w] ^= key[i][w];
        }
    }
    let (mut l, mut r) = ([0u32; N], [0u32; N]);
    let mut salt_pos = 0; // 0 or 2: which pair of salt words goes into this block
    for pair in 0..P_WORDS / 2 {
        chain_block(st, &mut l, &mut r, salt, &mut salt_pos);
        for i in 0..N {
            st.p[i][2 * pair] = l[i];
            st.p[i][2 * pair + 1] = r[i];
        }
    }
    for sbox in 0..S_BOXES {
        for pair in 0..S_WORDS / 2 {
            chain_block(st, &mut l, &mut r, salt, &mut salt_pos);
            for i in 0..N {
                st.s[i][sbox][2 * pair] = l[i];
                st.s[i][sbox][2 * pair + 1] = r[i];
            }
        }
    }
}

/// One link of the `ExpandKey` chain: XOR the next salt pair into the running block and encrypt it.
#[inline(always)]
fn chain_block<const N: usize>(
    st: &Lanes<N>,
    l: &mut [u32; N],
    r: &mut [u32; N],
    salt: &[[u32; SALT_WORDS]; N],
    salt_pos: &mut usize,
) {
    for i in 0..N {
        l[i] ^= salt[i][*salt_pos];
        r[i] ^= salt[i][*salt_pos + 1];
    }
    *salt_pos ^= 2;
    st.encrypt(l, r);
}

/// Raw bcrypt digests of `N` (password, salt) pairs that share `cost`.
pub fn digest<const N: usize>(
    passwords: [&[u8]; N],
    salts: &[[u8; 16]; N],
    cost: u32,
) -> [[u8; DIGEST_BYTES]; N] {
    let keys: [KeyWords; N] = std::array::from_fn(|i| key_words(passwords[i]));
    let salts: [[u32; SALT_WORDS]; N] = std::array::from_fn(|i| salt_words(&salts[i]));
    let salt_keys: [KeyWords; N] = std::array::from_fn(|i| salt_as_key(&salts[i]));
    let no_salt = [[0u32; SALT_WORDS]; N];

    let mut st = Lanes::<N>::new();
    expand_key(&mut st, &keys, &salts);
    for _ in 0..(1u64 << cost) {
        expand_key(&mut st, &keys, &no_salt);
        expand_key(&mut st, &salt_keys, &no_salt);
    }
    encrypt_magic(&st)
}

/// Encrypts "OrpheanBeholderScryDoubt" 64 times in ECB mode and keeps the first 23 bytes.
fn encrypt_magic<const N: usize>(st: &Lanes<N>) -> [[u8; DIGEST_BYTES]; N] {
    let mut text = [[0u32; 6]; N];
    text.fill(MAGIC);
    for _ in 0..CIPHER_ROUNDS {
        for block in 0..3 {
            let mut l: [u32; N] = std::array::from_fn(|i| text[i][2 * block]);
            let mut r: [u32; N] = std::array::from_fn(|i| text[i][2 * block + 1]);
            st.encrypt(&mut l, &mut r);
            for i in 0..N {
                text[i][2 * block] = l[i];
                text[i][2 * block + 1] = r[i];
            }
        }
    }
    std::array::from_fn(|i| {
        let mut bytes = [0u8; 24];
        for (word, chunk) in text[i].iter().zip(bytes.as_chunks_mut::<4>().0) {
            *chunk = word.to_be_bytes();
        }
        let mut out = [0u8; DIGEST_BYTES];
        out.copy_from_slice(&bytes[..DIGEST_BYTES]);
        out
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_words_append_nul_and_wrap() {
        // "ab" + NUL repeats: ab\0a b\0a b\0a ...
        let k = key_words(b"ab");
        assert_eq!(k[0], u32::from_be_bytes(*b"ab\0a"));
        assert_eq!(k[1], u32::from_be_bytes(*b"b\0ab"));
        assert_eq!(k[17], u32::from_be_bytes(*b"\0ab\0"));
    }

    #[test]
    fn empty_password_is_all_zero_key() {
        assert_eq!(key_words(b""), [0; P_WORDS]);
    }

    #[test]
    fn long_passwords_are_cut_at_72_bytes() {
        let long = [b'x'; 100];
        assert_eq!(key_words(&long), key_words(&long[..72]));
        // 71 bytes still gets its NUL as the 72nd byte, 72 bytes does not.
        assert_ne!(key_words(&long[..71]), key_words(&long[..72]));
    }
}
