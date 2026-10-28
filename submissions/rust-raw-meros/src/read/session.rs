//! One lane's database session: the connection plus its prepared statements, and how to (re)open it.

use std::time::{Duration, Instant};

use crate::pg::{Config as PgConfig, Connection, PgError};

use super::statements::Statements;

/// Session settings, passed as the startup `options` so no `SET` round trip is needed.
///
/// * `plan_cache_mode=force_generic_plan`: the statements are prepared once and run with arrays, so a custom plan
///   per parameter value would only cost planning time.
/// * `jit=off`, `max_parallel_workers_per_gather=0`: these statements are short; JIT compilation and parallel
///   workers cost more than they save and break the "one backend per lane" CPU accounting.
/// * `enable_memoize=off`: measured on the full seed (`bench::enable_memoize_experiment`, best of three alternating
///   runs, every kind at batch 16 and 128): no kind is cheaper with it on (differences under 1% except `comments`,
///   9.1 against 9.7 us per request at batch 128, in favour of off). The planner picks Memoize rarely for these
///   statements, and where it does it costs a hash table without hits, so it stays off.
pub const SESSION_OPTIONS: &str = "-c plan_cache_mode=force_generic_plan -c jit=off \
     -c max_parallel_workers_per_gather=0 -c enable_memoize=off";

/// Pause between connection attempts.
pub const RETRY_BACKOFF: Duration = Duration::from_millis(250);
/// How long a lane keeps trying at start before it begins answering batches with 503.
pub const START_PATIENCE: Duration = Duration::from_secs(60);

pub struct Db {
    pub conn: Connection,
    pub stmts: Statements,
}

impl Db {
    /// Connects and prepares every statement.
    pub fn open(cfg: &PgConfig, options: &str) -> Result<Db, PgError> {
        let mut conn = Connection::connect(cfg, options)?;
        let stmts = Statements::prepare(&mut conn)?;
        Ok(Db { conn, stmts })
    }

    /// Retries every [`RETRY_BACKOFF`] until `patience` has passed. The last error is returned if it never works.
    pub fn open_patiently(
        cfg: &PgConfig,
        options: &str,
        patience: Duration,
    ) -> Result<Db, PgError> {
        let deadline = Instant::now() + patience;
        loop {
            match Db::open(cfg, options) {
                Ok(db) => return Ok(db),
                Err(e) if Instant::now() >= deadline => return Err(e),
                Err(_) => std::thread::sleep(RETRY_BACKOFF),
            }
        }
    }
}
