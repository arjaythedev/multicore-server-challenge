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
    /// Every statement ran. The job's answer is row `usize` of the last statement's result: row 0 for a job that
    /// owns its statements, the job's own row for a statement shared by a run of jobs.
    Done(StmtResult<'r>, usize),
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
    Finding::Done(results.statement(first + count - 1), 0)
}

/// Judges job number `row` of a run of `rows` jobs answered by the single statement at `stmt` (one result row per
/// job, in job order). A statement that returns another number of rows broke that contract: the transaction is
/// already committed then, so the jobs are answered 500 instead of being read from the wrong rows.
pub fn finding_for_row(results: &Results, stmt: usize, row: usize, rows: usize) -> Finding<'_> {
    if stmt >= results.len() {
        return Finding::Failed(Failure::NotRun);
    }
    let statement = results.statement(stmt);
    match statement.error() {
        Some(error) if error.is_unique_violation() => Finding::Failed(Failure::UniqueViolation),
        Some(_) => Finding::Failed(Failure::Server),
        None if !statement.is_ok() => Finding::Failed(Failure::NotRun),
        None if statement.row_count() != rows => Finding::Failed(Failure::Server),
        None => Finding::Done(statement, row),
    }
}

/// True when every statement of the pipeline ran, so its transaction committed as a whole.
pub fn all_ok(results: &Results) -> bool {
    results.iter().all(|s| s.is_ok())
}
