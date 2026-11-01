//! [`Plan`]: splits a batch into groups by kind and pushes one statement per group present.
//!
//! The statements take parallel arrays, one element per request of the group. The arrays live in vectors owned by
//! the plan and reused from batch to batch; text elements are `&str` slices of each job's own request buffer, so no
//! request text is copied before `Connection::push` writes it to the socket buffer. The only text the plan builds
//! itself is the feed key (the viewer id in decimal), which goes into one reusable byte arena.

use crate::app::jobs::ReadJob;
use crate::json::itoa;
use crate::pg::{Connection, Param, PgError};

use super::scratch::recycle;
use super::statements::{Group, Statements};

#[derive(Default)]
pub struct Plan {
    /// Job indices per group, in queue order.
    members: [Vec<u32>; Group::COUNT],
    /// Index of each group's statement among the pushed ones (and so in `Results`).
    answered_by: [Option<usize>; Group::COUNT],
    tags_at: Option<usize>,
    pushed: usize,
    viewers: Vec<i64>,
    limits: Vec<i64>,
    offsets: Vec<i64>,
    /// Decimal viewer ids for the feed key, back to back.
    digits: Vec<u8>,
    spans: Vec<(u32, u32)>,
    texts: Vec<&'static str>,
}

impl Plan {
    /// Sorts the jobs into groups. Forgets the previous batch.
    pub fn assign(&mut self, jobs: &[ReadJob]) {
        self.members.iter_mut().for_each(Vec::clear);
        self.answered_by = [None; Group::COUNT];
        self.tags_at = None;
        self.pushed = 0;
        for (i, job) in jobs.iter().enumerate() {
            self.members[Group::of(job.kind).index()].push(i as u32);
        }
    }

    /// The jobs (indices into the batch) of a group.
    pub fn members(&self, group: Group) -> &[u32] {
        &self.members[group.index()]
    }

    /// Where the group's answer sits in `Results`; `None` if it has no requests or its push failed.
    pub fn statement_of(&self, group: Group) -> Option<usize> {
        self.answered_by[group.index()]
    }

    /// Where the tag table sits in `Results`, if the batch needed it and it was pushed.
    pub fn tags_statement(&self) -> Option<usize> {
        self.tags_at
    }

    /// Bytes of capacity held by the reusable vectors (tests assert that it stops growing).
    #[cfg(test)]
    pub fn footprint(&self) -> usize {
        let groups: usize = self.members.iter().map(|m| m.capacity() * 4).sum();
        groups
            + (self.viewers.capacity() + self.limits.capacity() + self.offsets.capacity()) * 8
            + self.digits.capacity()
            + self.spans.capacity() * 8
            + self.texts.capacity() * 16
    }

    /// Does anything in the batch need the tag table?
    fn needs_tags(&self) -> bool {
        Group::ALL
            .iter()
            .any(|g| g.needs_tag_table() && !self.members(*g).is_empty())
    }

    /// Pushes one statement per non-empty group, then the tag table once if any group needs it. A push that fails
    /// without breaking the connection (a value too large to encode) leaves that group unanswered; the caller
    /// answers it with 500. Nothing is sent until `Connection::flush_and_collect`.
    pub fn push_all(&mut self, conn: &mut Connection, stmts: &Statements, jobs: &[ReadJob]) {
        for group in Group::ALL {
            let Some(stmt) = stmts.of(group) else {
                continue;
            };
            if self.members(group).is_empty() {
                continue;
            }
            if self.push_group(conn, stmt, group, jobs).is_ok() {
                self.answered_by[group.index()] = Some(self.pushed);
                self.pushed += 1;
            }
        }
        if self.needs_tags() && conn.push(stmts.tags(), &[]).is_ok() {
            self.tags_at = Some(self.pushed);
            self.pushed += 1;
        }
    }

    fn push_group(
        &mut self,
        conn: &mut Connection,
        stmt: &crate::pg::Stmt,
        group: Group,
        jobs: &[ReadJob],
    ) -> Result<(), PgError> {
        let Plan {
            members,
            viewers,
            limits,
            offsets,
            digits,
            spans,
            texts,
            ..
        } = self;
        let members = &members[group.index()];
        viewers.clear();
        viewers.extend(members.iter().map(|&i| jobs[i as usize].viewer));
        let mut keys = recycle(std::mem::take(texts));
        let result = match group {
            Group::ListAll
            | Group::ListTag
            | Group::ListAuthor
            | Group::ListFavorited
            | Group::Feed => {
                limits.clear();
                limits.extend(members.iter().map(|&i| jobs[i as usize].limit));
                offsets.clear();
                offsets.extend(members.iter().map(|&i| jobs[i as usize].offset));
                if group == Group::Feed {
                    fill_decimal_keys(digits, spans, viewers);
                    keys.extend(spans.iter().map(|&(s, e)| decimal_text(digits, s, e)));
                } else {
                    keys.extend(members.iter().map(|&i| key_text(&jobs[i as usize])));
                }
                conn.push(
                    stmt,
                    &[
                        Param::Int8Array(viewers),
                        Param::Int8Array(limits),
                        Param::Int8Array(offsets),
                        Param::TextArray(&keys),
                    ],
                )
            }
            Group::Article | Group::Comments | Group::Profile => {
                keys.extend(members.iter().map(|&i| key_text(&jobs[i as usize])));
                conn.push(stmt, &[Param::Int8Array(viewers), Param::TextArray(&keys)])
            }
            Group::CurrentUser => conn.push(stmt, &[Param::Int8Array(viewers)]),
            Group::Login => {
                keys.extend(members.iter().map(|&i| key_text(&jobs[i as usize])));
                conn.push(stmt, &[Param::TextArray(&keys)])
            }
            Group::Tags => Ok(()),
        };
        *texts = recycle(keys);
        result
    }
}

/// The text a request is about (slug, username, tag, email), borrowed from the job's own buffer.
fn key_text(job: &ReadJob) -> &str {
    job.key.text(&job.buf)
}

fn fill_decimal_keys(digits: &mut Vec<u8>, spans: &mut Vec<(u32, u32)>, ids: &[i64]) {
    digits.clear();
    spans.clear();
    for &id in ids {
        let start = digits.len() as u32;
        itoa::write_i64(digits, id);
        spans.push((start, digits.len() as u32));
    }
}

fn decimal_text(digits: &[u8], start: u32, end: u32) -> &str {
    digits
        .get(start as usize..end as usize)
        .and_then(|d| std::str::from_utf8(d).ok())
        .unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::jobs::{ListKind, ReadKind};
    use crate::read::queue::tests::job;
    use std::time::Instant;

    fn job_of(kind: ReadKind, viewer: i64) -> ReadJob {
        ReadJob {
            kind,
            ..job(viewer, Instant::now())
        }
    }

    #[test]
    fn jobs_are_grouped_in_queue_order() {
        let jobs = vec![
            job_of(ReadKind::Tags, 1),
            job_of(ReadKind::Article, 2),
            job_of(ReadKind::List(ListKind::Feed), 3),
            job_of(ReadKind::Article, 4),
        ];
        let mut plan = Plan::default();
        plan.assign(&jobs);
        assert_eq!(plan.members(Group::Article), [1, 3]);
        assert_eq!(plan.members(Group::Feed), [2]);
        assert_eq!(plan.members(Group::Tags), [0]);
        assert!(plan.members(Group::Profile).is_empty());
        assert!(plan.needs_tags());
        plan.assign(&jobs[..0]);
        assert!(plan.members(Group::Article).is_empty());
        assert!(!plan.needs_tags());
    }

    #[test]
    fn feed_keys_are_the_viewer_ids_in_decimal() {
        let (mut digits, mut spans) = (Vec::new(), Vec::new());
        fill_decimal_keys(&mut digits, &mut spans, &[7, 100_000, 42]);
        let keys: Vec<&str> = spans
            .iter()
            .map(|&(s, e)| decimal_text(&digits, s, e))
            .collect();
        assert_eq!(keys, ["7", "100000", "42"]);
    }

    #[test]
    fn only_comment_free_kinds_skip_the_tag_table() {
        let jobs = vec![job_of(ReadKind::Comments, 0), job_of(ReadKind::Profile, 0)];
        let mut plan = Plan::default();
        plan.assign(&jobs);
        assert!(!plan.needs_tags());
    }
}
