//! HMAC-SHA-256 (RFC 2104 / RFC 4231).
//!
//! The key is hashed into the inner and outer pad blocks once in [`HmacSha256::new`]; each [`HmacSha256::mac`]
//! then starts from those two saved states, so a MAC of a short message costs the message blocks plus one block
//! for the outer hash, never the two pad blocks. This matters for JWT (same secret on every request) and PBKDF2
//! (thousands of MACs per key). The copies of a 64-byte buffer a hasher makes per MAC are small next to a
//! compression, so there is no special fixed-size fast path.

use super::sha256::{BLOCK_LEN, DIGEST_LEN, Sha256, digest};

const INNER_PAD: u8 = 0x36;
const OUTER_PAD: u8 = 0x5c;

/// HMAC-SHA-256 keyed once, usable for any number of messages.
#[derive(Clone)]
pub struct HmacSha256 {
    /// State after absorbing `key ^ ipad`.
    inner: Sha256,
    /// State after absorbing `key ^ opad`.
    outer: Sha256,
}

impl HmacSha256 {
    /// Keys the MAC. Keys longer than one block are hashed first, as the RFC requires.
    pub fn new(key: &[u8]) -> Self {
        let mut block = [0u8; BLOCK_LEN];
        if key.len() > BLOCK_LEN {
            block[..DIGEST_LEN].copy_from_slice(&digest(key));
        } else {
            block[..key.len()].copy_from_slice(key);
        }
        HmacSha256 {
            inner: pad_state(&block, INNER_PAD),
            outer: pad_state(&block, OUTER_PAD),
        }
    }

    /// MAC of the concatenation of `parts`, without building the concatenation.
    pub fn mac(&self, parts: &[&[u8]]) -> [u8; DIGEST_LEN] {
        let mut inner = self.inner.clone();
        for part in parts {
            inner.update(part);
        }
        let mut outer = self.outer.clone();
        outer.update(&inner.finalize());
        outer.finalize()
    }
}

/// Hasher that has already absorbed `key_block ^ pad`.
fn pad_state(key_block: &[u8; BLOCK_LEN], pad: u8) -> Sha256 {
    let mut padded = *key_block;
    for byte in &mut padded {
        *byte ^= pad;
    }
    let mut hasher = Sha256::new();
    hasher.update(&padded);
    hasher
}

/// One-shot HMAC-SHA-256.
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; DIGEST_LEN] {
    HmacSha256::new(key).mac(&[msg])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// RFC 4231 test cases 1, 2, 3, 4, 6 and 7 (case 5 is a truncated MAC, not covered).
    #[test]
    fn rfc4231_vectors() {
        let cases: [(Vec<u8>, Vec<u8>, &str); 6] = [
            (
                vec![0x0b; 20],
                b"Hi There".to_vec(),
                "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7",
            ),
            (
                b"Jefe".to_vec(),
                b"what do ya want for nothing?".to_vec(),
                "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
            ),
            (
                vec![0xaa; 20],
                vec![0xdd; 50],
                "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe",
            ),
            (
                (1..=25).collect(),
                vec![0xcd; 50],
                "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b",
            ),
            (
                vec![0xaa; 131],
                b"Test Using Larger Than Block-Size Key - Hash Key First".to_vec(),
                "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54",
            ),
            (
                vec![0xaa; 131],
                b"This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."
                    .to_vec(),
                "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2",
            ),
        ];
        for (key, msg, expected) in cases {
            assert_eq!(hex(&hmac_sha256(&key, &msg)), expected);
        }
    }

    #[test]
    fn parts_equal_concatenation_and_key_is_reusable() {
        let mac = HmacSha256::new(b"secret");
        let whole = mac.mac(&[b"hello world"]);
        assert_eq!(mac.mac(&[b"hello", b" ", b"world"]), whole);
        assert_eq!(mac.mac(&[b"hello world"]), whole);
        assert_eq!(mac.mac(&[b"", b"hello world", b""]), whole);
    }
}
