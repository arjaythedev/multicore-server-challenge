//! What became of one job after its statements ran: the bridge between Postgres' answers and the response.

use crate::pg::{Results, StmtResult};

/// Why a job's statements did not complete.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// SQLSTATE 23505. A 422 for the requests that can collide on username or email, else a 500.
    UniqueViolation,
    /// Any other server error. The transaction was rolled back, nothing of the job is visible.
    Server,
    /// The server skipped the statement because an earlier one failed.
    NotRun,
}

/// The outcome the response is built from.
pub enum Finding<'r> {
    /// Every statement ran; this is the answer of the last one.
    Done(StmtResult<'r>),
    Failed(Failure),
    /// The job could not be sent (see [`Pushed::Rejected`](super::push::Pushed::Rejected)).
    Rejected,
    /// The connection broke after the job was sent: it may or may not be committed. Answered 503, never retried.
    Unknown,
}

/// Judges the `count` statements of a job that start at `first` in `results`.
pub fn finding_for(results: &Results, first: usize, count: usize) -> Finding<'_> {
    if count == 0 || first + count > results.len() {
        return Finding::Failed(Failure::NotRun);
    }
    for i in first..first + count {
        let statement = results.statement(i);
        if let Some(error) = statement.error() {
            let failure = if error.is_unique_violation() {
                Failure::UniqueViolation
            } else {
                Failure::Server
            };
            return Finding::Failed(failure);
        }
        if !statement.is_ok() {
            return Finding::Failed(Failure::NotRun);
        }
    }
    Finding::Done(results.statement(first + count - 1))
}

/// True when every statement of the pipeline ran, so its transaction committed as a whole.
pub fn all_ok(results: &Results) -> bool {
    results.iter().all(|s| s.is_ok())
}
