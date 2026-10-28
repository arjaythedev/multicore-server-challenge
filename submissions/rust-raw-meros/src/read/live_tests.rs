//! Integration tests against a real PostgreSQL (`#[ignore]` by default; they must pass).
//!
//! Run: `cargo test --lib read::live_tests -- --ignored --test-threads=1`. The database is `READ_TEST_URL`, default
//! `postgres://conduit:conduit@127.0.0.1:5433/conduit_dev`; these tests only read.
//!
//! Method: build batches of requests, run them through the [`Runner`], and compare every response, byte for byte,
//! with the answer of the reference SQL of SPEC.md executed one request at a time and rendered by the same
//! `render.rs` functions.

use crate::app::jobs::{ListKind, ReadKind};
use crate::http::Status;
use crate::pg::Param;

use super::harness::{Coverage, Harness, Pools, Rng, TOKEN};
use super::reference::Req;
use super::runner::Health;
use crate::app::jobs::PasswordKind;

#[test]
#[ignore]
fn random_mixed_batches_match_the_reference() {
    let mut h = Harness::connect();
    let pools = Pools::sample(&mut h);
    let mut rng = Rng(0x5eed_1234_abcd_0001);
    let mut seen = Coverage::default();
    for _ in 0..60 {
        let size = 1 + rng.below(64);
        let reqs: Vec<Req> = (0..size).map(|_| pools.request(&mut rng)).collect();
        seen.merge(h.check_batch(&reqs));
    }
    assert!(seen.substantial * 2 > seen.responses, "{seen:?}");
    assert!(
        seen.favorited > 15 && seen.following > 20 && seen.tagged > 100,
        "{seen:?}"
    );
}

#[test]
#[ignore]
fn every_list_kind_alone_matches_the_reference() {
    let mut h = Harness::connect();
    let pools = Pools::sample(&mut h);
    let mut rng = Rng(77);
    let kinds = [
        ListKind::All,
        ListKind::Tag,
        ListKind::Author,
        ListKind::Favorited,
        ListKind::Feed,
    ];
    for kind in kinds {
        for _ in 0..8 {
            let reqs: Vec<Req> = (0..32)
                .map(|_| {
                    loop {
                        let r = pools.request(&mut rng);
                        if matches!(r.kind, ReadKind::List(k) if k == kind) {
                            break r;
                        }
                    }
                })
                .collect();
            h.check_batch(&reqs);
        }
    }
}

#[test]
#[ignore]
fn edge_cases_match_the_reference() {
    let mut h = Harness::connect();
    let pools = Pools::sample(&mut h);
    let (viewer, follower) = (pools.viewers[0], pools.followers[0]);
    let (slug, tag, author) = (
        pools.slugs[0].clone(),
        pools.tags[0].clone(),
        pools.authors[0].clone(),
    );
    let reqs = vec![
        // anonymous viewer
        Req::list(ListKind::All, 0, "", 10, 0),
        Req::keyed(ReadKind::Article, 0, &slug),
        Req::keyed(ReadKind::Comments, 0, &slug),
        Req::keyed(ReadKind::Profile, 0, &author),
        // real viewer
        Req::list(ListKind::All, viewer, "", 10, 0),
        Req::list(ListKind::Feed, follower, "", 10, 0),
        Req::list(ListKind::Tag, viewer, &tag, 100, 0),
        Req::list(ListKind::Author, viewer, &author, 100, 0),
        // unknown tag / user / slug
        Req::list(ListKind::Tag, viewer, "no-such-tag", 10, 0),
        Req::list(ListKind::Author, viewer, "nobody-here", 10, 0),
        Req::list(ListKind::Favorited, viewer, "nobody-here", 10, 0),
        Req::keyed(ReadKind::Article, viewer, "no-such-slug"),
        Req::keyed(ReadKind::Comments, viewer, "no-such-slug"),
        Req::keyed(ReadKind::Profile, viewer, "nobody-here"),
        Req::keyed(ReadKind::CurrentUser, 999_999_999, TOKEN),
        // offset beyond the end
        Req::list(ListKind::All, viewer, "", 20, 1_000_000),
        Req::list(ListKind::Tag, viewer, &tag, 20, 1_000_000),
        Req::list(ListKind::Feed, follower, "", 20, 1_000_000),
        // unicode and quoting in keys must not matter
        Req::keyed(
            ReadKind::Article,
            0,
            "tab\there \"quoted\" \u{e5}\u{e4}\u{f6}",
        ),
        Req::list(ListKind::Tag, 0, "\u{e5}\u{e4}\u{f6}", 5, 0),
        Req::keyed(ReadKind::Tags, 0, ""),
    ];
    h.check_batch(&reqs);
    // every request alone as well: a batch of one is a different code path through the plan
    for req in &reqs {
        h.check_batch(std::slice::from_ref(req));
    }
}

#[test]
#[ignore]
fn duplicate_requests_share_rows_and_answer_alike() {
    let mut h = Harness::connect();
    let pools = Pools::sample(&mut h);
    let viewer = pools.followers[0];
    let one = |kind, key: &str| Req {
        kind,
        viewer,
        key: key.to_owned(),
        limit: 10,
        offset: 0,
    };
    let mut reqs = Vec::new();
    for _ in 0..5 {
        reqs.push(Req::list(ListKind::All, viewer, "", 10, 0));
        reqs.push(Req::list(ListKind::Feed, viewer, "", 10, 0));
        reqs.push(one(ReadKind::Article, &pools.slugs[0]));
        reqs.push(one(ReadKind::Comments, &pools.slugs[1]));
        reqs.push(Req::keyed(ReadKind::Tags, 0, ""));
    }
    // overlapping pages of the same list, and two viewers over the same page
    reqs.push(Req::list(ListKind::All, viewer, "", 20, 0));
    reqs.push(Req::list(ListKind::All, viewer, "", 10, 5));
    reqs.push(Req::list(ListKind::All, 0, "", 10, 0));
    h.check_batch(&reqs);
    let (answers, _) = h.run_batch(&reqs);
    assert_eq!(answers[0], answers[5]);
    assert_eq!(answers[4], answers[9]);
}

#[test]
#[ignore]
fn tags_are_listed_by_name_and_tag_lists_follow_that_order() {
    let mut h = Harness::connect();
    let (answers, _) = h.run_batch(&[
        Req::keyed(ReadKind::Tags, 0, ""),
        Req::list(ListKind::All, 0, "", 100, 0),
    ]);
    let tags: Vec<String> = h.strings("select name from tags order by name");
    let want = format!(
        "{{\"tags\":[{}]}}",
        tags.iter()
            .map(|t| format!("\"{t}\""))
            .collect::<Vec<_>>()
            .join(",")
    );
    assert_eq!(
        String::from_utf8(answers[0].clone().unwrap().body).unwrap(),
        want
    );
    // every article's tagList is sorted by name
    let text = String::from_utf8(answers[1].clone().unwrap().body).unwrap();
    for list in text.split("\"tagList\":[").skip(1) {
        let names: Vec<&str> = list
            .split(']')
            .next()
            .unwrap()
            .split(',')
            .filter(|s| !s.is_empty())
            .collect();
        assert!(names.windows(2).all(|w| w[0] <= w[1]), "{names:?}");
    }
}

#[test]
#[ignore]
fn login_lookup_hands_the_buffer_to_the_password_queue() {
    let mut h = Harness::connect();
    let email = h
        .strings("select email from users order by id limit 1")
        .remove(0);
    let reqs = [
        Req::keyed(ReadKind::LoginLookup, 0, &email),
        Req::keyed(ReadKind::LoginLookup, 0, "nobody@example.invalid"),
    ];
    let (answers, health) = h.run_batch(&reqs);
    assert_eq!(health, Health::Good);
    assert!(
        answers[0].is_none(),
        "a known email continues on the password thread"
    );
    let unknown = answers[1].clone().unwrap();
    assert_eq!(unknown.status, 401);
    assert_eq!(
        unknown.body,
        br#"{"errors":{"body":["invalid credentials"]}}"#
    );
    let jobs = h.passwords.0.lock().unwrap();
    assert_eq!(jobs.len(), 1);
    let job = &jobs[0];
    let PasswordKind::Verify { user } = &job.kind else {
        panic!("verify job")
    };
    assert_eq!(user.email, email);
    assert_eq!(user.password_hash.len(), 60);
    assert!(user.password_hash.starts_with(b"$2"));
    assert_eq!(
        job.password.text(&job.buf),
        "password123",
        "the request buffer moved with its password"
    );
    assert!(job.origin.keep_alive);
}

#[test]
#[ignore]
fn a_failing_statement_gives_500_to_its_kind_and_the_lane_carries_on() {
    let mut h = Harness::connect();
    let reqs = [
        Req::list(ListKind::All, 0, "", -1, 0),
        Req::keyed(ReadKind::Tags, 0, ""),
    ];
    let (answers, health) = h.run_batch(&reqs);
    assert_eq!(health, Health::Good);
    assert_eq!(answers[0].as_ref().unwrap().status, 500);
    assert_eq!(
        answers[1].as_ref().unwrap().status,
        500,
        "the tag table was skipped behind the failed statement"
    );
    h.check_batch(&[
        Req::list(ListKind::All, 0, "", 5, 0),
        Req::keyed(ReadKind::Tags, 0, ""),
    ]);
}

#[test]
#[ignore]
fn a_poisoned_connection_gives_503_to_the_batch() {
    let mut h = Harness::connect();
    h.check_batch(&[Req::keyed(ReadKind::Tags, 0, "")]);
    let stmt =
        h.db.conn
            .prepare("pid", "select pg_backend_pid()", &[])
            .unwrap();
    h.db.conn.push(&stmt, &[]).unwrap();
    h.db.conn.flush_and_collect(&mut h.results).unwrap();
    let lane_pid = h.results.statement(0).row(0).unwrap().i32(0).unwrap();
    let killer = h
        .reference_conn
        .prepare(
            "kill",
            "select pg_terminate_backend($1::int4)",
            &[crate::pg::INT4],
        )
        .unwrap();
    h.reference_conn
        .push(&killer, &[Param::Int4(lane_pid)])
        .unwrap();
    h.reference_conn.flush_and_collect(&mut h.results).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(100));
    let (answers, health) = h.run_batch(&[
        Req::keyed(ReadKind::Tags, 0, ""),
        Req::list(ListKind::All, 0, "", 5, 0),
    ]);
    assert_eq!(health, Health::Poisoned);
    for a in answers {
        assert_eq!(a.unwrap().status, Status::ServiceUnavailable.code());
    }
}

#[test]
#[ignore]
fn buffers_are_reused_from_batch_to_batch() {
    let mut h = Harness::connect();
    let pools = Pools::sample(&mut h);
    let mut rng = Rng(5);
    let reqs: Vec<Req> = (0..64).map(|_| pools.request(&mut rng)).collect();
    h.run_batch(&reqs);
    let before = h.runner.footprint();
    for _ in 0..20 {
        h.run_batch(&reqs);
    }
    assert_eq!(
        h.runner.footprint(),
        before,
        "the second identical batch needs no new scratch memory"
    );
}
