//! Constant-time equality for secrets (MAC tags).

use std::hint::black_box;

/// Compares two byte strings without exiting at the first difference.
///
/// The lengths are treated as public: different lengths return `false` at once. `black_box` keeps the optimiser
/// from turning the accumulate-then-test into an early-exit loop.
pub fn eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff = 0u8;
    for (x, y) in a.iter().zip(b) {
        diff |= x ^ y;
    }
    black_box(diff) == 0
}

#[cfg(test)]
mod tests {
    use super::eq;

    #[test]
    fn equal_and_different() {
        assert!(eq(b"", b""));
        assert!(eq(b"abc", b"abc"));
        assert!(!eq(b"abc", b"abd"));
        assert!(!eq(b"abc", b"abcd"));
        assert!(!eq(b"\x00", b"\x80"));
    }
}
