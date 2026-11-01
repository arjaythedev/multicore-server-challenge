//! Integration tests of group commit itself: one transaction per batch, the single-job fallback, read-your-writes,
//! concurrency, a dropped connection, and the queue plus threads end to end. `#[ignore]`d like `live_tests`.

use std::sync::Arc;
use std::time::{Duration, Instant};

use super::lane::spawn_lanes;
use super::queue::WriteQueue;
use super::test_proxy::CuttableProxy;
use super::test_support::*;
use crate::app::jobs::WriteJob;
use crate::jwt::Jwt;
use crate::net::{Mailboxes, Reply};

/// The state a script runs against: three users, four articles by the first, comments by the others.
struct Fixture {
    users: [(i64, String); 3],
    slugs: Vec<String>,
    comments: Vec<i64>,
}

fn fixture(h: &mut Harness) -> Fixture {
    let users = [new_user(h, "xa"), new_user(h, "xb"), new_user(h, "xc")];
    let slugs: Vec<String> = (0..4)
        .map(|i| {
            let tags: &[&str] = if i == 0 { &["x", "y"] } else { &[] };
            h.run_one(create_article(
                users[0].0,
                &format!("Fixture article {i}"),
                tags,
            ))
            .text(&["article", "slug"])
        })
        .collect();
    let comments = (0..6)
        .map(|i| {
            let (viewer, slug) = if i < 4 {
                (users[1].0, &slugs[0])
            } else {
                (users[2].0, &slugs[0])
            };
            h.run_one(add_comment(viewer, slug, &format!("seed {i}")))
                .number(&["comment", "id"])
        })
        .collect();
    Fixture {
        users,
        slugs,
        comments,
    }
}

/// Exactly 50 mixed writes, no statement of which fails on the server (errors are all "no row" answers).
fn script(f: &Fixture, sfx: &str) -> Vec<WriteJob> {
    let [(a, a_name), (b, _), (c, _)] =
        [&f.users[0], &f.users[1], &f.users[2]].map(|u| (u.0, u.1.clone()));
    let (s0, s1, s2, s3) = (&f.slugs[0], &f.slugs[1], &f.slugs[2], &f.slugs[3]);
    let (dup, other, solo) = (
        format!("dup{sfx}"),
        format!("other{sfx}"),
        format!("solo{sfx}"),
    );
    let mut jobs = vec![
        create_article(a, &format!("Group article 0 {sfx}"), &[]),
        create_article(b, &format!("Group article 1 {sfx}"), &[&dup, &dup, &other]),
        create_article(c, &format!("Group article 2 {sfx}"), &[&solo]),
        create_article(a, &format!("Group article 3 {sfx}"), &[&dup]),
        create_article(b, &format!("Group article 4 {sfx}"), &[]),
        create_article(c, &format!("Group article 5 {sfx}"), &[&other, &solo]),
    ];
    for i in 0..3 {
        jobs.push(register(
            &format!("gnew{i}{sfx}"),
            &format!("gnew{i}{sfx}@example.com"),
        ));
    }
    jobs.push(register(
        &format!("gnew0{sfx}"),
        &format!("again{sfx}@example.com"),
    ));
    jobs.extend([
        update_user(b, None, None, Some("new bio")),
        update_user(c, Some(&format!("c2{sfx}@example.com")), None, None),
        follow(b, &a_name, true),
        follow(c, &a_name, true),
        follow(b, &a_name, false),
        follow(a, &format!("nobody{sfx}"), true),
        favorite(b, s0, true),
        favorite(c, s0, true),
        favorite(a, s0, true),
        favorite(b, s0, true),
        favorite(c, s0, false),
        favorite(a, s1, false),
        favorite(a, &format!("missing{sfx}"), true),
        favorite(b, s1, true),
        favorite(c, s1, true),
        add_comment(a, s1, "first"),
        add_comment(b, s1, "second"),
        add_comment(a, &format!("missing{sfx}"), "lost"),
        delete_comment(b, s0, f.comments[0]),
        delete_comment(a, s0, f.comments[1]),
        delete_comment(c, s0, f.comments[4]),
        delete_comment(b, s0, 999_999_999_999),
        delete_comment(b, s2, f.comments[2]),
        update_article(a, s2, Some(&format!("Retitled {sfx}")), None),
        update_article(b, s3, None, Some("hijack")),
        update_article(a, &format!("missing{sfx}"), None, Some("x")),
        delete_article(a, s3),
        delete_article(b, s2),
        delete_article(a, &format!("missing{sfx}")),
    ]);
    for viewer in 1.. {
        if jobs.len() == 50 {
            break;
        }
        jobs.push(favorite(viewer, s1, true));
    }
    jobs
}

fn xmins(sql_from_where: &str) -> i64 {
    count(&format!(
        "select count(distinct xmin::text) from {sql_from_where}"
    ))
}

#[test]
#[ignore]
fn a_group_of_50_gives_the_same_result_as_one_by_one_and_commits_once() {
    let mut h = Harness::new();
    let (sfx_group, sfx_single) = (unique("g"), unique("s"));
    let (grouped, single) = (fixture(&mut h), fixture(&mut h));
    let jobs = script(&grouped, &sfx_group);
    assert_eq!(jobs.len(), 50);
    let in_group = h.run(jobs);
    let one_by_one = h.run_each(script(&single, &sfx_single));
    let sigs = |resps: &[Resp], f: &Fixture, sfx: &str| -> Vec<String> {
        let names: Vec<&str> = f.users.iter().map(|u| u.1.as_str()).collect();
        let subs = [
            (names[0], "UA"),
            (names[1], "UB"),
            (names[2], "UC"),
            (sfx, "SFX"),
        ];
        resps.iter().map(|r| r.signature(&subs)).collect()
    };
    let group_sigs = sigs(&in_group, &grouped, &sfx_group);
    let single_sigs = sigs(&one_by_one, &single, &sfx_single);
    for (i, (g, s)) in group_sigs.iter().zip(&single_sigs).enumerate() {
        assert_eq!(g, s, "job {i} differs");
    }
    let statuses: Vec<u16> = in_group.iter().map(|r| r.status).collect();
    for expected in [201, 422, 200, 404, 403, 204] {
        assert!(
            statuses.contains(&expected),
            "the script covers {expected}: {statuses:?}"
        );
    }
    let created = |sfx: &str| format!("articles where title like 'Group article % {sfx}'");
    assert_eq!(
        xmins(&created(&sfx_group)),
        1,
        "the group is one transaction"
    );
    assert_eq!(
        xmins(&created(&sfx_single)),
        6,
        "one by one is one transaction per job"
    );
    assert_eq!(
        count(&format!("select count(*) from {}", created(&sfx_group))),
        6
    );
    let favorites = |f: &Fixture| {
        count(&format!(
            "select count(*) from favorites where article_id in (select id from articles where slug = '{}')",
            f.slugs[1]
        ))
    };
    assert_eq!(favorites(&grouped), favorites(&single));
}

#[test]
#[ignore]
fn one_failing_statement_retries_the_others_alone() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "ra");
    let (b, b_name) = new_user(&mut h, "rb");
    let (_, c_name) = new_user(&mut h, "rc");
    let slug = new_article(&mut h, a, &[]);
    let title = format!("Retry {}", unique("r"));
    let new_name = unique("rn");
    let resps = h.run(vec![
        create_article(a, &title, &["rt"]),
        update_user(b, None, Some(&c_name), None),
        favorite(b, &slug, true),
        add_comment(b, &slug, "survives"),
        register(&new_name, &format!("{new_name}@e.com")),
    ]);
    let statuses: Vec<u16> = resps.iter().map(|r| r.status).collect();
    assert_eq!(statuses, [201, 422, 200, 201, 201], "{resps:?}");
    assert_eq!(resps[1].error_message(), "username or email already taken");
    assert_eq!(
        count(&format!(
            "select count(*) from articles where title = '{title}'"
        )),
        1
    );
    assert_eq!(
        scalar(&format!("select username from users where id = {b}")),
        b_name
    );
    assert_eq!(
        count(&format!(
            "select count(*) from users where username = '{new_name}'"
        )),
        1
    );
    assert_eq!(resps[2].number(&["article", "favoritesCount"]), 1);
    let own = count(&format!(
        "select xmin::text from articles where title = '{title}'"
    ));
    let comment = count(&format!(
        "select xmin::text from comments where body = 'survives' and article_id in (select id from articles where slug = '{slug}')"
    ));
    assert_ne!(own, comment, "the retried jobs commit separately");
}

#[test]
#[ignore]
fn replies_are_posted_only_after_the_data_is_visible_to_other_connections() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "rw");
    let marker = unique("rw");
    let jobs = (0..20)
        .map(|i| create_article(a, &format!("Visible {marker} {i}"), &["v"]))
        .collect();
    let resps = h.run(jobs);
    assert!(resps.iter().all(|r| r.status == 201));
    assert_eq!(
        count(&format!(
            "select count(*) from articles where title like 'Visible {marker} %'"
        )),
        20
    );
    for r in &resps {
        let slug = r.text(&["article", "slug"]);
        assert_eq!(
            count(&format!(
                "select count(*) from articles where slug = '{slug}'"
            )),
            1
        );
    }
}

#[test]
#[ignore]
fn favorite_counts_equal_the_real_counts_for_a_group_and_for_concurrent_groups() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "ca");
    let slug = new_article(&mut h, a, &[]);
    let resps = h.run(
        (1..=60)
            .map(|viewer| favorite(viewer, &slug, true))
            .collect(),
    );
    let counts: Vec<i64> = resps
        .iter()
        .map(|r| r.number(&["article", "favoritesCount"]))
        .collect();
    assert_eq!(
        counts,
        (1..=60).collect::<Vec<_>>(),
        "each answer sees the favorites before it in the group"
    );
    let real = |slug: &str| {
        count(&format!(
            "select count(*) from favorites f join articles a on a.id = f.article_id where a.slug = '{slug}'"
        ))
    };
    assert_eq!(real(&slug), 60);

    for _ in 0..5 {
        let slug = new_article(&mut h, a, &[]);
        let workers: Vec<_> = [1..=30_i64, 31..=60]
            .into_iter()
            .map(|range| {
                let slug = slug.clone();
                std::thread::spawn(move || {
                    let mut lane = Harness::new();
                    lane.run(range.map(|viewer| favorite(viewer, &slug, true)).collect())
                })
            })
            .collect();
        for worker in workers {
            assert!(worker.join().unwrap().iter().all(|r| r.status == 200));
        }
        assert_eq!(real(&slug), 60, "two groups at once lose nothing");
    }
}

#[test]
#[ignore]
fn a_dropped_connection_answers_503_and_the_lane_recovers() {
    let proxy = CuttableProxy::start("127.0.0.1:5433");
    let database = test_url()
        .rsplit('/')
        .next()
        .unwrap_or("write_test")
        .to_owned();
    let mut h = Harness::with_url(&format!(
        "postgres://conduit:conduit@127.0.0.1:{}/{database}",
        proxy.port
    ));
    let (a, _) = new_user(&mut h, "dc");
    proxy.cut();
    let lost = format!("Lost {}", unique("l"));
    let resps = h.run(
        (0..3)
            .map(|i| create_article(a, &format!("{lost} {i}"), &[]))
            .collect(),
    );
    assert!(resps.iter().all(|r| r.status == 503), "{resps:?}");
    assert_eq!(
        count(&format!(
            "select count(*) from articles where title like '{lost} %'"
        )),
        0,
        "never retried"
    );
    let back = h.run_one(create_article(a, &format!("Back {lost}"), &[]));
    assert_eq!(back.status, 201, "{}", back.body);
    proxy.cut();
    let again = h.run_one(create_article(a, &format!("Lost again {lost}"), &[]));
    assert_eq!(again.status, 503);
    assert_eq!(
        h.run_one(create_article(a, &format!("Back again {lost}"), &[]))
            .status,
        201
    );
}

#[test]
#[ignore]
fn queue_and_lane_threads_work_end_to_end() {
    let config = test_config(&test_url());
    let queue = WriteQueue::new(Duration::from_millis(5), 16);
    let mailboxes = Mailboxes::new(1).unwrap();
    let handles = spawn_lanes(
        2,
        &config,
        Arc::clone(&queue),
        mailboxes.clone(),
        Arc::new(Jwt::new(b"test-secret")),
    );
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "qe");
    let marker = unique("qe");
    for i in 0..40 {
        let mut job = create_article(a, &format!("Queued {marker} {i}"), &["q"]);
        job.origin.conn.slot = i;
        queue.push(job);
    }
    let mut replies: Vec<Reply> = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    while replies.len() < 40 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(5));
        let mut arrived = Vec::new();
        mailboxes.get(0).take_all(&mut arrived);
        replies.append(&mut arrived);
    }
    assert_eq!(replies.len(), 40);
    assert!(
        replies
            .iter()
            .all(|r| r.bytes[r.start..].starts_with(b"HTTP/1.1 201"))
    );
    assert_eq!(
        count(&format!(
            "select count(*) from articles where title like 'Queued {marker} %'"
        )),
        40
    );
    queue.close();
    handles
        .into_iter()
        .for_each(|handle| handle.join().unwrap());
}
