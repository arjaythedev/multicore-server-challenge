//! Integration tests, one lane against a real Postgres: every kind of write, including the error answers.
//! `#[ignore]`d by default; run with `cargo test --lib write:: -- --ignored` (see `test_support` for the database).

use super::test_support::*;
use crate::app::jobs::WriteKind;
use crate::jwt::Jwt;

const TAKEN: &str = "username or email already taken";

#[test]
#[ignore]
fn register_returns_a_user_with_a_token_that_verifies() {
    let mut h = Harness::new();
    let name = unique("reg");
    let resp = h.run_one(register(&name, &format!("{name}@example.com")));
    assert_eq!(resp.status, 201, "{}", resp.body);
    assert_eq!(resp.text(&["user", "username"]), name);
    assert_eq!(resp.text(&["user", "email"]), format!("{name}@example.com"));
    assert!(
        resp.json()
            .get("user")
            .and_then(|u| u.get("bio"))
            .is_some_and(|b| b.is_null())
    );
    let token = resp.text(&["user", "token"]);
    let now = super::respond::unix_seconds();
    assert_eq!(
        Jwt::new(b"test-secret").verify(token.as_bytes(), now),
        Ok(user_id(&name) as u64)
    );
    assert_eq!(
        count(&format!(
            "select count(*) from users where username = '{name}'"
        )),
        1
    );
}

#[test]
#[ignore]
fn register_duplicates_are_422() {
    let mut h = Harness::new();
    let name = unique("dup");
    assert_eq!(
        h.run_one(register(&name, &format!("{name}@example.com")))
            .status,
        201
    );
    let same_name = h.run_one(register(&name, &format!("other{name}@example.com")));
    assert_eq!(
        (same_name.status, same_name.error_message().as_str()),
        (422, TAKEN)
    );
    let same_email = h.run_one(register(
        &format!("other{name}"),
        &format!("{name}@example.com"),
    ));
    assert_eq!(
        (same_email.status, same_email.error_message().as_str()),
        (422, TAKEN)
    );
    assert_eq!(
        count(&format!(
            "select count(*) from users where username like '%{name}'"
        )),
        1
    );
}

#[test]
#[ignore]
fn update_user_changes_fields_and_echoes_the_presented_token() {
    let mut h = Harness::new();
    let (id, name) = new_user(&mut h, "upd");
    let resp = h.run_one(update_user(
        id,
        Some(&format!("{name}@new.example")),
        None,
        Some("my bio"),
    ));
    assert_eq!(resp.status, 200, "{}", resp.body);
    assert_eq!(resp.text(&["user", "token"]), "presented.token.value");
    assert_eq!(resp.text(&["user", "bio"]), "my bio");
    assert_eq!(resp.text(&["user", "username"]), name);
    assert_eq!(
        scalar(&format!("select email from users where id = {id}")),
        format!("{name}@new.example")
    );
    let renamed = h.run_one(update_user(id, None, Some(&format!("{name}x")), None));
    assert_eq!(renamed.text(&["user", "username"]), format!("{name}x"));
    assert_eq!(
        renamed.text(&["user", "bio"]),
        "my bio",
        "absent fields stay as they were"
    );
}

#[test]
#[ignore]
fn update_user_stores_a_new_password_hash() {
    let mut h = Harness::new();
    let (id, _) = new_user(&mut h, "pw");
    let mut r = Req::new();
    let new_hash = [b'Z'; 60];
    let kind = WriteKind::UpdateUser {
        email: None,
        username: None,
        password_hash: Some(new_hash),
        bio: None,
        image: None,
        token: r.put("t"),
    };
    assert_eq!(h.run_one(r.job(id, kind)).status, 200);
    let stored = scalar(&format!("select password_hash from users where id = {id}"));
    assert_eq!(stored.as_bytes(), &new_hash);
}

#[test]
#[ignore]
fn update_user_conflicts_are_422_and_unknown_users_401() {
    let mut h = Harness::new();
    let (id, name) = new_user(&mut h, "uc");
    let (_, other) = new_user(&mut h, "uo");
    let by_name = h.run_one(update_user(id, None, Some(&other), None));
    assert_eq!(
        (by_name.status, by_name.error_message().as_str()),
        (422, TAKEN)
    );
    let by_email = h.run_one(update_user(
        id,
        Some(&format!("{other}@example.com")),
        None,
        None,
    ));
    assert_eq!(by_email.status, 422);
    assert_eq!(
        scalar(&format!("select username from users where id = {id}")),
        name,
        "nothing changed"
    );
    assert_eq!(
        h.run_one(update_user(9_000_000_000_000, None, None, Some("x")))
            .status,
        401
    );
}

#[test]
#[ignore]
fn follow_and_unfollow() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "fa");
    let (b, b_name) = new_user(&mut h, "fb");
    for _ in 0..2 {
        let resp = h.run_one(follow(a, &b_name, true));
        assert_eq!(resp.status, 200, "{}", resp.body);
        assert_eq!(resp.text(&["profile", "username"]), b_name);
        assert!(resp.flag(&["profile", "following"]));
    }
    assert_eq!(
        count(&format!(
            "select count(*) from follows where follower_id = {a} and followee_id = {b}"
        )),
        1
    );
    for _ in 0..2 {
        let resp = h.run_one(follow(a, &b_name, false));
        assert_eq!(resp.status, 200);
        assert!(!resp.flag(&["profile", "following"]));
    }
    assert_eq!(
        count(&format!(
            "select count(*) from follows where follower_id = {a}"
        )),
        0
    );
    assert_eq!(h.run_one(follow(a, "nobody-here-at-all", true)).status, 404);
    assert_eq!(
        h.run_one(follow(a, "nobody-here-at-all", false)).status,
        404
    );
}

#[test]
#[ignore]
fn create_article_with_and_without_tags() {
    let mut h = Harness::new();
    let (a, a_name) = new_user(&mut h, "ca");
    let tag = unique("tg");
    let resp = h.run_one(create_article(
        a,
        "Hello, Write Lane!",
        &[&format!("{tag}b"), &format!("{tag}a"), &format!("{tag}a")],
    ));
    assert_eq!(resp.status, 201, "{}", resp.body);
    let slug = resp.text(&["article", "slug"]);
    assert!(slug.starts_with("hello-write-lane-"), "{slug}");
    assert_eq!(
        slug,
        format!(
            "hello-write-lane-{}",
            scalar(&format!(
                "select id::text from articles where slug = '{slug}'"
            ))
        )
    );
    assert_eq!(resp.text(&["article", "body"]), "The body");
    assert_eq!(resp.number(&["article", "favoritesCount"]), 0);
    assert!(!resp.flag(&["article", "favorited"]));
    assert_eq!(resp.text(&["article", "author", "username"]), a_name);
    assert!(!resp.flag(&["article", "author", "following"]));
    let root = resp.json();
    let list = root
        .get("article")
        .and_then(|a| a.get("tagList"))
        .and_then(|t| t.as_array())
        .map(|items| {
            items
                .iter()
                .filter_map(|t| t.as_str().map(str::to_owned))
                .collect::<Vec<_>>()
        });
    assert_eq!(
        list,
        Some(vec![format!("{tag}a"), format!("{tag}b")]),
        "sorted, duplicates collapsed: {}",
        resp.body
    );
    assert_eq!(
        count(&format!(
            "select count(*) from article_tags at join tags t on t.id = at.tag_id where t.name like '{tag}%'"
        )),
        2
    );

    let plain = h.run_one(create_article(a, "No tags", &[]));
    assert_eq!(plain.status, 201, "{}", plain.body);
    assert_eq!(
        plain
            .json()
            .get("article")
            .and_then(|a| a.get("tagList"))
            .and_then(|t| t.as_array())
            .map(<[_]>::len),
        Some(0)
    );
}

#[test]
#[ignore]
fn update_article_by_the_author_and_the_error_cases() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "ua");
    let (b, _) = new_user(&mut h, "ub");
    let slug = new_article(&mut h, a, &["keep"]);
    let id = scalar(&format!(
        "select id::text from articles where slug = '{slug}'"
    ));

    let body_only = h.run_one(update_article(a, &slug, None, Some("new body")));
    assert_eq!(body_only.status, 200, "{}", body_only.body);
    assert_eq!(
        body_only.text(&["article", "slug"]),
        slug,
        "no title, no new slug"
    );
    assert_eq!(body_only.text(&["article", "body"]), "new body");

    let retitled = h.run_one(update_article(a, &slug, Some("A Brand New Title"), None));
    assert_eq!(retitled.status, 200);
    assert_eq!(
        retitled.text(&["article", "slug"]),
        format!("a-brand-new-title-{id}")
    );
    assert_eq!(retitled.text(&["article", "body"]), "new body");
    assert_eq!(
        count(&format!(
            "select count(*) from article_tags where article_id = {id}"
        )),
        1,
        "tags survive"
    );

    let new_slug = retitled.text(&["article", "slug"]);
    let hijack = h.run_one(update_article(b, &new_slug, None, Some("mine now")));
    assert_eq!(hijack.status, 403, "{}", hijack.body);
    assert_eq!(
        scalar(&format!("select body from articles where id = {id}")),
        "new body"
    );
    assert_eq!(
        h.run_one(update_article(a, "no-such-slug", None, Some("x")))
            .status,
        404
    );
}

#[test]
#[ignore]
fn delete_article_404_403_204() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "da");
    let (b, _) = new_user(&mut h, "db");
    let slug = new_article(&mut h, a, &[]);
    assert_eq!(h.run_one(delete_article(a, "no-such-slug")).status, 404);
    assert_eq!(h.run_one(delete_article(b, &slug)).status, 403);
    assert_eq!(
        count(&format!(
            "select count(*) from articles where slug = '{slug}'"
        )),
        1
    );
    let done = h.run_one(delete_article(a, &slug));
    assert_eq!((done.status, done.body.as_str()), (204, ""));
    assert_eq!(
        count(&format!(
            "select count(*) from articles where slug = '{slug}'"
        )),
        0
    );
    assert_eq!(h.run_one(delete_article(a, &slug)).status, 404);
}

#[test]
#[ignore]
fn favorite_counts_follow_the_real_rows() {
    let mut h = Harness::new();
    let (a, _) = new_user(&mut h, "ga");
    let (b, _) = new_user(&mut h, "gb");
    let (c, _) = new_user(&mut h, "gc");
    let slug = new_article(&mut h, a, &["t"]);
    let first = h.run_one(favorite(b, &slug, true));
    assert_eq!(first.status, 200, "{}", first.body);
    assert_eq!(
        (
            first.number(&["article", "favoritesCount"]),
            first.flag(&["article", "favorited"])
        ),
        (1, true)
    );
    let repeat = h.run_one(favorite(b, &slug, true));
    assert_eq!(
        repeat.number(&["article", "favoritesCount"]),
        1,
        "a repeat does not count twice"
    );
    let second = h.run_one(favorite(c, &slug, true));
    assert_eq!(second.number(&["article", "favoritesCount"]), 2);
    let undone = h.run_one(favorite(b, &slug, false));
    assert_eq!(
        (
            undone.number(&["article", "favoritesCount"]),
            undone.flag(&["article", "favorited"])
        ),
        (1, false)
    );
    let nothing = h.run_one(favorite(b, &slug, false));
    assert_eq!(
        (
            nothing.status,
            nothing.number(&["article", "favoritesCount"])
        ),
        (200, 1),
        "unfavorite without favorite"
    );
    assert_eq!(
        count(&format!(
            "select count(*) from favorites f join articles a on a.id = f.article_id where a.slug = '{slug}'"
        )),
        1
    );
    assert_eq!(h.run_one(favorite(b, "no-such-slug", true)).status, 404);
    assert_eq!(h.run_one(favorite(b, "no-such-slug", false)).status, 404);
}

#[test]
#[ignore]
fn follow_state_shows_in_favorite_answers() {
    let mut h = Harness::new();
    let (a, a_name) = new_user(&mut h, "ha");
    let (b, _) = new_user(&mut h, "hb");
    let slug = new_article(&mut h, a, &[]);
    assert!(
        !h.run_one(favorite(b, &slug, true))
            .flag(&["article", "author", "following"])
    );
    assert_eq!(h.run_one(follow(b, &a_name, true)).status, 200);
    assert!(
        h.run_one(favorite(b, &slug, true))
            .flag(&["article", "author", "following"])
    );
}

#[test]
#[ignore]
fn comments_add_delete_and_the_error_cases() {
    let mut h = Harness::new();
    let (a, a_name) = new_user(&mut h, "ma");
    let (b, _) = new_user(&mut h, "mb");
    let slug = new_article(&mut h, a, &[]);
    let other_slug = new_article(&mut h, a, &[]);
    let added = h.run_one(add_comment(b, &slug, "Nice \"post\" ä ö"));
    assert_eq!(added.status, 201, "{}", added.body);
    assert_eq!(added.text(&["comment", "body"]), "Nice \"post\" ä ö");
    assert!(!added.flag(&["comment", "author", "following"]));
    let id = added.number(&["comment", "id"]);
    assert_ne!(added.text(&["comment", "author", "username"]), a_name);
    assert_eq!(h.run_one(add_comment(b, "no-such-slug", "x")).status, 404);

    assert_eq!(
        h.run_one(delete_comment(a, &slug, id)).status,
        403,
        "someone else's comment"
    );
    assert_eq!(
        h.run_one(delete_comment(b, &other_slug, id)).status,
        404,
        "comment of another article"
    );
    assert_eq!(
        h.run_one(delete_comment(b, &slug, id + 1_000_000_000))
            .status,
        404
    );
    assert_eq!(
        count(&format!("select count(*) from comments where id = {id}")),
        1
    );
    let done = h.run_one(delete_comment(b, &slug, id));
    assert_eq!((done.status, done.body.as_str()), (204, ""));
    assert_eq!(
        count(&format!("select count(*) from comments where id = {id}")),
        0
    );
    assert_eq!(h.run_one(delete_comment(b, &slug, id)).status, 404);
}

#[test]
#[ignore]
fn a_job_the_lane_cannot_send_is_a_500_and_does_not_hurt_others() {
    let mut h = Harness::new();
    let name = unique("bad");
    let mut r = Req::new();
    let kind = WriteKind::Register {
        username: r.put(&name),
        email: r.put(&format!("{name}@e.com")),
        password_hash: [0xff; 60],
    };
    let bad = r.job(0, kind);
    let good = register(&unique("ok"), &format!("{}@e.com", unique("ok")));
    let resps = h.run(vec![bad, good]);
    assert_eq!(resps[0].status, 500);
    assert_eq!(resps[1].status, 201);
    assert_eq!(
        count(&format!(
            "select count(*) from users where username = '{name}'"
        )),
        0
    );
}

#[test]
#[ignore]
fn created_article_reads_by_primary_key_not_by_scanning() {
    let sql = include_str!("sql/created_article.sql").replace("$1", "1");
    let plan = plan_text(&sql);
    let filtered_by_currval = plan
        .lines()
        .any(|line| line.contains("Filter") && line.contains("currval"));
    assert!(
        !filtered_by_currval,
        "a volatile currval() in WHERE is re-evaluated for every index entry:\n{plan}"
    );
    assert!(plan.contains("Index Cond"), "{plan}");
}
