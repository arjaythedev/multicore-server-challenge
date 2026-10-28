//! Write lanes: group commit.
//!
//! The app pushes a [`WriteJob`](crate::app::jobs::WriteJob) per write request into the shared [`WriteQueue`]. A few
//! lane threads, each with its own Postgres connection, take batches from it, run all statements of a batch in ONE
//! transaction (one commit, one WAL flush) and only then render and post the responses. Every write is therefore
//! committed before its response is sent, and a commit is shared by as many requests as arrived within the window.
//!
//! File map:
//!
//! * `queue`: the shared queue and the batching rule (window, `batch_max`).
//! * `lane`: the thread, the connection, group execution and the single-job fallback; `spawn_lanes`.
//! * `statements`: the prepared statements (`sql/*.sql`, included with `include_str!`).
//! * `push`: job -> pipelined statements (zero-copy parameters).
//! * `finding`: a job's statements -> committed / failed / unknown.
//! * `respond`: findings -> HTTP responses in pooled buffers, delivery through the mailboxes.
//! * `bodies`: rows -> JSON per request kind.
//!
//! Not handled on purpose: caching anything between batches, retrying requests whose commit outcome is unknown,
//! splitting a batch by kind.

mod bodies;
mod finding;
mod lane;
mod push;
mod queue;
mod respond;
mod statements;

#[cfg(test)]
mod bench_tests;
#[cfg(test)]
mod group_tests;
#[cfg(test)]
mod live_tests;
#[cfg(test)]
mod test_proxy;
#[cfg(test)]
mod test_support;

pub use lane::{Lane, SESSION_OPTIONS, spawn_lanes};
pub use queue::WriteQueue;
