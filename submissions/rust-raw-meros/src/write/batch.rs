//! Planning a group: which jobs share one statement and which keep their own.
//!
//! A run of favorites, comments or follows can be sent as ONE statement that takes the jobs' parameters as arrays
//! and returns one row per job in job order (`sql/*_many.sql`). The answer of every job must be the one the
//! sequential statements would have given, so the planner only merges what provably commutes:
//!
//! * **Barriers.** Register, update user, create / update / delete article and delete comment each stay a
//!   statement of their own and cut the group into *segments*: they change the rows the batchable kinds look up
//!   (a slug, a username, an author), so a favorite may not move across them. Only the jobs between two barriers
//!   (a segment) are regrouped, by kind.
//! * **Kinds commute inside a segment**, with one exception: a follow changes the `following` flag that a favorite
//!   of the same viewer reports. A segment with a follow and a favorite of the same viewer is therefore left
//!   entirely sequential.
//! * **A repeated pair** (the same viewer favoriting or following the same target twice, with or without an undo
//!   in between) makes the second write depend on the first, so that kind is left sequential in its segment.
//!   Two different viewers on one article are fine: the statement computes the running count per article.
//! * A kind with a single job in a segment gains nothing from an array statement and stays a plain statement.
//!
//! Not handled on purpose: reordering across a barrier, merging register / create article (their ids and unique
//! violations make a partial failure unattributable), and splitting a segment to rescue a kind that has a repeated
//! pair (the lane's single-job fallback already makes a bad group cost only itself).

use crate::app::jobs::{WriteJob, WriteKind};

/// Fewer jobs of one kind than this in a segment are sent as plain statements.
pub const MIN_RUN: usize = 2;

/// The kinds that have an array statement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunKind {
    Favorite,
    Comment,
    Follow,
}

/// One step of the pipeline.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// The statements of job `i` as `push_job` makes them.
    Single(usize),
    /// One array statement for the jobs `Plan::order[start..end]`, in job order.
    Run {
        kind: RunKind,
        start: usize,
        end: usize,
    },
}

/// The steps of a group, in pipeline order. Reused from group to group.
#[derive(Default, Debug)]
pub struct Plan {
    pub steps: Vec<Step>,
    /// Job indexes of the runs; a run owns a contiguous range.
    pub order: Vec<usize>,
}

impl Plan {
    /// The job indexes of a run.
    pub fn members(&self, start: usize, end: usize) -> &[usize] {
        &self.order[start..end]
    }
}

/// Which batchable kind a job is, if any.
fn run_kind(job: &WriteJob) -> Option<RunKind> {
    match job.kind {
        WriteKind::Favorite { .. } => Some(RunKind::Favorite),
        WriteKind::AddComment { .. } => Some(RunKind::Comment),
        WriteKind::Follow { .. } => Some(RunKind::Follow),
        _ => None,
    }
}

/// The text that, with the viewer, identifies what a favorite or follow touches.
fn target(job: &WriteJob) -> Option<&str> {
    match &job.kind {
        WriteKind::Favorite { slug, .. } => Some(slug.text(&job.buf)),
        WriteKind::Follow { username, .. } => Some(username.text(&job.buf)),
        _ => None,
    }
}

/// True when some (viewer, target) pair occurs twice among `members`.
fn repeats_a_pair(jobs: &[WriteJob], members: &[usize]) -> bool {
    let mut pairs: Vec<(i64, &str)> = members
        .iter()
        .filter_map(|&i| target(&jobs[i]).map(|t| (jobs[i].viewer, t)))
        .collect();
    pairs.sort_unstable();
    pairs.windows(2).any(|w| w[0] == w[1])
}

/// True when a follow and a favorite of one viewer are both in the segment.
fn follow_meets_favorite(jobs: &[WriteJob], favorites: &[usize], follows: &[usize]) -> bool {
    follows
        .iter()
        .any(|&f| favorites.iter().any(|&v| jobs[v].viewer == jobs[f].viewer))
}

/// Builds the plan for `jobs` into `plan` (cleared first).
pub fn plan_group(jobs: &[WriteJob], plan: &mut Plan) {
    plan.steps.clear();
    plan.order.clear();
    // The open segment: job indexes per kind, in job order.
    let mut segment: [Vec<usize>; 3] = Default::default();
    for (i, job) in jobs.iter().enumerate() {
        match run_kind(job) {
            Some(kind) => segment[kind as usize].push(i),
            None => {
                close_segment(jobs, &mut segment, plan);
                plan.steps.push(Step::Single(i));
            }
        }
    }
    close_segment(jobs, &mut segment, plan);
}

/// Turns the open segment into steps and empties it.
fn close_segment(jobs: &[WriteJob], segment: &mut [Vec<usize>; 3], plan: &mut Plan) {
    let [favorites, comments, follows] = segment;
    if follow_meets_favorite(jobs, favorites, follows) {
        // Not commutable: every job keeps its own statement, in job order.
        let mut all: Vec<usize> = [&favorites[..], &comments[..], &follows[..]].concat();
        all.sort_unstable();
        plan.steps.extend(all.into_iter().map(Step::Single));
        for members in [favorites, comments, follows] {
            members.clear();
        }
        return;
    }
    for (kind, members) in [
        (RunKind::Favorite, favorites),
        (RunKind::Comment, comments),
        (RunKind::Follow, follows),
    ] {
        let mergeable = members.len() >= MIN_RUN
            && (kind == RunKind::Comment || !repeats_a_pair(jobs, members));
        if mergeable {
            let start = plan.order.len();
            plan.order.extend_from_slice(members);
            plan.steps.push(Step::Run {
                kind,
                start,
                end: plan.order.len(),
            });
        } else {
            plan.steps.extend(members.iter().map(|&i| Step::Single(i)));
        }
        members.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::write::test_support::{
        add_comment, create_article, delete_comment, favorite, follow,
    };

    fn plan_of(jobs: &[WriteJob]) -> Vec<Step> {
        let mut plan = Plan::default();
        plan_group(jobs, &mut plan);
        plan.steps
    }

    fn run(kind: RunKind, start: usize, end: usize) -> Step {
        Step::Run { kind, start, end }
    }

    #[test]
    fn kinds_in_one_segment_become_one_run_each() {
        let jobs = vec![
            favorite(1, "a", true),
            add_comment(1, "a", "x"),
            favorite(2, "a", true),
            favorite(3, "b", false),
            add_comment(2, "a", "y"),
            follow(7, "bob", true),
            follow(8, "bob", false),
        ];
        assert_eq!(
            plan_of(&jobs),
            vec![
                run(RunKind::Favorite, 0, 3),
                run(RunKind::Comment, 3, 5),
                run(RunKind::Follow, 5, 7),
            ]
        );
    }

    #[test]
    fn a_barrier_cuts_the_segment() {
        let jobs = vec![
            favorite(1, "a", true),
            favorite(2, "a", true),
            create_article(1, "New one", &[]),
            favorite(3, "a", true),
            favorite(4, "a", true),
            delete_comment(1, "a", 5),
        ];
        assert_eq!(
            plan_of(&jobs),
            vec![
                run(RunKind::Favorite, 0, 2),
                Step::Single(2),
                run(RunKind::Favorite, 2, 4),
                Step::Single(5),
            ]
        );
    }

    #[test]
    fn a_single_job_of_a_kind_stays_plain() {
        let jobs = vec![favorite(1, "a", true), add_comment(1, "a", "x")];
        assert_eq!(plan_of(&jobs), vec![Step::Single(0), Step::Single(1)]);
    }

    #[test]
    fn a_repeated_pair_keeps_only_its_kind_sequential() {
        let jobs = vec![
            favorite(1, "a", true),
            favorite(1, "a", false),
            favorite(2, "a", true),
            add_comment(1, "a", "x"),
            add_comment(2, "a", "y"),
        ];
        assert_eq!(
            plan_of(&jobs),
            vec![
                Step::Single(0),
                Step::Single(1),
                Step::Single(2),
                run(RunKind::Comment, 0, 2),
            ]
        );
        // The same viewer on another article, or another viewer on the same article, is not a repeat.
        let jobs = vec![
            favorite(1, "a", true),
            favorite(1, "b", true),
            favorite(2, "a", true),
        ];
        assert_eq!(plan_of(&jobs), vec![run(RunKind::Favorite, 0, 3)]);
        let jobs = vec![follow(1, "bob", true), follow(1, "bob", false)];
        assert_eq!(plan_of(&jobs), vec![Step::Single(0), Step::Single(1)]);
    }

    #[test]
    fn a_follow_and_a_favorite_of_one_viewer_keep_the_segment_sequential() {
        let jobs = vec![
            follow(1, "bob", true),
            favorite(1, "a", true),
            favorite(2, "a", true),
            add_comment(3, "a", "x"),
            add_comment(3, "a", "y"),
        ];
        assert!(plan_of(&jobs).iter().all(|s| matches!(s, Step::Single(_))));
        // Different viewers: the follow cannot change what the favorites report.
        let jobs = vec![
            follow(9, "bob", true),
            follow(9, "al", true),
            favorite(1, "a", true),
            favorite(2, "a", true),
        ];
        assert_eq!(
            plan_of(&jobs),
            vec![run(RunKind::Favorite, 0, 2), run(RunKind::Follow, 2, 4)]
        );
    }

    #[test]
    fn every_job_appears_exactly_once() {
        let jobs = vec![
            favorite(1, "a", true),
            create_article(1, "T", &[]),
            favorite(2, "a", true),
            favorite(3, "a", true),
            add_comment(1, "a", "x"),
            follow(1, "z", true),
            add_comment(1, "a", "x"),
        ];
        let mut plan = Plan::default();
        plan_group(&jobs, &mut plan);
        let mut seen = Vec::new();
        for step in &plan.steps {
            match *step {
                Step::Single(i) => seen.push(i),
                Step::Run { start, end, .. } => seen.extend_from_slice(plan.members(start, end)),
            }
        }
        seen.sort_unstable();
        assert_eq!(seen, (0..jobs.len()).collect::<Vec<_>>());
    }
}
