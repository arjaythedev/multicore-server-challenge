//! Password service: bcrypt on dedicated, low-priority threads.
//!
//! Two kinds of work arrive in one [`PasswordQueue`]: *verify* (a login, after the read lane fetched the stored
//! hash) and *hash* (a register or password change that continues as a write once the hash exists). A worker
//! gathers up to [`bcrypt::MAX_LANES`] jobs, computes them interleaved in one `hash_many` call (the lanes share
//! the CPU's execution units, so six hashes cost little more than three) and finishes each job.
//!
//! Layers: `queue` (gather rule), `compute` (one interleaved call), `finish` (answers and hand-off), `outbox`
//! (where results go: a trait with one production implementation, so tests capture without dynamic dispatch).
//!
//! Memory: the request buffer is never copied. A login answer reuses a pooled buffer and returns the request
//! buffer to the pool; a hash job moves the request buffer into the follow-up write job. Per batch the only heap
//! allocation is the `Vec` of digests that `bcrypt::hash_many` returns.
//!
//! Not handled on purpose: empty passwords (the app rejects them first), priorities between jobs (FIFO), and
//! retrying a failed system random source (the request gets a 500).

mod compute;
mod finish;
mod outbox;
mod queue;
#[cfg(test)]
mod tests;

use std::sync::Arc;
use std::thread::JoinHandle;

use crate::config::Config;
use crate::jwt::Jwt;
use crate::net::Mailboxes;
use crate::sys::{self, SchedClass};
use crate::write::WriteQueue;

use compute::Computer;
use outbox::{Live, Outbox};
pub use queue::PasswordQueue;

/// Cost factor of every hash this server writes (challenge rule: bcrypt cost 10).
pub const BCRYPT_COST: u32 = 10;
/// Lifetime of a login token in seconds.
pub const TOKEN_TTL_SECS: u64 = 30 * 24 * 3600;

/// Starts `count` bcrypt threads. They end when [`PasswordQueue::close`] is called and the queue is drained.
/// `config` is reserved for tuning knobs; the gather window is already in the queue.
pub fn spawn_threads(
    count: usize,
    _config: &Config,
    queue: Arc<PasswordQueue>,
    mailboxes: Mailboxes,
    writes: Arc<WriteQueue>,
    jwt: Arc<Jwt>,
) -> Vec<JoinHandle<()>> {
    let outbox = Arc::new(Live::new(mailboxes, writes));
    (0..count)
        .filter_map(|i| {
            let (queue, outbox, jwt) = (queue.clone(), outbox.clone(), jwt.clone());
            std::thread::Builder::new()
                .name(format!("bcrypt-{i}"))
                .spawn(move || {
                    // Failure only means the thread keeps the normal class.
                    let _ = sys::set_thread_sched(SchedClass::Batch);
                    run(&queue, &*outbox, &jwt);
                })
                .ok()
        })
        .collect()
}

/// The worker loop: gather, compute, finish. Returns when the queue is closed and empty.
fn run<O: Outbox>(queue: &PasswordQueue, outbox: &O, jwt: &Jwt) {
    let mut computer = Computer::new();
    let mut finisher = finish::Finisher::new(outbox, jwt);
    let mut batch = Vec::with_capacity(crate::bcrypt::MAX_LANES);
    while queue.take_batch(&mut batch) {
        computer.compute(&batch);
        finisher.finish_all(&mut batch, computer.verdicts());
    }
}
