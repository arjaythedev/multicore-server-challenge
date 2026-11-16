//! Security & Cryptography Module
//! Owned by `crypto`.
//!
//! Provides:
//! - Hardware SHA-NI accelerated SHA-256 with portable scalar fallback and CPUID dispatch.
//! - Precomputed HMAC-SHA256 for zero-overhead token verification.
//! - SCRAM-SHA-256 client authentication primitives for PostgreSQL (RFC 5802).
//! - Zero-allocation JWT HS256 verify and sign.
//! - Hand-written x86-64 assembly Blowfish engine (6-lane, 4-lane, 2-lane, 1-lane).
//! - SCHED_IDLE KDF background worker with full-batching coalescing.

pub mod sha256;
pub mod hmac;
pub mod scram;
pub mod jwt;
pub mod bf_tables;
pub mod bcrypt;
pub mod kdf_worker;

pub use sha256::{sha256, sha256_digest};
pub use hmac::{hmac_sha256, PrecomputedHmac};
pub use scram::pbkdf2_hmac_sha256;
pub use jwt::{jwt_verify, jwt_sign};
pub use bcrypt::{
    bcrypt_hash, bcrypt_verify_batch, format_bcrypt, parse_bcrypt, ct_digest_eq, VerifyItem,
};
pub use kdf_worker::{spawn_kdf_worker, spawn_kdf_worker_indexed, get_default_kdf_threads};
