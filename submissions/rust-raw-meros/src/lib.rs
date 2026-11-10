//! Conduit (RealWorld) API server for the multicore challenge. See DESIGN.md for the shape and README.md for the measurements.
//!
//! Everything is a library so `cargo test` covers it; `main.rs` only reads the config and starts the threads.
//! Not handled on purpose: anything the benchmark does not send (TLS, HTTP/2, chunked bodies, other databases).
pub mod app;
pub mod bcrypt;
pub mod config;
pub mod crypto;
pub mod http;
pub mod json;
pub mod jwt;
pub mod net;
pub mod password;
pub mod pg;
pub mod pool;
pub mod read;
pub mod render;
pub mod sys;
pub mod write;
