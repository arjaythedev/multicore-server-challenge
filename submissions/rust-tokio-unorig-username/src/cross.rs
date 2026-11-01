//! Every read kind waiting together (except the two user lookups) runs as ONE statement.
//!
//! Each kind gets its own five parameter arrays (ordinal, viewer, n1, n2, s). The statement resolves every
//! list page and article page to article ids, reads each distinct article's viewer-independent data (tags,
//! favorite count, author) once for the whole statement, whichever endpoints asked for it, and each distinct
//! article's comment thread once. Per request it returns its page of ids and the viewer's favorited / followed
//! ids among them (one primary-key range scan per request instead of a probe per row). Responses are built
//! here from those rows. Rows are tagged by type (column 0) and request ordinal (column 1).

use std::collections::HashMap;
use std::time::SystemTime;

use tokio_postgres::Row;
use tokio_postgres::types::Type;

use crate::db::*;
use crate::json;

const T_ART: i32 = 1; // per distinct article
const T_PAGE: i32 = 2; // per list / article request: i, ids, favorited ids, followed author ids
const T_COUNT: i32 = 3; // per list request: i, n
const T_COMMENT: i32 = 4; // per comment of each distinct article
const T_COMMENTS: i32 = 5; // per comments request: i, article id, followed comment author ids
const T_PROFILE: i32 = 6;
const T_TAGS: i32 = 7;
const T_TAG_NAME: i32 = 8; // per tag the listed articles carry: id, name (title), rank by name (n)

const COLS: [(&str, &str); 20] = [
    ("t", "int4"),
    ("i", "int8"),
    ("id", "int8"),
    ("slug", "text"),
    ("title", "text"),
    ("description", "text"),
    ("body", "text"),
    ("created", "timestamptz"),
    ("updated", "timestamptz"),
    ("tags", "text[]"),
    ("n", "int8"),
    ("username", "text"),
    ("bio", "text"),
    ("image", "text"),
    ("aid", "int8"),
    ("ids", "int8[]"),
    ("fa", "int8[]"),
    ("fo", "int8[]"),
    ("b", "bool"),
    ("tagids", "int4[]"),
];
const C_I: usize = 1;
const C_ID: usize = 2;
const C_SLUG: usize = 3;
const C_TITLE: usize = 4;
const C_DESC: usize = 5;
const C_BODY: usize = 6;
const C_CREATED: usize = 7;
const C_UPDATED: usize = 8;
const C_TAGS: usize = 9;
const C_N: usize = 10;
const C_USERNAME: usize = 11;
const C_BIO: usize = 12;
const C_IMAGE: usize = 13;
const C_AID: usize = 14;
const C_IDS: usize = 15;
const C_FA: usize = 16;
const C_FO: usize = 17;
const C_B: usize = 18;
const C_TAG_IDS: usize = 19;

/// Kinds this statement serves.
pub fn is_cross(kind: usize) -> bool {
    kind != USER_ID && kind != USER_EMAIL
}

pub const N_KINDS: usize = 12;

pub fn param_types() -> Vec<Type> {
    (0..N_KINDS).flat_map(|_| [Type::INT8_ARRAY, Type::INT8_ARRAY, Type::INT8_ARRAY, Type::INT8_ARRAY, Type::TEXT_ARRAY]).collect()
}

/// One branch's SELECT list: every output column, NULL unless given.
fn sel(t: i32, cols: &[(&str, &str)]) -> String {
    let mut s = format!("SELECT {t}");
    for (name, ty) in &COLS[1..] {
        s.push_str(", ");
        match cols.iter().find(|c| c.0 == *name) {
            Some((_, e)) => s.push_str(e),
            None => s.push_str(&format!("NULL::{ty}")),
        }
    }
    s
}

/// Kind k's request arrays.
fn rk(k: usize) -> String {
    let p = |n: usize| 5 * k + n;
    format!(
        "unnest(${}::int8[], ${}::int8[], ${}::int8[], ${}::int8[], ${}::text[]) r(i, v, n1, n2, s)",
        p(1),
        p(2),
        p(3),
        p(4),
        p(5)
    )
}

pub fn sql() -> String {
    let by_username = "(SELECT u.id FROM users u WHERE u.username = r.s)";
    let by_tag = "(SELECT t.id FROM tags t WHERE t.name = r.s)";
    let page = |k: usize, ids: &str| {
        format!("SELECT r.i, r.v, x.id, false AS isfull, {} AS fe FROM {} CROSS JOIN LATERAL ({ids}) x", k == FEED, rk(k))
    };
    let count = |k: usize, src: &str| {
        format!("{} FROM {}", sel(T_COUNT, &[("i", "r.i"), ("n", &format!("(SELECT count(*) FROM ({src} LIMIT 1000) s)"))]), rk(k))
    };
    let flag = |v: &str, a: &str| format!("({v} <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = {v} AND fo.followee_id = {a}))");
    [
        "WITH pa AS MATERIALIZED (".to_owned(),
        page(LIST_ALL, "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.n1 OFFSET r.n2"),
        format!(" UNION ALL {}", page(LIST_TAG, &format!("SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = {by_tag} ORDER BY at.article_id DESC LIMIT r.n1 OFFSET r.n2"))),
        format!(" UNION ALL {}", page(LIST_AUTHOR, &format!("SELECT a.id FROM articles a WHERE a.author_id = {by_username} ORDER BY a.id DESC LIMIT r.n1 OFFSET r.n2"))),
        format!(" UNION ALL {}", page(LIST_FAV, &format!("SELECT f.article_id AS id FROM favorites f WHERE f.user_id = {by_username} ORDER BY f.article_id DESC LIMIT r.n1 OFFSET r.n2"))),
        format!(
            " UNION ALL {}",
            page(
                FEED,
                "SELECT x.id FROM follows fo CROSS JOIN LATERAL (
       SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.n1 + r.n2) x
     WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.n1 OFFSET r.n2"
            )
        ),
        format!(" UNION ALL SELECT r.i, r.v, a.id, true, false FROM {} JOIN articles a ON a.slug = r.s", rk(ARTICLE_SLUG)),
        format!(" UNION ALL SELECT r.i, r.v, a.id, true, false FROM {} JOIN articles a ON a.id = r.n1", rk(ARTICLE_ID)),
        "),
e AS MATERIALIZED (SELECT a.id, a.author_id, a.slug, a.title, a.description,
    CASE WHEN a.id = ANY(ARRAY(SELECT id FROM pa WHERE isfull)) THEN a.body END AS body, a.created_at, a.updated_at,
    ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id) AS tags,
    (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, u.username, u.bio, u.image
  FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = ANY(ARRAY(SELECT DISTINCT id FROM pa))),
q AS MATERIALIZED (SELECT pa.i, pa.v, pa.fe, array_agg(pa.id ORDER BY pa.id DESC) AS ids, array_agg(DISTINCT e.author_id) AS au
  FROM pa JOIN e ON e.id = pa.id GROUP BY pa.i, pa.v, pa.fe),"
            .to_owned(),
        format!("ca AS MATERIALIZED (SELECT a.id, a.slug FROM articles a WHERE a.slug = ANY(ARRAY(SELECT DISTINCT r.s FROM {}))),", rk(COMMENTS)),
        "cc AS MATERIALIZED (SELECT ca.id AS aid, c.* FROM ca CROSS JOIN LATERAL (
    SELECT c.id, c.created_at, c.updated_at, c.body, c.author_id FROM comments c
     WHERE c.article_id = ca.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c),
cau AS MATERIALIZED (SELECT aid, array_agg(DISTINCT author_id) AS au FROM cc GROUP BY aid)
"
        .to_owned(),
        sel(
            T_ART,
            &[
                ("id", "e.id"),
                ("slug", "e.slug"),
                ("title", "e.title"),
                ("description", "e.description"),
                ("body", "e.body"),
                ("created", "e.created_at"),
                ("updated", "e.updated_at"),
                ("tagids", "e.tags"),
                ("n", "e.fc"),
                ("username", "e.username"),
                ("bio", "e.bio"),
                ("image", "e.image"),
                ("aid", "e.author_id"),
            ],
        ) + " FROM e",
        format!(
            "\nUNION ALL {} FROM q",
            sel(
                T_PAGE,
                &[
                    ("i", "q.i"),
                    ("ids", "q.ids"),
                    ("fa", "CASE WHEN q.v <> 0 THEN ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = q.v AND f.article_id = ANY(q.ids)) END"),
                    ("fo", "CASE WHEN q.v <> 0 AND NOT q.fe THEN ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.au)) END"),
                ],
            )
        ),
        // The global count depends on no request: once per statement, walking the primary key from the oldest
        // (frozen, all-visible) end, which is the same min(count, 1000).
        format!(
            "\nUNION ALL {} FROM {}",
            sel(T_COUNT, &[("i", "r.i"), ("n", "(SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s)")]),
            rk(LIST_ALL)
        ),
        format!("\nUNION ALL {}", count(LIST_TAG, &format!("SELECT 1 FROM article_tags at WHERE at.tag_id = {by_tag}"))),
        format!("\nUNION ALL {}", count(LIST_AUTHOR, &format!("SELECT 1 FROM articles a WHERE a.author_id = {by_username}"))),
        format!("\nUNION ALL {}", count(LIST_FAV, &format!("SELECT 1 FROM favorites f WHERE f.user_id = {by_username}"))),
        format!(
            "\nUNION ALL {}",
            count(FEED, "SELECT 1 FROM articles a WHERE a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v))")
        ),
        format!(
            "\nUNION ALL {} FROM cc JOIN users u ON u.id = cc.author_id",
            sel(
                T_COMMENT,
                &[
                    ("id", "cc.aid"),
                    ("n", "cc.id"),
                    ("created", "cc.created_at"),
                    ("updated", "cc.updated_at"),
                    ("body", "cc.body"),
                    ("username", "u.username"),
                    ("bio", "u.bio"),
                    ("image", "u.image"),
                    ("aid", "cc.author_id"),
                ],
            )
        ),
        format!(
            "\nUNION ALL {} FROM {} JOIN ca ON ca.slug = r.s LEFT JOIN cau ON cau.aid = ca.id",
            sel(
                T_COMMENTS,
                &[
                    ("i", "r.i"),
                    ("id", "ca.id"),
                    ("fo", "CASE WHEN r.v <> 0 THEN ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = ANY(cau.au)) END"),
                ],
            ),
            rk(COMMENTS)
        ),
        format!(
            "\nUNION ALL {} FROM {} JOIN users u ON u.username = r.s",
            sel(T_PROFILE, &[("i", "r.i"), ("username", "u.username"), ("bio", "u.bio"), ("image", "u.image"), ("b", &flag("r.v", "u.id"))]),
            rk(PROFILE)
        ),
        format!(
            "\nUNION ALL {} FROM tags t WHERE t.id = ANY(ARRAY(SELECT DISTINCT unnest(e.tags) FROM e))",
            sel(T_TAG_NAME, &[("id", "t.id::int8"), ("title", "t.name"), ("n", "row_number() OVER (ORDER BY t.name)")])
        ),
        format!(
            "\nUNION ALL {} WHERE cardinality(${}::int8[]) > 0",
            sel(T_TAGS, &[("tags", "(SELECT coalesce(array_agg(t.name ORDER BY t.name), '{}') FROM tags t)")]),
            5 * TAGS + 1
        ),
    ]
    .concat()
}

/// The statement's parameters for `qs` (kind, request), ordinals being positions in `qs`.
pub fn params(qs: &[(usize, &Q)]) -> (Vec<Vec<i64>>, Vec<Vec<String>>) {
    let mut n: Vec<Vec<i64>> = vec![Vec::new(); 4 * N_KINDS];
    let mut s: Vec<Vec<String>> = vec![Vec::new(); N_KINDS];
    for (i, (k, q)) in qs.iter().enumerate() {
        n[4 * k].push(i as i64);
        n[4 * k + 1].push(q.v);
        n[4 * k + 2].push(q.n1);
        n[4 * k + 3].push(q.n2);
        s[*k].push(q.s.clone());
    }
    (n, s)
}

fn has(ids: &Option<Vec<i64>>, id: i64) -> bool {
    ids.as_ref().is_some_and(|v| v.contains(&id))
}

fn article(o: &mut Vec<u8>, e: &Row, tags: &HashMap<i32, (&str, i64)>, favorited: bool, following: bool, body: bool) {
    o.extend_from_slice(b"{\"slug\":");
    json::str(o, e.get(C_SLUG));
    o.extend_from_slice(b",\"title\":");
    json::str(o, e.get(C_TITLE));
    o.extend_from_slice(b",\"description\":");
    json::str(o, e.get(C_DESC));
    if body {
        o.extend_from_slice(b",\"body\":");
        json::str(o, e.get(C_BODY));
    }
    o.extend_from_slice(b",\"tagList\":[");
    // tag names in the database's name order
    let mut ids: Vec<i32> = e.get(C_TAG_IDS);
    ids.sort_unstable_by_key(|id| tags[id].1);
    for (i, id) in ids.iter().enumerate() {
        if i > 0 {
            o.push(b',');
        }
        json::str(o, tags[id].0);
    }
    o.extend_from_slice(b"],\"createdAt\":");
    json::time(o, e.get(C_CREATED));
    o.extend_from_slice(b",\"updatedAt\":");
    json::time(o, e.get(C_UPDATED));
    o.extend_from_slice(b",\"favorited\":");
    json::bool(o, favorited);
    o.extend_from_slice(b",\"favoritesCount\":");
    json::int(o, e.get(C_N));
    o.extend_from_slice(b",\"author\":");
    json::profile(o, e.get(C_USERNAME), e.get(C_BIO), e.get(C_IMAGE), following);
    o.push(b'}');
}

/// Builds every request's response body from the statement's rows. An empty body means "not found"
/// (article, comments, profile); lists always answer.
pub fn assemble(kinds: &[usize], rows: &[Row]) -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = vec![Vec::new(); kinds.len()];
    let mut counts = vec![0i64; kinds.len()];
    let mut arts: HashMap<i64, &Row> = HashMap::new();
    let mut comments: HashMap<i64, Vec<&Row>> = HashMap::new();
    let mut pages: Vec<Option<&Row>> = vec![None; kinds.len()];
    let mut threads = Vec::new();
    let mut tags: HashMap<i32, (&str, i64)> = HashMap::new();
    for r in rows {
        let t: i32 = r.get(0);
        match t {
            T_ART => {
                arts.insert(r.get(C_ID), r);
            }
            T_COMMENT => comments.entry(r.get(C_ID)).or_default().push(r),
            T_PAGE => pages[r.get::<_, i64>(C_I) as usize] = Some(r),
            T_COUNT => counts[r.get::<_, i64>(C_I) as usize] = r.get(C_N),
            T_COMMENTS => threads.push(r),
            T_TAG_NAME => {
                tags.insert(r.get::<_, i64>(C_ID) as i32, (r.get(C_TITLE), r.get(C_N)));
            }
            T_PROFILE => {
                let o = &mut out[r.get::<_, i64>(C_I) as usize];
                o.extend_from_slice(b"{\"profile\":");
                json::profile(o, r.get(C_USERNAME), r.get(C_BIO), r.get(C_IMAGE), r.get(C_B));
                o.push(b'}');
            }
            T_TAGS => {
                let mut b = Vec::with_capacity(4096);
                b.extend_from_slice(b"{\"tags\":[");
                for (i, t) in r.get::<_, Vec<&str>>(C_TAGS).into_iter().enumerate() {
                    if i > 0 {
                        b.push(b',');
                    }
                    json::str(&mut b, t);
                }
                b.extend_from_slice(b"]}");
                for (i, k) in kinds.iter().enumerate() {
                    if *k == TAGS {
                        out[i] = b.clone();
                    }
                }
            }
            _ => {}
        }
    }
    for (i, &k) in kinds.iter().enumerate() {
        let is_list = matches!(k, LIST_ALL | LIST_TAG | LIST_AUTHOR | LIST_FAV | FEED);
        if !is_list && k != ARTICLE_SLUG && k != ARTICLE_ID {
            continue;
        }
        let o = &mut out[i];
        if is_list {
            o.extend_from_slice(b"{\"articles\":[");
        }
        if let Some(p) = pages[i] {
            let (fa, fo): (Option<Vec<i64>>, Option<Vec<i64>>) = (p.get(C_FA), p.get(C_FO));
            for (n, id) in p.get::<_, Vec<i64>>(C_IDS).into_iter().enumerate() {
                let e = arts[&id];
                let following = k == FEED || has(&fo, e.get(C_AID));
                if is_list {
                    if n > 0 {
                        o.push(b',');
                    }
                    article(o, e, &tags, has(&fa, id), following, false);
                } else {
                    o.extend_from_slice(b"{\"article\":");
                    article(o, e, &tags, has(&fa, id), following, true);
                    o.push(b'}');
                }
            }
        }
        if is_list {
            o.extend_from_slice(b"],\"articlesCount\":");
            json::int(o, counts[i]);
            o.push(b'}');
        }
    }
    for cs in comments.values_mut() {
        cs.sort_unstable_by_key(|r| std::cmp::Reverse((r.get::<_, SystemTime>(C_CREATED), r.get::<_, i64>(C_N))));
    }
    for t in threads {
        let i = t.get::<_, i64>(C_I) as usize;
        let fo: Option<Vec<i64>> = t.get(C_FO);
        let o = &mut out[i];
        o.extend_from_slice(b"{\"comments\":[");
        for (n, c) in comments.get(&t.get::<_, i64>(C_ID)).into_iter().flatten().enumerate() {
            if n > 0 {
                o.push(b',');
            }
            o.extend_from_slice(b"{\"id\":");
            json::int(o, c.get(C_N));
            o.extend_from_slice(b",\"createdAt\":");
            json::time(o, c.get(C_CREATED));
            o.extend_from_slice(b",\"updatedAt\":");
            json::time(o, c.get(C_UPDATED));
            o.extend_from_slice(b",\"body\":");
            json::str(o, c.get(C_BODY));
            o.extend_from_slice(b",\"author\":");
            json::profile(o, c.get(C_USERNAME), c.get(C_BIO), c.get(C_IMAGE), has(&fo, c.get(C_AID)));
            o.push(b'}');
        }
        o.extend_from_slice(b"]}");
    }
    out
}
