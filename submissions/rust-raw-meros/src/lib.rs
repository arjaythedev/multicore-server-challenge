//! Conduit (RealWorld) API server for the multicore challenge. See DESIGN.md.
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
