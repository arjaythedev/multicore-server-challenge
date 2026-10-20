//! Connection actors: one supervised actor per Postgres connection.
//!
//! Each worker owns its connection, registers its inbox under its slot's name, and runs the jobs
//! sent to it one at a time. A broken connection ends the worker; its supervisor starts a
//! replacement that connects and registers under the same name. Jobs go to the worker with the
//! fewest jobs in flight, so a slow statement doesn't hold up requests that a free connection
//! could have taken.

use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Arc;
use std::time::Duration;

use smarm::{channel, ChildSpec, Name, OneForOne, Restart, Sender, Shutdown};

use smarm_pg::{Config, PgConn, PgError, PgResult, Rows, Step};

/// A batch of statements for one connection, and where to send the result.
struct Job {
    steps: Vec<Step>,
    reply: Sender<PgResult<Vec<Rows>>>,
}

/// One worker's address, and how many jobs have been sent to it and not yet answered.
struct Slot {
    name: Name<Job>,
    in_flight: AtomicU32,
}

/// A fixed set of interchangeable connections.
pub struct Pool {
    slots: Vec<Slot>,
}

impl Pool {
    /// The pool handle, and the supervisor child that runs its `size` workers, registered as
    /// `<prefix>.0`, `<prefix>.1`, ….
    pub fn start(prefix: &str, cfg: Arc<Config>, size: usize) -> (Pool, ChildSpec) {
        // Registered names are `&'static str`: made once at startup and kept for the process's life.
        let names: Vec<Name<Job>> =
            (0..size).map(|i| Name::new(String::leak(format!("{prefix}.{i}")))).collect();
        let workers = names.clone();
        let child = ChildSpec::new(Restart::Permanent, move || {
            let mut sup = OneForOne::new().intensity(2 * size as u32, Duration::from_secs(5));
            for &name in &workers {
                let cfg = cfg.clone();
                sup = sup.child(ChildSpec::new(Restart::Permanent, move || worker(name, &cfg)));
            }
            sup.run();
        })
        .shutdown(Shutdown::Infinity);
        let slots = names.into_iter().map(|name| Slot { name, in_flight: AtomicU32::new(0) }).collect();
        (Pool { slots }, child)
    }

    /// Run the steps on the least busy connection.
    pub fn run(&self, steps: Vec<Step>) -> PgResult<Vec<Rows>> {
        let slot = self
            .slots
            .iter()
            .min_by_key(|slot| slot.in_flight.load(Ordering::Relaxed))
            .ok_or(PgError::Protocol("empty pool"))?;
        let (reply, result) = channel();
        slot.in_flight.fetch_add(1, Ordering::Relaxed);
        let sent = smarm::send(slot.name, Job { steps, reply });
        // Answered, failed, or never delivered: either way it is no longer in flight.
        let outcome = match sent {
            Ok(()) => result.recv().map_err(|_| PgError::Protocol("connection worker died")),
            Err(_) => Err(PgError::Protocol("connection worker is restarting")),
        };
        slot.in_flight.fetch_sub(1, Ordering::Relaxed);
        outcome?
    }
}

fn worker(name: Name<Job>, cfg: &Config) {
    let mut conn = PgConn::connect(cfg).unwrap_or_else(|e| panic!("{}: connect: {e}", name.as_str()));
    let (tx, jobs) = channel::<Job>();
    smarm::register(name, tx).unwrap_or_else(|e| panic!("{}: register: {e:?}", name.as_str()));
    while let Ok(Job { steps, reply }) = jobs.recv() {
        let _ = reply.send(conn.pipe(&steps));
        if !conn.is_healthy() {
            // Let it crash: the supervisor restarts us with a fresh connection.
            return;
        }
    }
}
