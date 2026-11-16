//! HMAC-SHA-256 implementation with midstate caching for ultra-fast token verification & SCRAM auth.

use crate::sec::sha256::{sha256_digest, sha256_with_state, state_to_bytes, compress_block, SHA256_H0};

/// Precomputed HMAC-SHA256 states for fixed keys (avoids recomputing ipad/opad blocks on each request).
#[derive(Clone, Copy)]
pub struct PrecomputedHmac {
    pub inner_state: [u32; 8],
    pub outer_state: [u32; 8],
}

impl PrecomputedHmac {
    pub fn new(key: &[u8]) -> Self {
        let mut key_block = [0u8; 64];
        if key.len() > 64 {
            let digest = sha256_digest(key);
            key_block[..32].copy_from_slice(&digest);
        } else {
            key_block[..key.len()].copy_from_slice(key);
        }

        let mut ipad = [0u8; 64];
        let mut opad = [0u8; 64];
        for i in 0..64 {
            ipad[i] = key_block[i] ^ 0x36;
            opad[i] = key_block[i] ^ 0x5c;
        }

        let mut inner_state = SHA256_H0;
        compress_block(&mut inner_state, &ipad);

        let mut outer_state = SHA256_H0;
        compress_block(&mut outer_state, &opad);

        PrecomputedHmac {
            inner_state,
            outer_state,
        }
    }

    #[inline(always)]
    pub fn sign(&self, data: &[u8]) -> [u8; 32] {
        let inner_hash = state_to_bytes(&sha256_with_state(self.inner_state, 64, data));
        state_to_bytes(&sha256_with_state(self.outer_state, 64, &inner_hash))
    }
}

/// Computes HMAC-SHA256 of `msg` using `key`.
pub fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let hmac = PrecomputedHmac::new(key);
    hmac.sign(msg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rfc4231_case1() {
        let key = [0x0b; 20];
        let data = b"Hi There";
        let expected = [
            0xb0, 0x34, 0x4c, 0x61, 0xd8, 0xdb, 0x38, 0x53,
            0x5c, 0xa8, 0xaf, 0xce, 0xaf, 0x0b, 0xf1, 0x2b,
            0x88, 0x1d, 0xc2, 0x00, 0xc9, 0x83, 0x3d, 0xa7,
            0x26, 0xe9, 0x37, 0x6c, 0x2e, 0x32, 0xcf, 0xf7,
        ];
        assert_eq!(hmac_sha256(&key, data), expected);
    }

    #[test]
    fn test_rfc4231_case2() {
        let key = b"Jefe";
        let data = b"what do ya want for nothing?";
        let expected = [
            0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e,
            0x6a, 0x04, 0x24, 0x26, 0x08, 0x95, 0x75, 0xc7,
            0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83,
            0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43,
        ];
        assert_eq!(hmac_sha256(key, data), expected);
    }
}
