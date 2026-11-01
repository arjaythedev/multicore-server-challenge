//! bcrypt with N independent hashes interleaved in lockstep (see `blowfish` for why).
//!
//! Layers: `tables` (generated pi digits) -> `blowfish` (state and block cipher over lanes) -> `eks` (key
//! schedule and digest) -> `batch` (grouping by cost, chunking into lanes) -> this file (hash strings, verify).
//!
//! Handled: `$2a$`, `$2b$`, `$2y$` hashes with cost 4..=20; passwords up to 72 bytes (longer ones are
//! truncated, like OpenBSD). Not handled: `$2x$`, `$2$`, costs outside 4..=20, and any key-derivation use.

mod batch;
mod blowfish;
mod eks;
mod format;
mod tables;

pub use batch::{HashJob, MAX_LANES, hash_many};
pub use format::{Parsed, encode, parse};

/// Length of the stored hash string.
pub use format::HASH_LEN;

/// Raw digest length.
pub use eks::DIGEST_BYTES;

/// Computes the `$2a$` hash string of one password.
pub fn hash(password: &[u8], salt: [u8; 16], cost: u32) -> [u8; HASH_LEN] {
    let job = HashJob {
        password,
        salt,
        cost,
    };
    let digest = hash_many(&[job])[0];
    encode(cost, &salt, &digest)
}

/// Checks one password against a stored hash string.
pub fn verify(password: &[u8], hash: &[u8]) -> bool {
    verify_many(&[(password, hash)])[0]
}

/// Checks many (password, stored hash) pairs, computing the valid ones together in lockstep.
/// A malformed stored hash yields `false` without any computation.
pub fn verify_many(items: &[(&[u8], &[u8])]) -> Vec<bool> {
    let mut jobs = Vec::with_capacity(items.len());
    let mut owners = Vec::with_capacity(items.len()); // (index in items, expected digest)
    for (index, (password, stored)) in items.iter().enumerate() {
        if let Some(p) = parse(stored) {
            jobs.push(HashJob {
                password,
                salt: p.salt,
                cost: p.cost,
            });
            owners.push((index, p.digest));
        }
    }
    let mut result = vec![false; items.len()];
    for ((index, expected), got) in owners.iter().zip(hash_many(&jobs)) {
        result[*index] = ct_eq(expected, &got);
    }
    result
}

/// Constant-time equality of two digests: no early exit on the first differing byte.
fn ct_eq(a: &[u8; DIGEST_BYTES], b: &[u8; DIGEST_BYTES]) -> bool {
    let diff = a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y));
    std::hint::black_box(diff) == 0
}

#[cfg(test)]
mod tests;
