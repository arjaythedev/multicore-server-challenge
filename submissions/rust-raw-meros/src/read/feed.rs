//! The feed in two phases, so that the work per followee is done once per batch instead of once per viewer.
//!
//! A feed page is "the newest `limit` articles after `offset`, over everything the viewer's followees wrote".
//! The straightforward statement probes the article index once per followee *per viewer*; a batch of 512 viewers
//! has about 10 500 follow rows but only about 6 100 distinct followees, and a probe is where the time goes. So:
//!
//! * **Phase A** (`sql/feed_lists.sql`, pushed together with the other groups of the batch): for every distinct
//!   followee, its newest articles as one descending id array (deep enough for the most demanding viewer that
//!   follows it), and for every request its followee ids and its capped count.
//! * **Merge** (here, [`merge_page`]): a k-way merge of a viewer's followee lists, descending, yields the ids of
//!   `[offset, offset + limit)`. No row is copied beyond the ids themselves.
//! * **Phase B** (`sql/feed_articles.sql`, a second round trip): the pages' ids go back as parameters and the
//!   statement answers in the "articles" shape, so `articles.rs` decodes and renders it like any other list.
//!
//! A request whose `limit + offset` exceeds [`SHALLOW_CAP`] is *deep*: shipping every followee's list that far
//! would cost more than it saves, so phase B computes that page itself (count `-1`) the way the reference does.
//! Nothing outlives the batch: the lists and pages are rebuilt every time, as the no-cache rule demands.
//!
//! Not handled: a followee list that is shorter than the request needs is taken as complete (phase A asks for
//! `limit + offset` ids per followee, so a short list means the followee has no more articles).

use std::collections::BinaryHeap;

use crate::app::jobs::ReadJob;
use crate::http::Status;
use crate::pg::{Connection, Param, Results, StmtResult};

use super::error::ReadError;
use super::statements::Statements;
use super::table::IdTable;

/// Requests with `limit + offset` above this are computed by phase B alone. The same number is sent to phase A.
pub const SHALLOW_CAP: i64 = 400;
/// Marks a deep request in the `count` parameter of phase B.
const DEEP: i64 = -1;
/// A result arena that grew beyond this is released after the batch.
const KEEP_RESULT_BYTES: usize = 8 << 20;

/// Columns of phase A (see `sql/feed_lists.sql`).
mod col {
    pub const KIND: usize = 0;
    pub const ORD: usize = 1;
    pub const ID: usize = 2;
    pub const IDS: usize = 3;
    pub const TOTAL: usize = 4;
}

const KIND_LIST: i32 = 0;
const KIND_REQUEST: i32 = 1;
/// Marks a request that phase A sent no row for.
const MISSING: u32 = u32::MAX;

/// What the second round trip left behind.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
enum State {
    /// Nothing ran (no feed in the batch, or phase A itself failed and carries the error).
    #[default]
    Idle,
    /// Phase B's answer is in `results`.
    Ready,
    /// Phase A's rows were unusable or phase B could not be pushed; the connection is fine.
    Broken,
    /// The connection failed during phase B.
    Failed { poisoned: bool },
}

/// Reusable memory and state of the feed's two phases.
#[derive(Default)]
pub struct FeedBatch {
    /// Phase B's answer.
    results: Results,
    state: State,
    /// Followee id -> index in `spans`.
    lists: IdTable,
    /// Range of each followee's list in `flat`.
    spans: Vec<(u32, u32)>,
    /// All followees' lists back to back, each descending.
    flat: Vec<i64>,
    /// All requests' followee ids back to back, and each request's range in it.
    followees: Vec<i64>,
    followee_spans: Vec<(u32, u32)>,
    totals: Vec<i64>,
    /// Parameters of phase B, one entry per request (and the merged pages back to back).
    viewers: Vec<i64>,
    limits: Vec<i64>,
    offsets: Vec<i64>,
    starts: Vec<i64>,
    counts: Vec<i64>,
    pages: Vec<i64>,
    heap: BinaryHeap<Head>,
}

/// The front of one followee's list during a merge.
type Head = (i64, u32, u32);

impl FeedBatch {
    #[cfg(test)]
    pub fn footprint(&self) -> usize {
        let ids = self.flat.capacity()
            + self.followees.capacity()
            + self.totals.capacity()
            + self.viewers.capacity()
            + self.limits.capacity()
            + self.offsets.capacity()
            + self.starts.capacity()
            + self.counts.capacity()
            + self.pages.capacity();
        ids * 8
            + (self.spans.capacity() + self.followee_spans.capacity()) * 8
            + self.lists.footprint()
            + self.heap.capacity() * size_of::<Head>()
    }

    /// Runs phase B for the feed `members` of the batch, given phase A's answer. Afterwards [`answer`](Self::answer)
    /// says where the rows to render are. Returns whether the connection is still usable.
    pub fn second_round(
        &mut self,
        conn: &mut Connection,
        stmts: &Statements,
        phase_a: Option<StmtResult<'_>>,
        members: &[u32],
        jobs: &[ReadJob],
    ) -> bool {
        self.state = State::Idle;
        let Some(phase_a) = phase_a.filter(StmtResult::is_ok) else {
            return true;
        };
        if let Err(e) = self.prepare_pages(phase_a, members, jobs) {
            eprintln!("read lane: feed phase A rows unusable: {e}");
            self.state = State::Broken;
            return true;
        }
        let pushed = conn.push(
            stmts.feed_articles(),
            &[
                Param::Int8Array(&self.viewers),
                Param::Int8Array(&self.limits),
                Param::Int8Array(&self.offsets),
                Param::Int8Array(&self.totals),
                Param::Int8Array(&self.starts),
                Param::Int8Array(&self.counts),
                Param::Int8Array(&self.pages),
            ],
        );
        if let Err(e) = pushed {
            eprintln!("read lane: feed phase B not pushed: {e}");
            self.state = if conn.is_poisoned() {
                State::Failed { poisoned: true }
            } else {
                State::Broken
            };
            return self.state == State::Broken;
        }
        self.results.clear();
        if let Err(e) = conn.flush_and_collect(&mut self.results) {
            eprintln!("read lane: feed phase B failed: {e}");
            let poisoned = conn.is_poisoned();
            self.state = State::Failed { poisoned };
            return !poisoned;
        }
        self.state = State::Ready;
        true
    }

    /// What the feed group is answered from: phase B's rows once they exist, otherwise phase A's statement if it
    /// carries an error to report, otherwise nothing.
    pub fn answer<'a>(&'a self, phase_a: Option<StmtResult<'a>>) -> Option<StmtResult<'a>> {
        match self.state {
            State::Ready => Some(self.results.statement(0)),
            State::Idle => phase_a.filter(|s| !s.is_ok()),
            State::Broken | State::Failed { .. } => None,
        }
    }

    /// The status for the whole group if the connection failed during phase B.
    pub fn failure(&self) -> Option<Status> {
        match self.state {
            State::Failed { poisoned: true } => Some(Status::ServiceUnavailable),
            State::Failed { poisoned: false } => Some(Status::Internal),
            _ => None,
        }
    }

    /// Releases an oversized arena (one huge batch must not pin memory).
    pub fn shrink(&mut self) {
        self.results.shrink_if_above(KEEP_RESULT_BYTES);
    }

    /// Reads phase A's rows, merges the pages and fills the parameter vectors of phase B.
    fn prepare_pages(
        &mut self,
        phase_a: StmtResult<'_>,
        members: &[u32],
        jobs: &[ReadJob],
    ) -> Result<(), ReadError> {
        self.read_phase_a(phase_a, members.len())?;
        let FeedBatch {
            lists,
            spans,
            flat,
            followees,
            followee_spans,
            totals,
            viewers,
            limits,
            offsets,
            starts,
            counts,
            pages,
            heap,
            ..
        } = self;
        for v in [&mut *viewers, limits, offsets, starts, counts, pages] {
            v.clear();
        }
        for (at, &job) in members.iter().enumerate() {
            let job = &jobs[job as usize];
            viewers.push(job.viewer);
            limits.push(job.limit);
            offsets.push(job.offset);
            let shallow = job.limit > 0
                && job.offset >= 0
                && job.limit.saturating_add(job.offset) <= SHALLOW_CAP;
            if !shallow {
                starts.push(0);
                counts.push(DEEP);
                continue;
            }
            let (from, to) = followee_spans[at];
            heap.clear();
            for &followee in &followees[from as usize..to as usize] {
                let Some(list) = lists.get(followee) else {
                    continue;
                };
                let (start, end) = spans[list as usize];
                if start < end {
                    heap.push((flat[start as usize], list, start));
                }
            }
            let first = pages.len();
            merge_page(
                heap,
                spans,
                flat,
                job.offset as usize,
                job.limit as usize,
                pages,
            );
            starts.push(first as i64 + 1);
            counts.push((pages.len() - first) as i64);
        }
        debug_assert_eq!(totals.len(), members.len());
        Ok(())
    }

    /// Decodes phase A: the followees' lists into `flat`/`spans`, and per request its followees and total.
    fn read_phase_a(&mut self, stmt: StmtResult<'_>, requests: usize) -> Result<(), ReadError> {
        self.lists.reset(stmt.row_count());
        self.spans.clear();
        self.flat.clear();
        self.followees.clear();
        self.followee_spans.clear();
        self.followee_spans.resize(requests, (MISSING, MISSING));
        self.totals.clear();
        self.totals.resize(requests, 0);
        for row in stmt.rows() {
            if row.i32(col::KIND)? == KIND_LIST {
                let start = self.flat.len();
                self.flat.extend(row.i64_array(col::IDS)?);
                let at = self.spans.len() as u32;
                self.spans.push((start as u32, self.flat.len() as u32));
                if !self.lists.insert(row.i64(col::ID)?, at) {
                    return Err(ReadError::Inconsistent("followee listed twice"));
                }
            } else if row.i32(col::KIND)? == KIND_REQUEST {
                let ord = usize::try_from(row.i64(col::ORD)? - 1).unwrap_or(usize::MAX);
                let Some(slot) = self.followee_spans.get_mut(ord) else {
                    return Err(ReadError::Inconsistent("ordinality outside the batch"));
                };
                if slot.0 != MISSING {
                    return Err(ReadError::Inconsistent("request listed twice"));
                }
                let start = self.followees.len() as u32;
                self.followees.extend(row.i64_array(col::IDS)?);
                *slot = (start, self.followees.len() as u32);
                self.totals[ord] = row.i64(col::TOTAL)?;
            }
        }
        if self.followee_spans.iter().any(|s| s.0 == MISSING) {
            return Err(ReadError::Inconsistent("request without a row"));
        }
        Ok(())
    }
}

/// Appends the ids of positions `[skip, skip + take)` of the descending merge of the lists whose fronts are in
/// `heap` (each entry is the front value, the list's index in `spans` and the position in `flat`).
///
/// A binary heap keeps the cost at `O((skip + take) log k)` for `k` lists, whatever `k` is, and stops as soon as
/// the page is full: lists are never read past what the page needs.
fn merge_page(
    heap: &mut BinaryHeap<Head>,
    spans: &[(u32, u32)],
    flat: &[i64],
    skip: usize,
    take: usize,
    out: &mut Vec<i64>,
) {
    let mut seen = 0usize;
    while seen < skip + take {
        let Some((id, list, at)) = heap.pop() else {
            return;
        };
        if seen >= skip {
            out.push(id);
        }
        seen += 1;
        let next = at + 1;
        if next < spans[list as usize].1 {
            heap.push((flat[next as usize], list, next));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Lists as `flat`/`spans` and the heap holding their fronts.
    fn load(lists: &[&[i64]]) -> (BinaryHeap<Head>, Vec<(u32, u32)>, Vec<i64>) {
        let (mut flat, mut spans, mut heap) = (Vec::new(), Vec::new(), BinaryHeap::new());
        for (i, list) in lists.iter().enumerate() {
            let start = flat.len() as u32;
            flat.extend_from_slice(list);
            spans.push((start, flat.len() as u32));
            if !list.is_empty() {
                heap.push((list[0], i as u32, start));
            }
        }
        (heap, spans, flat)
    }

    fn page(lists: &[&[i64]], skip: usize, take: usize) -> Vec<i64> {
        let (mut heap, spans, flat) = load(lists);
        let mut out = vec![-7];
        merge_page(&mut heap, &spans, &flat, skip, take, &mut out);
        assert_eq!(out[0], -7, "the output is appended to");
        out.remove(0);
        out
    }

    #[test]
    fn merges_descending_lists_into_one_page() {
        let lists: [&[i64]; 3] = [&[9, 5, 1], &[8, 7], &[6, 4, 3, 2]];
        assert_eq!(page(&lists, 0, 4), [9, 8, 7, 6]);
        assert_eq!(page(&lists, 3, 3), [6, 5, 4]);
        assert_eq!(page(&lists, 0, 100), [9, 8, 7, 6, 5, 4, 3, 2, 1]);
    }

    #[test]
    fn a_page_past_the_end_is_short_or_empty() {
        let lists: [&[i64]; 2] = [&[3, 1], &[2]];
        assert_eq!(page(&lists, 2, 5), [1]);
        assert!(page(&lists, 3, 5).is_empty());
        assert!(page(&lists, 1_000, 5).is_empty());
        assert!(page(&[], 0, 10).is_empty());
        assert!(page(&[&[], &[]], 0, 10).is_empty());
    }

    #[test]
    fn matches_a_sort_of_everything_on_pseudo_random_lists() {
        let mut state = 0x2545_f491_4f6c_dd1d_u64;
        let mut next = move |bound: u64| {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state % bound
        };
        for _ in 0..300 {
            // distinct ids spread over the lists, each list descending
            let mut owned: Vec<Vec<i64>> = vec![Vec::new(); 1 + next(30) as usize];
            for id in 0..(next(120) as i64) {
                let owner = next(owned.len() as u64) as usize;
                owned[owner].push(id);
            }
            owned.iter_mut().for_each(|l| l.reverse());
            let lists: Vec<&[i64]> = owned.iter().map(Vec::as_slice).collect();
            let mut all: Vec<i64> = owned.iter().flatten().copied().collect();
            all.sort_unstable_by(|a, b| b.cmp(a));
            let (skip, take) = (next(60) as usize, 1 + next(30) as usize);
            let want: Vec<i64> = all.iter().copied().skip(skip).take(take).collect();
            assert_eq!(page(&lists, skip, take), want);
        }
    }

    #[test]
    fn the_cap_leaves_room_for_the_largest_ordinary_page() {
        // limit 100 (the most SPEC allows) with an offset of 300 is still shallow
        const { assert!(100 + 300 <= SHALLOW_CAP) };
    }
}
