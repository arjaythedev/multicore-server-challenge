//! The read lane threads: connect, then forever take a batch, run it, deliver the replies.
//!
//! A lane that has no connection (the database is down, or the stream was poisoned) keeps taking batches and
//! answers them 503 instead of letting requests pile up, and tries to reconnect between batches with a 250 ms pause.
//!
//! Not handled on purpose: lane shutdown (threads end with the process), more than one connection per lane.

use std::sync::Arc;
use std::thread::JoinHandle;

use crate::app::jobs::ReadJob;
use crate::config::Config;
use crate::http::Status;
use crate::jwt::Jwt;
use crate::net::Mailboxes;
use crate::password::PasswordQueue;
use crate::pg::Config as PgConfig;

use super::queue::ReadQueue;
use super::runner::{Health, Runner};
use super::session::{Db, RETRY_BACKOFF, SESSION_OPTIONS, START_PATIENCE};

/// Starts `count` lanes. Each connects on its own thread, so the caller does not wait for the database.
pub fn spawn_lanes(
    count: usize,
    config: &Config,
    queue: Arc<ReadQueue>,
    mailboxes: Mailboxes,
    passwords: Arc<PasswordQueue>,
    jwt: Arc<Jwt>,
) -> Vec<JoinHandle<()>> {
    let pg = match PgConfig::from_url(&config.database_url) {
        Ok(pg) => pg,
        Err(e) => {
            eprintln!("read lanes not started: {e}");
            return Vec::new();
        }
    };
    (0..count)
        .filter_map(|n| {
            let lane = Lane {
                pg: pg.clone(),
                queue: Arc::clone(&queue),
                mailboxes: mailboxes.clone(),
                passwords: Arc::clone(&passwords),
                _jwt: Arc::clone(&jwt),
                runner: Runner::new(),
            };
            std::thread::Builder::new()
                .name(format!("read-lane-{n}"))
                .spawn(move || lane.run())
                .map_err(|e| eprintln!("read lane {n} not started: {e}"))
                .ok()
        })
        .collect()
}

struct Lane {
    pg: PgConfig,
    queue: Arc<ReadQueue>,
    mailboxes: Mailboxes,
    passwords: Arc<PasswordQueue>,
    /// Logins are signed on the password thread, so the read side holds the signer only to keep the lanes'
    /// constructor identical to the other services'.
    _jwt: Arc<Jwt>,
    runner: Runner,
}

impl Lane {
    fn run(mut self) -> ! {
        let mut db = Db::open_patiently(&self.pg, SESSION_OPTIONS, START_PATIENCE)
            .map_err(|e| eprintln!("read lane cannot reach the database: {e}"))
            .ok();
        let mut batch: Vec<ReadJob> = Vec::new();
        loop {
            self.queue.take_batch(&mut batch);
            if db.is_none() {
                db = Db::open(&self.pg, SESSION_OPTIONS)
                    .map_err(|e| eprintln!("read lane reconnect: {e}"))
                    .ok();
            }
            match db.as_mut() {
                Some(open) => {
                    if self
                        .runner
                        .run(&mut open.conn, &open.stmts, &mut batch, &*self.passwords)
                        == Health::Poisoned
                    {
                        db = None;
                    }
                }
                None => {
                    self.runner.fail_all(&batch, Status::ServiceUnavailable);
                    std::thread::sleep(RETRY_BACKOFF);
                }
            }
            self.runner.deliver(&mut batch, &self.mailboxes);
        }
    }
}
