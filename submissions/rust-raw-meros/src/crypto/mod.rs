//! Hand-written cryptographic primitives for this server (std only, no crates).
//!
//! | Module | Purpose | Used by |
//! |---|---|---|
//! | [`sha256`] | SHA-256, portable and SHA-NI back ends | everything below |
//! | [`hmac`] | HMAC-SHA-256 with precomputed pad states | JWT, PBKDF2, SCRAM |
//! | [`pbkdf2`] | PBKDF2-HMAC-SHA-256, one 32-byte block | SCRAM-SHA-256 (Postgres login) |
//! | [`base64`] | standard (padded) and URL-safe (unpadded) | SCRAM, JWT |
//! | [`random`] | bytes from `/dev/urandom` | SCRAM client nonce, bcrypt salt |
//! | [`ct`] | constant-time byte comparison | JWT signature check |
//!
//! Scope: only what the Conduit server needs. There is no streaming PBKDF2 output longer than one block, no
//! SHA-224/384/512, and no side-channel hardening beyond the constant-time comparison (the portable SHA-256 has no
//! secret-dependent branches or table lookups, and the SHA-NI path is constant-time in hardware).

pub mod base64;
pub mod ct;
pub mod hmac;
pub mod pbkdf2;
pub mod random;
pub mod sha256;

#[cfg(target_arch = "x86_64")]
mod sha256_ni;
