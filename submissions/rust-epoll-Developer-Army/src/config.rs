//! Global configuration and environment settings.

use std::time::Duration;

#[derive(Clone, Debug)]
pub struct ServerConfig {
    pub db_url: String,
    pub jwt_secret: Vec<u8>,
    pub host: String,
    pub port: u16,
    pub io_workers: usize,
    pub read_lanes: usize,
    pub write_lanes: usize,
    pub bcrypt_workers: usize,
    pub read_batch_max: usize,
    pub read_target_size: usize,
    pub read_timeout: Duration,
    pub write_batch_max: usize,
    pub bcrypt_lanes: usize,
    pub bcrypt_timeout: Duration,
}

fn env_parse<T: std::str::FromStr>(var: &str, default: T) -> T {
    std::env::var(var).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

impl ServerConfig {
    pub fn from_env() -> Self {
        let db_url = std::env::var("DATABASE_URL").expect("DATABASE_URL environment variable must be set");
        let secret = std::env::var("JWT_SECRET").expect("JWT_SECRET environment variable must be set");
        let host = std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".to_string());
        let port = env_parse("PORT", 80);

        let cpus = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);

        ServerConfig {
            db_url,
            jwt_secret: secret.into_bytes(),
            host,
            port,
            io_workers: env_parse("IO_THREADS", (cpus / 2).max(2)),
            read_lanes: env_parse("READ_LANES", 16),
            write_lanes: env_parse("WRITE_LANES", 2),
            bcrypt_workers: env_parse("BCRYPT_THREADS", 3),
            read_batch_max: env_parse("READ_BATCH_MAX", 4096),
            read_target_size: env_parse("READ_TARGET", 256),
            read_timeout: Duration::from_micros(env_parse("READ_WINDOW_US", 4_000)),
            write_batch_max: env_parse("WRITE_BATCH_MAX", 256),
            bcrypt_lanes: env_parse("BCRYPT_LANES", 8).clamp(1, 8),
            bcrypt_timeout: Duration::from_millis(env_parse("BCRYPT_WINDOW_MS", 25)),
        }
    }
}
