//! Keyed-Hashing for Message Authentication (HMAC) per RFC 2104 using SHA-256.

use crate::sec::sha256::{compress_block, sha256, Sha256, SHA256_H0};

#[derive(Clone, Copy, Debug)]
pub struct PrecomputedHmac {
    inner_mid: [u32; 8],
    outer_mid: [u32; 8],
}

impl PrecomputedHmac {
    pub fn new(key: &[u8]) -> Self {
        let (mut inner_mid, mut outer_mid) = (SHA256_H0, SHA256_H0);
        let mut ipad = [0x36u8; 64];
        let mut opad = [0x5cu8; 64];
        let hashed_key;
        let effective_key = if key.len() > 64 {
            hashed_key = sha256(key);
            &hashed_key[..]
        } else {
            key
        };
        let mut i = 0;
        while i < effective_key.len() {
            ipad[i] ^= effective_key[i];
            opad[i] ^= effective_key[i];
            i += 1;
        }
        compress_block(&mut inner_mid, &ipad);
        compress_block(&mut outer_mid, &opad);
        Self { inner_mid, outer_mid }
    }

    pub fn sign(&self, data: &[u8]) -> [u8; 32] {
        let mut inner_hasher = Sha256::resume(self.inner_mid, 64);
        inner_hasher.update(data);
        let inner_digest = inner_hasher.finish();

        let mut outer_hasher = Sha256::resume(self.outer_mid, 64);
        outer_hasher.update(&inner_digest);
        outer_hasher.finish()
    }
}

pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    PrecomputedHmac::new(key).sign(msg)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex_bytes_32(s: &str) -> [u8; 32] {
        let mut res = [0u8; 32];
        let b = s.as_bytes();
        let mut idx = 0;
        while idx < 32 {
            let high = match b[idx * 2] {
                b'0'..=b'9' => b[idx * 2] - b'0',
                b'a'..=b'f' => b[idx * 2] - b'a' + 10,
                _ => 0,
            };
            let low = match b[idx * 2 + 1] {
                b'0'..=b'9' => b[idx * 2 + 1] - b'0',
                b'a'..=b'f' => b[idx * 2 + 1] - b'a' + 10,
                _ => 0,
            };
            res[idx] = (high << 4) | low;
            idx += 1;
        }
        res
    }

    #[test]
    fn test_rfc4231_case1() {
        let key = [0x0bu8; 20];
        let data = b"Hi There";
        let exp = hex_bytes_32("b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");
        assert_eq!(hmac_sha256(&key, data), exp);
    }

    #[test]
    fn test_rfc4231_case2() {
        let exp = hex_bytes_32("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");
        assert_eq!(hmac_sha256(b"Jefe", b"what do ya want for nothing?"), exp);
    }

    #[test]
    fn test_rfc4231_case6() {
        let key = [0xaau8; 131];
        let data = b"Test Using Larger Than Block-Size Key - Hash Key First";
        let exp = hex_bytes_32("60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54");
        assert_eq!(hmac_sha256(&key, data), exp);
    }
}
