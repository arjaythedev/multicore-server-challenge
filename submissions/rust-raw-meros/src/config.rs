//! Configuration: the four variables the challenge defines (`DATABASE_URL`, `JWT_SECRET`, `HOST`, `PORT`) and a few
//! optional tuning knobs for experiments. Defaults are sized from the CPU count for the 8-vCPU benchmark box.

use std::time::Duration;

/// Everything the server reads at start.
#[derive(Debug, Clone)]
pub struct Config {
    pub database_url: String,
    pub jwt_secret: Vec<u8>,
    pub host: [u8; 4],
    pub port: u16,
    /// Threads running an epoll loop and the HTTP side.
    pub io_threads: usize,
    /// Postgres connections (one thread each) that run batched reads.
    pub read_lanes: usize,
    /// Postgres connections (one thread each) that run grouped writes.
    pub write_lanes: usize,
    /// How long the oldest queued read waits for company before its batch runs.
    pub read_window: Duration,
    /// Most reads in one batch.
    pub read_batch_max: usize,
    /// How long a lone write waits for company.
    pub write_window: Duration,
    /// Most writes in one transaction.
    pub write_batch_max: usize,
    /// Threads hashing and verifying passwords.
    pub bcrypt_threads: usize,
    /// How long the oldest queued password job waits to fill the interleaved lanes.
    pub bcrypt_window: Duration,
}

impl Config {
    /// Reads the environment. Errors are messages for the operator.
    pub fn from_env() -> Result<Config, String> {
        let cpus = std::thread::available_parallelism().map_or(1, |n| n.get());
        let database_url = required("DATABASE_URL")?;
        let jwt_secret = required("JWT_SECRET")?.into_bytes();
        let host = parse_ipv4(&std::env::var("HOST").unwrap_or_else(|_| "0.0.0.0".into()))?;
        let port = optional_num("PORT", 3000u16)?;
        Ok(Config {
            database_url,
            jwt_secret,
            host,
            port,
            io_threads: optional_num("IO_THREADS", (cpus / 4).max(1))?,
            read_lanes: optional_num("READ_LANES", (cpus * 3 / 4).max(2))?,
            write_lanes: optional_num("WRITE_LANES", (cpus / 4).max(1))?,
            read_window: Duration::from_micros(optional_num("READ_WINDOW_US", 30_000)?),
            read_batch_max: optional_num("READ_BATCH_MAX", 512)?,
            write_window: Duration::from_micros(optional_num("WRITE_WINDOW_US", 1_000)?),
            write_batch_max: optional_num("WRITE_BATCH_MAX", 256)?,
            bcrypt_threads: optional_num("BCRYPT_THREADS", (cpus / 8).max(1))?,
            bcrypt_window: Duration::from_micros(optional_num("BCRYPT_WINDOW_US", 400_000)?),
        })
    }
}

fn required(name: &str) -> Result<String, String> {
    std::env::var(name).map_err(|_| format!("{name} is not set"))
}

fn optional_num<T: std::str::FromStr>(name: &str, default: T) -> Result<T, String> {
    match std::env::var(name) {
        Ok(text) if !text.is_empty() => text
            .parse()
            .map_err(|_| format!("{name}={text} is not a valid number")),
        _ => Ok(default),
    }
}

fn parse_ipv4(text: &str) -> Result<[u8; 4], String> {
    let addr: std::net::Ipv4Addr = text
        .parse()
        .map_err(|_| format!("HOST={text} is not an IPv4 address"))?;
    Ok(addr.octets())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_parsing() {
        assert_eq!(parse_ipv4("127.0.0.1"), Ok([127, 0, 0, 1]));
        assert_eq!(parse_ipv4("0.0.0.0"), Ok([0, 0, 0, 0]));
        assert!(parse_ipv4("localhost").is_err());
    }
}
