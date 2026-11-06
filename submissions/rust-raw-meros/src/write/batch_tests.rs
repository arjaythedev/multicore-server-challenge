//! Live tests of the array statements: a group that shares statements per kind must answer every job, and leave
//! the database, exactly as the same jobs run one by one. `#[ignore]`d like `live_tests`.
//!
//! Each scenario runs on two identical fixtures, once as ONE group and once job by job, and the answers (without
//! ids, slugs, timestamps and the run's own names) plus the stored favorites, follows and comments are compared.

use super::test_support::*;
use crate::app::jobs::WriteJob;

/// Four users (the first writes the articles), four articles, and some earlier favorites and follows.
struct Fix {
    sfx: String,
    users: Vec<(i64, String)>,
    slugs: Vec<String>,
}

fn fixture(h: &mut Harness) -> Fix {
    let users: Vec<(i64, String)> = (0..4).map(|_| new_user(h, "bt")).collect();
    let sfx = unique("x");
    let slugs: Vec<String> = (0..4)
        .map(|i| {
            let tags: &[&str] = if i % 2 == 0 { &["t1", "t2"] } else { &[] };
            let title = format!("Batch article {i} {sfx}");
            let resp = h.run_one(create_article(users[0].0, &title, tags));
            assert_eq!(resp.status, 201, "{}", resp.body);
            resp.text(&["article", "slug"])
        })
        .collect();
    let earlier = vec![
        favorite(users[2].0, &slugs[0], true),
        favorite(users[1].0, &slugs[1], true),
        favorite(users[3].0, &slugs[1], true),
        follow(users[3].0, &users[0].1, true),
        follow(users[2].0, &users[1].1, true),
    ];
    h.run_each(earlier);
    Fix { sfx, users, slugs }
}

fn state(f: &Fix) -> Vec<i64> {
    let mut out = Vec::new();
    for slug in &f.slugs {
        out.push(count(&format!(
            "select count(*) from favorites f join articles a on a.id = f.article_id where a.slug = '{slug}'"
        )));
        out.push(count(&format!(
            "select count(*) from comments c join articles a on a.id = c.article_id where a.slug = '{slug}'"
        )));
        for (user, _) in &f.users {
            out.push(count(&format!(
                "select count(*) from favorites f join articles a on a.id = f.article_id where a.slug = '{slug}' and f.user_id = {user}"
            )));
        }
    }
    for (a, _) in &f.users {
        for (b, _) in &f.users {
            out.push(count(&format!(
                "select count(*) from follows where follower_id = {a} and followee_id = {b}"
            )));
        }
    }
    out
}

fn signatures(resps: &[Resp], f: &Fix) -> Vec<String> {
    let mut subs: Vec<(&str, &str)> = f
        .users
        .iter()
        .zip(["U0", "U1", "U2", "U3"])
        .map(|(u, to)| (u.1.as_str(), to))
        .collect();
    subs.push((f.sfx.as_str(), "SFX"));
    resps.iter().map(|r| r.signature(&subs)).collect()
}

/// Runs the scenario as a group and one by one; returns the group's answers.
fn same_as_sequential(build: impl Fn(&Fix) -> Vec<WriteJob>) -> Vec<Resp> {
    let mut h = Harness::new();
    let (grouped, single) = (fixture(&mut h), fixture(&mut h));
    let jobs = build(&grouped);
    let count = jobs.len();
    let in_group = h.run(jobs);
    let one_by_one = h.run_each(build(&single));
    assert_eq!(in_group.len(), count);
    let (g, s) = (
        signatures(&in_group, &grouped),
        signatures(&one_by_one, &single),
    );
    for (i, (g, s)) in g.iter().zip(&s).enumerate() {
        assert_eq!(
            g, s,
            "job {i} differs: {:?} / {:?}",
            in_group[i], one_by_one[i]
        );
    }
    assert_eq!(state(&grouped), state(&single), "the stored rows differ");
    in_group
}

#[test]
#[ignore]
fn favorites_of_different_users_on_the_same_article() {
    let answers = same_as_sequential(|f| {
        let (u, s) = (&f.users, &f.slugs);
        vec![
            favorite(u[0].0, &s[0], true),
            favorite(u[1].0, &s[0], true),
            favorite(u[3].0, &s[0], true),
            favorite(u[2].0, &s[0], false),
            favorite(u[1].0, &s[1], true),
            favorite(u[3].0, &s[1], false),
            favorite(u[0].0, &s[1], false),
            favorite(u[2].0, &s[2], false),
            favorite(u[1].0, "no-such-article", true),
            favorite(u[2].0, &s[3], true),
        ]
    });
    assert_eq!(answers[0].number(&["article", "favoritesCount"]), 2);
    assert_eq!(answers[2].number(&["article", "favoritesCount"]), 4);
    assert_eq!(answers[3].number(&["article", "favoritesCount"]), 3);
    assert!(answers[0].flag(&["article", "favorited"]));
    assert!(!answers[3].flag(&["article", "favorited"]));
    assert_eq!(answers[8].status, 404);
}

#[test]
#[ignore]
fn one_user_touching_one_pair_twice_runs_sequentially() {
    same_as_sequential(|f| {
        let (u, s) = (&f.users, &f.slugs);
        vec![
            favorite(u[0].0, &s[0], true),
            favorite(u[0].0, &s[0], true),
            favorite(u[1].0, &s[0], true),
            favorite(u[1].0, &s[0], false),
            favorite(u[2].0, &s[0], false),
            favorite(u[2].0, &s[0], true),
            favorite(u[3].0, &s[2], true),
            favorite(u[3].0, &s[3], true),
        ]
    });
}

#[test]
#[ignore]
fn follow_then_unfollow_and_distinct_follows() {
    same_as_sequential(|f| {
        let u = &f.users;
        vec![
            follow(u[0].0, &u[1].1, true),
            follow(u[1].0, &u[2].1, true),
            follow(u[3].0, &u[0].1, false),
            follow(u[2].0, &u[1].1, true),
            follow(u[2].0, &u[3].1, true),
            follow(u[0].0, "nobody-like-this", true),
        ]
    });
    same_as_sequential(|f| {
        let u = &f.users;
        vec![
            follow(u[0].0, &u[1].1, true),
            follow(u[0].0, &u[1].1, false),
            follow(u[1].0, &u[2].1, true),
        ]
    });
}

#[test]
#[ignore]
fn comments_get_rising_ids_in_job_order() {
    let answers = same_as_sequential(|f| {
        let (u, s) = (&f.users, &f.slugs);
        vec![
            add_comment(u[1].0, &s[0], "first"),
            add_comment(u[2].0, &s[1], "second"),
            add_comment(u[1].0, "no-such-article", "lost"),
            add_comment(u[1].0, &s[0], "third"),
            add_comment(u[3].0, &s[0], "fourth with \"quotes\" and åäö"),
        ]
    });
    let ids: Vec<i64> = [0, 1, 3, 4]
        .iter()
        .map(|&i| answers[i].number(&["comment", "id"]))
        .collect();
    assert!(ids.windows(2).all(|w| w[0] < w[1]), "{ids:?}");
    assert_eq!(answers[2].status, 404);
    assert_eq!(
        answers[4].text(&["comment", "body"]),
        "fourth with \"quotes\" and åäö"
    );
}

#[test]
#[ignore]
fn a_follow_before_a_favorite_of_the_same_viewer_shows_in_its_following_flag() {
    let answers = same_as_sequential(|f| {
        let (u, s) = (&f.users, &f.slugs);
        vec![
            follow(u[1].0, &u[0].1, true),
            favorite(u[1].0, &s[0], true),
            favorite(u[2].0, &s[0], true),
            follow(u[1].0, &u[0].1, false),
            favorite(u[1].0, &s[2], true),
        ]
    });
    assert!(answers[1].flag(&["article", "author", "following"]));
    assert!(!answers[4].flag(&["article", "author", "following"]));
}

#[test]
#[ignore]
fn barriers_keep_their_place_between_runs() {
    let answers = same_as_sequential(|f| {
        let (u, s) = (&f.users, &f.slugs);
        vec![
            favorite(u[1].0, &s[3], true),
            favorite(u[2].0, &s[3], true),
            update_article(u[0].0, &s[3], Some("A brand new title"), None),
            favorite(u[1].0, &s[3], false),
            favorite(u[3].0, &s[3], true),
            add_comment(u[1].0, &s[3], "after the rename"),
            add_comment(u[2].0, &s[3], "also after"),
            delete_article(u[0].0, &s[2]),
            favorite(u[1].0, &s[2], true),
            favorite(u[2].0, &s[2], true),
        ]
    });
    assert_eq!(
        answers[3].status, 404,
        "the old slug is gone after the rename"
    );
    assert_eq!(
        answers[8].status, 404,
        "the article is deleted before these"
    );
}

#[test]
#[ignore]
fn a_big_mixed_group_equals_one_by_one() {
    let answers = same_as_sequential(|f| {
        let (u, s) = (&f.users, &f.slugs);
        let mut jobs = Vec::new();
        for i in 0..40usize {
            let viewer = &u[i % 4];
            let slug = &s[(i / 4) % 4];
            jobs.push(favorite(viewer.0, slug, i % 3 != 0));
            jobs.push(add_comment(viewer.0, slug, &format!("comment {i}")));
        }
        jobs
    });
    assert!(answers.iter().any(|r| r.status == 201));
}
