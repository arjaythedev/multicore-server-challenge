//! A write lane: one thread, one Postgres connection, group commit.
//!
//! # Group commit
//!
//! The statements of every job in a batch are pipelined and sent with ONE Sync, which Postgres runs as one implicit
//! transaction with one commit (one WAL flush instead of one per request). Responses are rendered and posted only
//! after that commit returned and every statement of the batch was ok, so a client never hears about a write that
//! is not durable.
//!
//! # Failure handling
//!
//! * A statement of the group failed (the whole transaction rolled back): every job is run again ALONE, in queue
//!   order, each in its own transaction, so one bad request fails only itself. A failed job ends as 422 (a unique
//!   violation on username or email) or 500.
//! * The connection broke while a group or job was in flight: whether it committed is unknown. Those jobs are
//!   answered 503 and are never retried (a retry could apply a write twice). The lane reconnects before its next
//!   batch.
//!
//! Not handled on purpose: retrying a deadlock or serialization failure (a lone retry has the same effect and
//! needs no extra code path), statement timeouts, a transaction that spans two batches.

use std::sync::Arc;
use std::time::{Duration, Instant};

use super::finding::{Failure, Finding, all_ok, finding_for};
use super::push::{Pushed, push_job};
use super::queue::WriteQueue;
use super::respond::Responder;
use super::statements::Statements;
use crate::app::jobs::WriteJob;
use crate::config::Config;
use crate::jwt::Jwt;
use crate::net::Mailboxes;
use crate::pg::{self, Connection, PgError, Results};

/// Session settings of every write connection (startup `options`, no server-wide change).
pub const SESSION_OPTIONS: &str = "-c plan_cache_mode=force_generic_plan -c jit=off";
/// Pause between connection attempts.
const RECONNECT_BACKOFF: Duration = Duration::from_millis(250);
/// How long a lane keeps trying to reach Postgres at start before the process gives up.
const START_PATIENCE: Duration = Duration::from_secs(60);
/// The result arena is released when one batch inflated it beyond this many bytes.
const MAX_KEPT_ARENA: usize = 4 * 1024 * 1024;
/// Log every n-th failed connection attempt (the first one always).
const LOG_EVERY: u32 = 40;

/// Where one job's statements sit in the pipeline of a group.
#[derive(Clone, Copy)]
enum Slot {
    Rejected,
    Pushed { first: usize, count: usize },
}

/// How a group ended.
#[derive(PartialEq, Eq, Debug)]
enum Group {
    /// Committed; every job was answered.
    Committed,
    /// Rolled back; nothing was answered yet, the jobs must run alone.
    RolledBack,
    /// The connection broke; every job was answered 503.
    Lost,
}

pub struct Lane {
    pg_config: pg::Config,
    conn: Connection,
    stmts: Statements,
    /// Set when the connection must be replaced although the client does not know it (a failed push).
    broken: bool,
    results: Results,
    responder: Responder,
    mailboxes: Mailboxes,
    slots: Vec<Slot>,
}

impl Lane {
    /// Connects (retrying for up to a minute) and prepares the statements.
    pub fn start(config: &Config, jwt: Arc<Jwt>, mailboxes: Mailboxes) -> Result<Lane, PgError> {
        let pg_config = pg::Config::from_url(&config.database_url)?;
        let (conn, stmts) = open_retrying(&pg_config, Some(START_PATIENCE))?;
        Ok(Lane {
            pg_config,
            conn,
            stmts,
            broken: false,
            results: Results::new(),
            responder: Responder::new(jwt),
            mailboxes,
            slots: Vec::new(),
        })
    }

    /// Takes batches from `queue` until it is closed and drained.
    pub fn run(mut self, queue: &WriteQueue) {
        let mut batch = Vec::new();
        while queue.take_batch(&mut batch) {
            self.revive(None);
            self.process(&mut batch);
        }
    }

    /// Executes one batch and posts its responses. Leaves `jobs` empty. Public so tests and benchmarks can drive
    /// a lane without threads.
    pub fn process(&mut self, jobs: &mut Vec<WriteJob>) {
        if jobs.is_empty() {
            return;
        }
        if !self.revive(Some(Duration::ZERO)) {
            jobs.iter()
                .for_each(|job| self.responder.answer(job, Finding::Unknown));
        } else if jobs.len() == 1 || self.run_group(jobs) == Group::RolledBack {
            jobs.iter().for_each(|job| self.run_alone(job));
        }
        for job in jobs.drain(..) {
            self.responder.recycle(job.buf);
        }
        self.responder.deliver(&self.mailboxes);
        self.results.shrink_if_above(MAX_KEPT_ARENA);
    }

    /// All jobs in one transaction.
    fn run_group(&mut self, jobs: &[WriteJob]) -> Group {
        self.slots.clear();
        let mut next = 0;
        for job in jobs {
            match push_job(&mut self.conn, &self.stmts, job) {
                Ok(Pushed::Statements(count)) => {
                    self.slots.push(Slot::Pushed { first: next, count });
                    next += count;
                }
                Ok(Pushed::Rejected) => self.slots.push(Slot::Rejected),
                Err(_) => {
                    self.lose(jobs);
                    return Group::Lost;
                }
            }
        }
        match self.conn.flush_and_collect(&mut self.results) {
            Ok(()) if all_ok(&self.results) => {
                for (job, slot) in jobs.iter().zip(&self.slots) {
                    let finding = match *slot {
                        Slot::Rejected => Finding::Rejected,
                        Slot::Pushed { first, count } => finding_for(&self.results, first, count),
                    };
                    self.responder.answer(job, finding);
                }
                Group::Committed
            }
            Ok(()) | Err(PgError::Server(_)) => Group::RolledBack,
            Err(_) => {
                self.lose(jobs);
                Group::Lost
            }
        }
    }

    /// One job in its own transaction.
    fn run_alone(&mut self, job: &WriteJob) {
        if !self.revive(Some(Duration::ZERO)) {
            return self.responder.answer(job, Finding::Unknown);
        }
        let count = match push_job(&mut self.conn, &self.stmts, job) {
            Ok(Pushed::Statements(count)) => count,
            Ok(Pushed::Rejected) => return self.responder.answer(job, Finding::Rejected),
            Err(_) => return self.lose(std::slice::from_ref(job)),
        };
        match self.conn.flush_and_collect(&mut self.results) {
            Ok(()) => self
                .responder
                .answer(job, finding_for(&self.results, 0, count)),
            Err(PgError::Server(_)) => self.responder.answer(job, Finding::Failed(Failure::Server)),
            Err(_) => self.lose(std::slice::from_ref(job)),
        }
    }

    /// The connection can no longer be trusted: answer 503 and reconnect before the next batch.
    fn lose(&mut self, jobs: &[WriteJob]) {
        self.broken = true;
        jobs.iter()
            .for_each(|job| self.responder.answer(job, Finding::Unknown));
    }

    /// Replaces a broken connection. `patience`: how long to keep trying (`None` = forever).
    fn revive(&mut self, patience: Option<Duration>) -> bool {
        if !self.broken && !self.conn.is_poisoned() {
            return true;
        }
        match open_retrying(&self.pg_config, patience) {
            Ok((conn, stmts)) => {
                (self.conn, self.stmts, self.broken) = (conn, stmts, false);
                true
            }
            Err(_) => false,
        }
    }
}

/// Connects and prepares, pausing [`RECONNECT_BACKOFF`] between attempts until `patience` has passed (`None` =
/// never give up). At least one attempt is made.
fn open_retrying(
    config: &pg::Config,
    patience: Option<Duration>,
) -> Result<(Connection, Statements), PgError> {
    let started = Instant::now();
    let mut failures = 0u32;
    loop {
        match open(config) {
            Ok(opened) => return Ok(opened),
            Err(e) => {
                if failures.is_multiple_of(LOG_EVERY) {
                    eprintln!(
                        "write lane: cannot reach postgres ({failures} failed attempts so far): {e}"
                    );
                }
                failures += 1;
                if patience.is_some_and(|p| started.elapsed() >= p) {
                    return Err(e);
                }
                std::thread::sleep(RECONNECT_BACKOFF);
            }
        }
    }
}

fn open(config: &pg::Config) -> Result<(Connection, Statements), PgError> {
    let mut conn = Connection::connect(config, SESSION_OPTIONS)?;
    let stmts = Statements::prepare(&mut conn)?;
    Ok((conn, stmts))
}

/// Starts `count` write lanes, each on its own thread with its own connection. A lane that cannot reach Postgres
/// within a minute at start ends the process: a server without write lanes would never answer a write.
pub fn spawn_lanes(
    count: usize,
    config: &Config,
    queue: Arc<WriteQueue>,
    mailboxes: Mailboxes,
    jwt: Arc<Jwt>,
) -> Vec<std::thread::JoinHandle<()>> {
    (0..count)
        .map(|index| {
            let (config, queue, mailboxes, jwt) = (
                config.clone(),
                Arc::clone(&queue),
                mailboxes.clone(),
                Arc::clone(&jwt),
            );
            std::thread::Builder::new()
                .name(format!("write-lane-{index}"))
                .spawn(move || match Lane::start(&config, jwt, mailboxes) {
                    Ok(lane) => lane.run(&queue),
                    Err(e) => fatal(&format!("write lane {index} cannot start: {e}")),
                })
                .unwrap_or_else(|e| fatal(&format!("cannot spawn write lane {index}: {e}")))
        })
        .collect()
}

fn fatal(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1)
}
