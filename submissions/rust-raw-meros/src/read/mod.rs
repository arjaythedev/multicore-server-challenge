//! Read lanes: batched reads.
//!
//! Every read request becomes a [`ReadJob`](crate::app::jobs::ReadJob) in the [`ReadQueue`]. A lane takes a batch
//! (see `queue.rs` for the gathering rule), asks Postgres **one statement per kind present** (the statements take
//! arrays, one element per request), reads every answer from one round trip into one arena, and renders each
//! response straight from the borrowed rows into a pooled buffer.
//!
//! File map:
//!
//! | file | what |
//! |---|---|
//! | `queue.rs` | the FIFO and the gatherer rule |
//! | `lane.rs`, `session.rs` | threads, connection, reconnect, session options |
//! | `runner.rs` | one batch: plan, flush, dispatch, deliver |
//! | `plan.rs`, `statements.rs`, `sql/*.sql` | grouping by kind, statement parameters, the SQL |
//! | `articles.rs`, `comments.rs`, `simple.rs`, `tags.rs` | row decoding and JSON per kind |
//! | `sink.rs`, `error.rs`, `table.rs`, `scratch.rs` | reply bookkeeping, errors, id table, reusable vectors |
//!
//! Failure model: a statement that fails (or is skipped because an earlier statement of the pipeline failed) gives
//! 500 to its kind; a poisoned connection gives 503 to the batch and the lane reconnects.
//!
//! Not handled on purpose: caching of any kind across batches (the rules forbid it), per-request statements,
//! cancellation of a batch that is already at the database.

mod articles;
mod comments;
mod error;
mod lane;
mod plan;
mod queue;
mod runner;
mod scratch;
mod session;
mod simple;
mod sink;
mod statements;
mod table;
mod tags;

#[cfg(test)]
mod bench;
#[cfg(test)]
mod harness;
#[cfg(test)]
mod live_tests;
#[cfg(test)]
mod reference;

pub use lane::spawn_lanes;
pub use queue::ReadQueue;
pub use runner::{Health, Runner};
pub use session::{Db, SESSION_OPTIONS};
pub use statements::{Group, Statements};
