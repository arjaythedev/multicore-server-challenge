//! [`Runner`]: executes one batch. Plan -> push -> one round trip -> decode and render per group -> deliver.
//!
//! The runner owns every buffer the batch needs (result arena, plan arrays, lookup tables, scratch vectors), so the
//! steady state allocates nothing except what the responses themselves need, and those come from the buffer pool.

use crate::app::jobs::ReadJob;
use crate::http::Status;
use crate::net::{Mailboxes, Reply};
use crate::pg::{Connection, Results, StmtResult};
use crate::pool::POOL;

use super::articles::{Articles, GroupCtx};
use super::comments::Comments;
use super::error::ReadError;
use super::plan::Plan;
use super::scratch::recycle;
use super::simple::{self, PasswordSink};
use super::sink::Sink;
use super::statements::{Group, Statements};
use super::table::IdTable;
use super::tags::{self, TagView};

/// A result arena that grew beyond this is released after the batch, so one huge batch does not pin memory.
const KEEP_RESULT_BYTES: usize = 8 << 20;

/// Did the connection survive the batch?
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Health {
    Good,
    /// The stream is out of sync; the owner must reconnect before the next batch.
    Poisoned,
}

#[derive(Default)]
pub struct Runner {
    results: Results,
    plan: Plan,
    sink: Sink,
    shapes: Shapes,
    tag_names: Vec<&'static str>,
    tag_ranks: IdTable,
    tags_body: Vec<u8>,
    /// Request buffers on their way back to the pool.
    spent: Vec<Vec<u8>>,
    /// Replies grouped by owning io thread, so each owner is woken once.
    per_owner: Vec<Vec<Reply>>,
    /// Jobs of a group whose shared statement failed: each is run alone, so one bad request cannot fail the others.
    retry: Vec<u32>,
}

impl Runner {
    pub fn new() -> Runner {
        Runner::default()
    }

    /// Capacity held by the reusable scratch (tests assert that it stops growing once the batches repeat).
    #[cfg(test)]
    pub fn footprint(&self) -> usize {
        self.plan.footprint()
            + self.shapes.articles.footprint()
            + self.shapes.comments.footprint()
            + self.tag_ranks.footprint()
            + self.tag_names.capacity() * 16
            + self.tags_body.capacity()
            + self.spent.capacity() * 24
            + self.sink.replies.capacity() * size_of::<Reply>()
    }

    /// The replies produced by the last `run` / `fail_all` and not yet delivered.
    pub fn replies(&self) -> &[Reply] {
        &self.sink.replies
    }

    /// Answers every job with `status` (no usable connection).
    pub fn fail_all(&mut self, jobs: &[ReadJob], status: Status) {
        self.sink.clear();
        self.fail_jobs(jobs, status);
    }

    /// Like [`fail_all`](Self::fail_all) but keeps the replies already produced.
    fn fail_jobs(&mut self, jobs: &[ReadJob], status: Status) {
        let message = if status == Status::ServiceUnavailable {
            "database unavailable"
        } else {
            "internal error"
        };
        for job in jobs {
            self.sink.error(job.origin, status, message);
        }
    }

    /// Runs the batch against `conn`: one statement per group present, one flush. Leaves a reply for every job in
    /// [`replies`](Self::replies), except logins that moved on to the password queue.
    pub fn run(
        &mut self,
        conn: &mut Connection,
        stmts: &Statements,
        jobs: &mut [ReadJob],
        passwords: &dyn PasswordSink,
    ) -> Health {
        self.sink.clear();
        let health = self.execute(conn, stmts, jobs, passwords);
        if health == Health::Good && !self.retry.is_empty() {
            let retry = std::mem::take(&mut self.retry);
            for &index in &retry {
                let one = &mut jobs[index as usize..=index as usize];
                if self.execute(conn, stmts, one, passwords) == Health::Poisoned {
                    self.retry = retry;
                    self.retry.clear();
                    return Health::Poisoned;
                }
            }
            self.retry = retry;
            self.retry.clear();
        }
        health
    }

    /// One round trip for `jobs`; replies are appended to the sink. A group of several jobs whose statement failed is
    /// not answered here: its jobs are queued in `retry`.
    fn execute(
        &mut self,
        conn: &mut Connection,
        stmts: &Statements,
        jobs: &mut [ReadJob],
        passwords: &dyn PasswordSink,
    ) -> Health {
        self.plan.assign(jobs);
        self.plan.push_all(conn, stmts, jobs);
        self.results.clear();
        if let Err(e) = conn.flush_and_collect(&mut self.results) {
            eprintln!("read lane: batch of {} failed: {e}", jobs.len());
            let poisoned = conn.is_poisoned();
            self.fail_jobs(
                jobs,
                if poisoned {
                    Status::ServiceUnavailable
                } else {
                    Status::Internal
                },
            );
            return if poisoned {
                Health::Poisoned
            } else {
                Health::Good
            };
        }
        self.answer_groups(jobs, passwords);
        self.results.shrink_if_above(KEEP_RESULT_BYTES);
        Health::Good
    }

    fn answer_groups(&mut self, jobs: &mut [ReadJob], passwords: &dyn PasswordSink) {
        let Runner {
            results,
            plan,
            sink,
            shapes,
            tag_names,
            tag_ranks,
            tags_body,
            retry,
            ..
        } = self;
        let mut names = recycle(std::mem::take(tag_names));
        let tags_ok = plan
            .tags_statement()
            .map(|at| results.statement(at))
            .is_some_and(|stmt| stmt.is_ok() && tags::load(stmt, &mut names, tag_ranks).is_ok());
        for group in Group::ALL {
            let members = plan.members(group);
            if members.is_empty() {
                continue;
            }
            sink.begin_group(members.len());
            let stmt = plan.statement_of(group).map(|at| results.statement(at));
            if let Some(error) = stmt.and_then(|s| s.error()) {
                eprintln!("read lane: {group:?} statement failed: {error}");
                if members.len() > 1 {
                    retry.extend_from_slice(members);
                    continue;
                }
            }
            let usable = !group.needs_tag_table() || tags_ok;
            if usable {
                let tag_view = TagView {
                    names: &names,
                    ranks: tag_ranks,
                };
                let mut ctx = Ctx {
                    group,
                    members,
                    tags: &tag_view,
                    tags_body,
                    passwords,
                };
                if let Err(e) = answer_group(stmt, &mut ctx, jobs, shapes, sink) {
                    eprintln!("read lane: {group:?}: {e}");
                }
            }
            sink.fail_unanswered(members, jobs, Status::Internal);
        }
        *tag_names = recycle(names);
    }

    /// Posts the replies (one wake-up per io thread) and returns the request buffers to the pool.
    pub fn deliver(&mut self, jobs: &mut Vec<ReadJob>, mailboxes: &Mailboxes) {
        for reply in self.sink.replies.drain(..) {
            let owner = reply.conn.io as usize;
            if self.per_owner.len() <= owner {
                self.per_owner.resize_with(owner + 1, Vec::new);
            }
            self.per_owner[owner].push(reply);
        }
        for (owner, group) in self.per_owner.iter_mut().enumerate() {
            if !group.is_empty() {
                mailboxes.get(owner).post_all(group);
            }
        }
        self.recycle_requests(jobs);
    }

    /// Returns the request buffers of `jobs` to the pool and empties the batch.
    pub fn recycle_requests(&mut self, jobs: &mut Vec<ReadJob>) {
        self.spent.extend(jobs.drain(..).map(|job| job.buf));
        POOL.put_all(&mut self.spent);
    }
}

/// What a group needs besides its rows.
struct Ctx<'x> {
    group: Group,
    members: &'x [u32],
    tags: &'x TagView<'x>,
    tags_body: &'x mut Vec<u8>,
    passwords: &'x dyn PasswordSink,
}

/// Reusable decoders for the statements that return more than one row per request.
#[derive(Default)]
struct Shapes {
    articles: Articles,
    comments: Comments,
}

/// Dispatches a group to its decoder. `stmt` is `None` for `Tags` (no statement of its own) and for a group whose
/// push failed; a failed statement is left for the caller to answer with 500.
fn answer_group(
    stmt: Option<StmtResult<'_>>,
    ctx: &mut Ctx<'_>,
    jobs: &mut [ReadJob],
    shapes: &mut Shapes,
    sink: &mut Sink,
) -> Result<(), ReadError> {
    if ctx.group == Group::Tags {
        answer_tags(ctx.tags_body, ctx.tags.names, ctx.members, jobs, sink);
        return Ok(());
    }
    let Some(stmt) = stmt.filter(StmtResult::is_ok) else {
        return Ok(());
    };
    let shared = GroupCtx {
        group: ctx.group,
        members: ctx.members,
        jobs,
    };
    match ctx.group {
        Group::Login => simple::logins(stmt, ctx.members, jobs, sink, ctx.passwords),
        Group::Comments => shapes.comments.answer(stmt, &shared, sink),
        Group::Profile => simple::profiles(stmt, &shared, sink),
        Group::CurrentUser => simple::current_users(stmt, &shared, sink),
        _ => shapes.articles.answer(stmt, &shared, ctx.tags, sink),
    }
}

/// The tag list is rendered once; each reply gets its own copy because each owns its buffer.
fn answer_tags(
    body: &mut Vec<u8>,
    names: &[&str],
    members: &[u32],
    jobs: &[ReadJob],
    sink: &mut Sink,
) {
    body.clear();
    tags::write_json(body, names);
    for (ord, &job) in members.iter().enumerate() {
        if sink.claim(ord as i64 + 1).is_ok() {
            sink.raw(jobs[job as usize].origin, Status::Ok, body);
        }
    }
}
