//! Connection settings parsed from a `postgres://` URL.
//!
//! Handles `postgres://user[:password]@host[:port]/database` and `postgresql://`, `[v6]` hosts and percent-encoded
//! user/password. Query parameters (`?sslmode=...`) are ignored: there is no TLS here. Not handled: unix sockets,
//! multiple hosts, service files.

use super::error::PgError;

const DEFAULT_PORT: u16 = 5432;
const SCHEMES: [&str; 2] = ["postgres://", "postgresql://"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub user: String,
    pub password: Option<String>,
    pub host: String,
    pub port: u16,
    pub database: String,
}

impl Config {
    pub fn from_url(url: &str) -> Result<Config, PgError> {
        let rest = SCHEMES
            .iter()
            .find_map(|s| url.strip_prefix(s))
            .ok_or_else(|| bad_url("scheme must be postgres:// or postgresql://"))?;
        let rest = rest.split('?').next().unwrap_or(rest);
        let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
        // The last '@' separates credentials from the host, so '@' inside a raw password still works.
        let (creds, hostport) = authority
            .rsplit_once('@')
            .ok_or_else(|| bad_url("missing user@"))?;
        let (user, password) = match creds.split_once(':') {
            Some((u, p)) => (percent_decode(u)?, Some(percent_decode(p)?)),
            None => (percent_decode(creds)?, None),
        };
        if user.is_empty() {
            return Err(bad_url("empty user"));
        }
        let (host, port) = split_host_port(hostport)?;
        let database = if path.is_empty() {
            user.clone()
        } else {
            percent_decode(path)?
        };
        Ok(Config {
            user,
            password,
            host,
            port,
            database,
        })
    }
}

fn bad_url(why: &str) -> PgError {
    PgError::Protocol(format!("invalid postgres url: {why}"))
}

fn split_host_port(s: &str) -> Result<(String, u16), PgError> {
    let (host, port_text) = if let Some(v6) = s.strip_prefix('[') {
        let (host, after) = v6
            .split_once(']')
            .ok_or_else(|| bad_url("unterminated [ipv6]"))?;
        (host, after.strip_prefix(':'))
    } else {
        match s.rsplit_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (s, None),
        }
    };
    if host.is_empty() {
        return Err(bad_url("empty host"));
    }
    let port = match port_text {
        Some(p) => p.parse().map_err(|_| bad_url("bad port"))?,
        None => DEFAULT_PORT,
    };
    Ok((host.to_owned(), port))
}

fn percent_decode(s: &str) -> Result<String, PgError> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = bytes
                .get(i + 1..i + 3)
                .ok_or_else(|| bad_url("truncated %-escape"))?;
            let hex = std::str::from_utf8(hex).map_err(|_| bad_url("bad %-escape"))?;
            out.push(u8::from_str_radix(hex, 16).map_err(|_| bad_url("bad %-escape"))?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).map_err(|_| bad_url("credentials are not UTF-8"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn full_url() {
        let c = Config::from_url("postgres://conduit:secret@127.0.0.1:5433/conduit_dev").unwrap();
        assert_eq!(c.user, "conduit");
        assert_eq!(c.password.as_deref(), Some("secret"));
        assert_eq!((c.host.as_str(), c.port), ("127.0.0.1", 5433));
        assert_eq!(c.database, "conduit_dev");
    }

    #[test]
    fn defaults_and_ignored_query() {
        let c = Config::from_url("postgresql://bob@db.local/?sslmode=disable").unwrap();
        assert_eq!(
            (c.port, c.password, c.database.as_str()),
            (5432, None, "bob")
        );
    }

    #[test]
    fn percent_escapes_and_ipv6() {
        let c = Config::from_url("postgres://u%40x:p%3Aw@[::1]:6000/d").unwrap();
        assert_eq!(
            (c.user.as_str(), c.password.as_deref()),
            ("u@x", Some("p:w"))
        );
        assert_eq!((c.host.as_str(), c.port), ("::1", 6000));
    }

    #[test]
    fn rejects_garbage() {
        for bad in [
            "mysql://a@b/c",
            "postgres://host/db",
            "postgres://u@:1/d",
            "postgres://u@h:x/d",
            "postgres://u%zz@h/d",
        ] {
            assert!(Config::from_url(bad).is_err(), "{bad}");
        }
    }
}
