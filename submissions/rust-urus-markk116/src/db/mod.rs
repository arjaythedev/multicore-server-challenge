//! Database access for the handlers.
//!
//! Connections live in two pools of connection actors ([`pool`]): one for batches that only
//! read, one for batches that write. A commit waits for its WAL flush, so a slow flush stalls
//! the connection it runs on and everything queued behind it; on separate connections, reads
//! never queue behind a commit.

mod pool;

use std::sync::Arc;
use std::time::Duration;

use smarm::{ChildSpec, OneForOne, Restart, Shutdown};

pub use smarm_pg::{oid, Config, FromRow, FromSql, Param, PgError, PgResult, Row, Rows, Stmt, ToParam};

use pool::Pool;
use smarm_pg::Step;

/// Statement parameters, in `$1, $2, …` order.
pub type Params<'a> = &'a [&'a dyn ToParam];

/// The handle the handlers use. Cheap to share; holds no connections itself.
pub struct Db {
    reads: Pool,
    writes: Pool,
}

impl Db {
    /// The handle, plus the child that runs the connections (start it before anything that
    /// uses the handle).
    pub fn new(cfg: Config, read_conns: usize, write_conns: usize) -> (Db, ChildSpec) {
        let cfg = Arc::new(cfg);
        let (reads, read_child) = Pool::start("db.read", cfg.clone(), read_conns);
        let (writes, write_child) = Pool::start("db.write", cfg, write_conns);
        let child = ChildSpec::new(Restart::Permanent, move || {
            OneForOne::new()
                .intensity(4, Duration::from_secs(5))
                .child(read_child.clone())
                .child(write_child.clone())
                .run();
        })
        .shutdown(Shutdown::Infinity);
        (Db { reads, writes }, child)
    }

    /// Run one statement.
    pub fn query(&self, stmt: &'static Stmt, params: Params) -> PgResult<Rows> {
        let [rows] = self.batch([(stmt, params)])?;
        Ok(rows)
    }

    /// Run several statements in one round trip and one implicit transaction: if any of them
    /// fails, none of them took effect.
    pub fn batch<const N: usize>(&self, stmts: [(&'static Stmt, Params); N]) -> PgResult<[Rows; N]> {
        let writes = stmts.iter().any(|(stmt, _)| stmt.writes);
        let steps = stmts
            .iter()
            .map(|(stmt, params)| Step { stmt, params: params.iter().map(|p| p.to_param()).collect() })
            .collect();
        let pool = if writes { &self.writes } else { &self.reads };
        let results = pool.run(steps)?;
        results.try_into().map_err(|_| PgError::Protocol("result count mismatch"))
    }
}
