//! SCRAM-SHA-256 cryptographic primitives for PostgreSQL authentication (RFC 5802 / RFC 7677).

use crate::sec::hmac::PrecomputedHmac;
pub use crate::sec::sha256::sha256;
pub use crate::sec::hmac::hmac_sha256;

/// Computes PBKDF2-HMAC-SHA256 (RFC 2898 / RFC 5802 Hi function).
/// Used by PostgreSQL SCRAM-SHA-256 authentication:
/// SaltedPassword := Hi(Normalize(password), salt, iterations)
pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32, out: &mut [u8; 32]) {
    assert!(iterations > 0, "iterations must be >= 1");
    let hmac = PrecomputedHmac::new(password);

    // U_1 = HMAC(password, salt || INT(1))
    let mut initial_msg = Vec::with_capacity(salt.len() + 4);
    initial_msg.extend_from_slice(salt);
    initial_msg.extend_from_slice(&[0, 0, 0, 1]);

    let mut u = hmac.sign(&initial_msg);
    let mut t = u;

    // U_j = HMAC(password, U_{j-1}), T = T ^ U_j
    for _ in 1..iterations {
        u = hmac.sign(&u);
        for i in 0..32 {
            t[i] ^= u[i];
        }
    }

    out.copy_from_slice(&t);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_pbkdf2_sha256_vectors() {
        let mut dk = [0u8; 32];

        // Case 1: P = "password", S = "salt", c = 1
        pbkdf2_hmac_sha256(b"password", b"salt", 1, &mut dk);
        let expected1: [u8; 32] = [
            0x12, 0x0f, 0xb6, 0xcf, 0xfc, 0xf8, 0xb3, 0x2c,
            0x43, 0xe7, 0x22, 0x52, 0x56, 0xc4, 0xf8, 0x37,
            0xa8, 0x65, 0x48, 0xc9, 0x2c, 0xcc, 0x35, 0x48,
            0x08, 0x05, 0x98, 0x7c, 0xb7, 0x0b, 0xe1, 0x7b,
        ];
        assert_eq!(dk, expected1, "PBKDF2-HMAC-SHA256 Case 1 failed");

        // Case 2: P = "password", S = "salt", c = 2
        pbkdf2_hmac_sha256(b"password", b"salt", 2, &mut dk);
        let expected2: [u8; 32] = [
            0xae, 0x4d, 0x0c, 0x95, 0xaf, 0x6b, 0x46, 0xd3,
            0x2d, 0x0a, 0xdf, 0xf9, 0x28, 0xf0, 0x6d, 0xd0,
            0x2a, 0x30, 0x3f, 0x8e, 0xf3, 0xc2, 0x51, 0xdf,
            0xd6, 0xe2, 0xd8, 0x5a, 0x95, 0x47, 0x4c, 0x43,
        ];
        assert_eq!(dk, expected2, "PBKDF2-HMAC-SHA256 Case 2 failed");

        // Case 3: P = "password", S = "salt", c = 4096 (standard PostgreSQL SCRAM iterations)
        pbkdf2_hmac_sha256(b"password", b"salt", 4096, &mut dk);
        let expected3: [u8; 32] = [
            0xc5, 0xe4, 0x78, 0xd5, 0x92, 0x88, 0xc8, 0x41,
            0xaa, 0x53, 0x0d, 0xb6, 0x84, 0x5c, 0x4c, 0x8d,
            0x96, 0x28, 0x93, 0xa0, 0x01, 0xce, 0x4e, 0x11,
            0xa4, 0x96, 0x38, 0x73, 0xaa, 0x98, 0x13, 0x4a,
        ];
        assert_eq!(dk, expected3, "PBKDF2-HMAC-SHA256 Case 3 failed");
    }
}
