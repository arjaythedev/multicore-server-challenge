//! PBKDF2-HMAC-SHA-256 (RFC 8018), single output block.
//!
//! SCRAM-SHA-256 (Postgres login) asks for exactly one 32-byte block, so block indexing beyond `INT(1)` is not
//! implemented. The iteration count comes from the server, so it is untrusted: `0` is treated as `1`; callers
//! should reject absurd counts themselves (this function would just run for a long time).

use super::hmac::HmacSha256;
use super::sha256::DIGEST_LEN;

/// Big-endian block index 1, appended to the salt for the first iteration.
const BLOCK_INDEX_1: [u8; 4] = 1u32.to_be_bytes();

/// Derives 32 bytes from `password` and `salt`.
pub fn pbkdf2_hmac_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; DIGEST_LEN] {
    let prf = HmacSha256::new(password);
    let mut u = prf.mac(&[salt, &BLOCK_INDEX_1]);
    let mut result = u;
    for _ in 1..iterations {
        u = prf.mac(&[&u]);
        for (r, byte) in result.iter_mut().zip(u) {
            *r ^= byte;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    // Expected values computed with Python: hashlib.pbkdf2_hmac('sha256', password, salt, iterations, 32).
    #[test]
    fn matches_python_hashlib() {
        let cases: [(&[u8], &[u8], u32, &str); 4] = [
            (
                b"password",
                b"salt",
                1,
                "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b",
            ),
            (
                b"password",
                b"salt",
                4096,
                "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
            ),
            (
                b"pencil",
                b"QSXCR+Q6sek8bf92",
                4096,
                "ad14c61698376bc20bf70747539f410b5666fcccc85672ef14945096a6c06ae3",
            ),
            (
                &[b'p'; 100],
                b"s",
                3,
                "9409e61da4c2c5d18a409dfac48da9a85ee907885ecaf8f7c74b973ed24a2a5e",
            ),
        ];
        for (password, salt, iterations, expected) in cases {
            assert_eq!(
                hex(&pbkdf2_hmac_sha256(password, salt, iterations)),
                expected
            );
        }
    }

    #[test]
    fn zero_iterations_behaves_like_one() {
        assert_eq!(
            pbkdf2_hmac_sha256(b"pw", b"salt", 0),
            pbkdf2_hmac_sha256(b"pw", b"salt", 1)
        );
    }
}
