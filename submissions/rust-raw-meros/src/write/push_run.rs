//! Turning a run of jobs of one kind into ONE array statement (see `batch.rs` for which runs are allowed).
//!
//! The parameters are `&str` slices of the jobs' own request buffers, collected into three small vectors per run
//! and copied once into the connection's outgoing buffer. The statement answers with one row per job in job order.

use super::batch::RunKind;
use super::statements::Statements;
use crate::app::jobs::{WriteJob, WriteKind};
use crate::pg::{Connection, Param, PgError};

/// Pushes the array statement of `kind` for `members` (indexes into `jobs`, in job order). Every member must be of
/// `kind` (the planner guarantees it); a job of another kind would contribute empty text and match nothing.
pub fn push_run(
    conn: &mut Connection,
    s: &Statements,
    jobs: &[WriteJob],
    kind: RunKind,
    members: &[usize],
) -> Result<(), PgError> {
    let viewers: Vec<i64> = members.iter().map(|&i| jobs[i].viewer).collect();
    let texts: Vec<&str> = members.iter().map(|&i| job_text(&jobs[i]).0).collect();
    match kind {
        RunKind::Comment => {
            let bodies: Vec<&str> = members.iter().map(|&i| job_text(&jobs[i]).1).collect();
            conn.push(
                &s.comment_many,
                &[
                    Param::TextArray(&texts),
                    Param::Int8Array(&viewers),
                    Param::TextArray(&bodies),
                ],
            )
        }
        RunKind::Favorite | RunKind::Follow => {
            let flags: Vec<i64> = members
                .iter()
                .map(|&i| i64::from(job_flag(&jobs[i])))
                .collect();
            let stmt = if kind == RunKind::Favorite {
                &s.favorite_many
            } else {
                &s.follow_many
            };
            conn.push(
                stmt,
                &[
                    Param::Int8Array(&viewers),
                    Param::TextArray(&texts),
                    Param::Int8Array(&flags),
                ],
            )
        }
    }
}

/// The target text (slug or username) and, for a comment, its body.
fn job_text(job: &WriteJob) -> (&str, &str) {
    let buf = job.buf.as_slice();
    match &job.kind {
        WriteKind::Favorite { slug, .. } => (slug.text(buf), ""),
        WriteKind::Follow { username, .. } => (username.text(buf), ""),
        WriteKind::AddComment { slug, body } => (slug.text(buf), body.text(buf)),
        _ => ("", ""),
    }
}

/// True for favorite / follow, false for unfavorite / unfollow (and for any other kind).
fn job_flag(job: &WriteJob) -> bool {
    matches!(
        job.kind,
        WriteKind::Favorite { favorite: true, .. } | WriteKind::Follow { follow: true, .. }
    )
}
