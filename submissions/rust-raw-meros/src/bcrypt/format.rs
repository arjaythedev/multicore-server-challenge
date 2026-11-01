//! The textual bcrypt hash format: `$2a$NN$<22 salt chars><31 digest chars>` (60 bytes).
//!
//! bcrypt has its own base64 alphabet (`./A-Za-z0-9`) without padding. Prefixes `$2a$`, `$2b$` and `$2y$`
//! are accepted when parsing (they differ only in historical bug handling that does not affect our inputs);
//! we always write `$2a$`. `$2x$` and `$2$` are not accepted.

/// Length of a complete hash string.
pub const HASH_LEN: usize = 60;
/// Smallest and largest cost accepted when parsing.
pub const MIN_COST: u32 = 4;
pub const MAX_COST: u32 = 20;
const SALT_BYTES: usize = 16;
const DIGEST_BYTES: usize = 23;
const SALT_CHARS: usize = 22;
const ALPHABET: &[u8; 64] = b"./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
const INVALID: u8 = 0xff;
/// Offsets inside the 60-byte string.
const COST_AT: usize = 4;
const SALT_AT: usize = 7;
const DIGEST_AT: usize = SALT_AT + SALT_CHARS;

/// A decoded stored hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed {
    pub cost: u32,
    pub salt: [u8; SALT_BYTES],
    pub digest: [u8; DIGEST_BYTES],
}

/// Character to 6-bit value, built at compile time.
const DECODE: [u8; 256] = {
    let mut table = [INVALID; 256];
    let mut i = 0;
    while i < 64 {
        table[ALPHABET[i] as usize] = i as u8;
        i += 1;
    }
    table
};

/// Parses a stored hash. Returns `None` for anything malformed (wrong length, prefix, cost or alphabet).
pub fn parse(hash: &[u8]) -> Option<Parsed> {
    if hash.len() != HASH_LEN || hash[0] != b'$' || hash[1] != b'2' || hash[3] != b'$' {
        return None;
    }
    if !matches!(hash[2], b'a' | b'b' | b'y') || hash[COST_AT + 2] != b'$' {
        return None;
    }
    let (tens, ones) = (hash[COST_AT], hash[COST_AT + 1]);
    if !tens.is_ascii_digit() || !ones.is_ascii_digit() {
        return None;
    }
    let cost = u32::from(tens - b'0') * 10 + u32::from(ones - b'0');
    if !(MIN_COST..=MAX_COST).contains(&cost) {
        return None;
    }
    let salt = decode::<SALT_BYTES>(&hash[SALT_AT..DIGEST_AT])?;
    let digest = decode::<DIGEST_BYTES>(&hash[DIGEST_AT..])?;
    Some(Parsed { cost, salt, digest })
}

/// Writes the `$2a$` form of a hash.
pub fn encode(cost: u32, salt: &[u8; SALT_BYTES], digest: &[u8; DIGEST_BYTES]) -> [u8; HASH_LEN] {
    let mut out = [0u8; HASH_LEN];
    out[..4].copy_from_slice(b"$2a$");
    out[COST_AT] = b'0' + (cost / 10 % 10) as u8;
    out[COST_AT + 1] = b'0' + (cost % 10) as u8;
    out[COST_AT + 2] = b'$';
    encode_into(salt, &mut out[SALT_AT..DIGEST_AT]);
    encode_into(digest, &mut out[DIGEST_AT..]);
    out
}

/// Base64 without padding, most significant bits first. `out` must hold `ceil(bytes * 8 / 6)` characters.
fn encode_into(bytes: &[u8], out: &mut [u8]) {
    let mut acc = 0u32;
    let mut bits = 0;
    let mut o = 0;
    for &byte in bytes {
        acc = (acc << 8) | u32::from(byte);
        bits += 8;
        while bits >= 6 {
            bits -= 6;
            out[o] = ALPHABET[((acc >> bits) & 0x3f) as usize];
            o += 1;
        }
    }
    if bits > 0 {
        out[o] = ALPHABET[((acc << (6 - bits)) & 0x3f) as usize];
    }
}

/// Decodes exactly `ceil(B * 8 / 6)` characters into `B` bytes. Spare bits of the last character are
/// ignored, as OpenBSD does (the 22nd salt character carries only 4 bits).
fn decode<const B: usize>(chars: &[u8]) -> Option<[u8; B]> {
    let mut out = [0u8; B];
    let mut acc = 0u32;
    let mut bits = 0;
    let mut o = 0;
    for &c in chars {
        let v = DECODE[c as usize];
        if v == INVALID {
            return None;
        }
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 && o < B {
            bits -= 8;
            out[o] = (acc >> bits) as u8;
            o += 1;
        }
    }
    (o == B).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &[u8] = b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW";

    #[test]
    fn lengths_match_constants() {
        const DIGEST_CHARS: usize = 31;
        assert_eq!(SALT_CHARS, (SALT_BYTES * 8).div_ceil(6));
        assert_eq!(DIGEST_CHARS, (DIGEST_BYTES * 8).div_ceil(6));
        assert_eq!(SAMPLE.len(), HASH_LEN);
    }

    #[test]
    fn round_trips() {
        let p = parse(SAMPLE).unwrap();
        assert_eq!(p.cost, 5);
        assert_eq!(&encode(p.cost, &p.salt, &p.digest)[..], SAMPLE);
    }

    #[test]
    fn accepts_other_prefixes() {
        for prefix in [b"2b", b"2y"] {
            let mut h = SAMPLE.to_vec();
            h[1..3].copy_from_slice(prefix);
            assert_eq!(parse(&h), parse(SAMPLE));
        }
    }

    #[test]
    fn rejects_malformed() {
        assert!(parse(b"").is_none());
        assert!(parse(&SAMPLE[..59]).is_none());
        let mut h = SAMPLE.to_vec();
        h[2] = b'x';
        assert!(parse(&h).is_none());
        let mut h = SAMPLE.to_vec();
        h[4..6].copy_from_slice(b"03");
        assert!(parse(&h).is_none());
        h[4..6].copy_from_slice(b"21");
        assert!(parse(&h).is_none());
        let mut h = SAMPLE.to_vec();
        h[30] = b'!';
        assert!(parse(&h).is_none());
        let mut h = SAMPLE.to_vec();
        h[6] = b'#';
        assert!(parse(&h).is_none());
    }

    #[test]
    fn last_salt_char_ignores_spare_bits() {
        // The last salt character holds 4 salt bits and 2 spare ones: '.' (0) and 'B' (3) differ in the spare.
        let mut a = SAMPLE.to_vec();
        let mut b = SAMPLE.to_vec();
        a[DIGEST_AT - 1] = b'.';
        b[DIGEST_AT - 1] = b'B';
        assert_eq!(parse(&a).unwrap().salt, parse(&b).unwrap().salt);
    }
}
