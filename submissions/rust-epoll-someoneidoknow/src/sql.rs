use crate::pg::{INT8, INT8_ARRAY, TEXT, TEXT_ARRAY};

pub const TAGS: usize = 0;
pub const LIST_GLOBAL: usize = 1;
pub const LIST_TAG: usize = 2;
pub const LIST_AUTHOR: usize = 3;
pub const LIST_FAVORITED: usize = 4;
pub const LIST_FEED: usize = 5;
pub const ARTICLE_BY_SLUG: usize = 6;
pub const COMMENTS: usize = 7;
pub const PROFILE: usize = 8;
pub const USER_BY_ID: usize = 9;
pub const USER_BY_EMAIL: usize = 10;
pub const USER_INSERT: usize = 11;
pub const USER_UPDATE: usize = 12;
pub const FOLLOW: usize = 13;
pub const UNFOLLOW: usize = 14;
pub const FAVORITE: usize = 15;
pub const UNFAVORITE: usize = 16;
pub const COMMENT_INSERT: usize = 17;
pub const COMMENT_DELETE: usize = 18;
pub const ARTICLE_INSERT: usize = 19;
pub const TAGS_INSERT: usize = 20;
pub const ARTICLE_TAGS_INSERT: usize = 21;
pub const ARTICLE_BY_CURRVAL: usize = 22;
pub const ARTICLE_UPDATE: usize = 23;
pub const ARTICLE_DELETE: usize = 24;
pub const SINGLE_COUNT: usize = 25;

pub const BATCHABLE: [usize; 10] = [
    TAGS,
    LIST_GLOBAL,
    LIST_TAG,
    LIST_AUTHOR,
    LIST_FAVORITED,
    LIST_FEED,
    ARTICLE_BY_SLUG,
    COMMENTS,
    PROFILE,
    USER_BY_ID,
];

pub fn batched(single: usize) -> Option<usize> {
    BATCHABLE
        .iter()
        .position(|&s| s == single)
        .map(|i| SINGLE_COUNT + i)
}

pub fn statements(app_sort: bool) -> Vec<(String, Vec<u32>)> {
    let order = if app_sort { "" } else { " ORDER BY 1" };
    let tags = |id: &str| {
        format!(
            "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) \
             FROM article_tags at WHERE at.article_id = {id}{order})"
        )
    };
    let enrich = |a: &str, author: &str, following: &str| {
        format!(
            "{tags}, (SELECT count(*) FROM favorites f WHERE f.article_id = {a}.id), \
             EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = $1 AND f.article_id = {a}.id), \
             u.username, u.bio, u.image, {following}",
            tags = tags(&format!("{a}.id")),
            following = if following.is_empty() {
                format!(
                    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 \
                     AND fo.followee_id = {author})"
                )
            } else {
                following.to_string()
            },
        )
    };
    let capped = |inner: &str| format!("(SELECT count(*) AS n FROM ({inner} LIMIT 1000) s)");
    let probed = |from: &str| {
        format!(
            "(SELECT CASE WHEN EXISTS (SELECT 1 FROM {from} OFFSET 999) THEN 1000 \
             ELSE (SELECT count(*) FROM {from}) END AS n)"
        )
    };
    let list = |count: &str, ids: &str, following: &str| {
        format!(
            "SELECT c.n, p.* FROM {count} c \
             LEFT JOIN LATERAL (SELECT a.id, a.slug, a.title, a.description, a.created_at, \
             a.updated_at, {enrich} FROM ({ids}) ids JOIN articles a ON a.id = ids.id \
             JOIN users u ON u.id = a.author_id) p ON true ORDER BY p.id DESC",
            enrich = enrich("a", "a.author_id", following),
        )
    };
    let paged = |inner: &str| format!("SELECT id FROM ({inner} OFFSET $3 LIMIT 100) x LIMIT $2");
    let full = |filter: &str| {
        format!(
            "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, \
             {enrich} FROM articles a JOIN users u ON u.id = a.author_id WHERE {filter}",
            enrich = enrich("a", "a.author_id", ""),
        )
    };
    let list_params = vec![INT8, INT8, INT8, TEXT];
    let tag_id = "(SELECT t.id FROM tags t WHERE t.name = $4)";
    let user_id = "(SELECT u2.id FROM users u2 WHERE u2.username = $4)";
    let currval = "currval(pg_get_serial_sequence('articles', 'id'))";
    let mut s: Vec<(String, Vec<u32>)> = Vec::new();

    let tag_order = if app_sort { "" } else { " ORDER BY name" };
    s.push((
        format!("SELECT ARRAY(SELECT name FROM tags{tag_order})"),
        vec![INT8],
    ));
    let lists = [
        (
            probed("articles"),
            paged("SELECT id FROM articles ORDER BY id DESC"),
            false,
        ),
        (
            probed(&format!("article_tags at2 WHERE at2.tag_id = {tag_id}")),
            paged(&format!(
                "SELECT at2.article_id AS id FROM article_tags at2 WHERE at2.tag_id = {tag_id} \
                 ORDER BY at2.article_id DESC"
            )),
            false,
        ),
        (
            capped(&format!(
                "SELECT 1 FROM articles a2 WHERE a2.author_id = {user_id}"
            )),
            paged(&format!(
                "SELECT a2.id FROM articles a2 WHERE a2.author_id = {user_id} ORDER BY a2.id DESC"
            )),
            false,
        ),
        (
            capped(&format!(
                "SELECT 1 FROM favorites f2 WHERE f2.user_id = {user_id}"
            )),
            paged(&format!(
                "SELECT f2.article_id AS id FROM favorites f2 WHERE f2.user_id = {user_id} \
                 ORDER BY f2.article_id DESC"
            )),
            false,
        ),
        (
            capped(
                "SELECT 1 FROM articles a2 WHERE a2.author_id IN \
                 (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)",
            ),
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 \
             WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2 + $3)) x \
             WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3"
                .to_string(),
            true,
        ),
    ];
    for (count, ids, feed) in &lists {
        let following = if *feed { "true" } else { "" };
        s.push((list(count, ids, following), list_params.clone()));
    }
    s.push((full("a.slug = $2"), vec![INT8, TEXT]));
    s.push((
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 \
         AND fo.followee_id = c.author_id) \
         FROM articles a LEFT JOIN LATERAL (SELECT c2.id, c2.body, c2.created_at, c2.updated_at, \
         c2.author_id FROM comments c2 WHERE c2.article_id = a.id \
         ORDER BY c2.created_at DESC, c2.id DESC LIMIT 100) c ON true \
         LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = $2 \
         ORDER BY c.created_at DESC, c.id DESC"
            .into(),
        vec![INT8, TEXT],
    ));
    s.push((
        "SELECT u.username, u.bio, u.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) \
         FROM users u WHERE u.username = $2"
            .into(),
        vec![INT8, TEXT],
    ));
    s.push((
        "SELECT id, username, email, bio, image FROM users WHERE id = $1".into(),
        vec![INT8],
    ));
    s.push((
        "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1".into(),
        vec![TEXT],
    ));
    s.push((
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) \
         RETURNING id, username, email, bio, image"
            .into(),
        vec![TEXT, TEXT, TEXT],
    ));
    s.push((
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
         password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), \
         image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image"
            .into(),
        vec![INT8, TEXT, TEXT, TEXT, TEXT, TEXT],
    ));
    s.push((
        "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
         i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u \
         ON CONFLICT DO NOTHING) SELECT username, bio, image FROM u"
            .into(),
        vec![INT8, TEXT],
    ));
    s.push((
        "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
         d AS (DELETE FROM follows fo USING u WHERE fo.follower_id = $1 AND fo.followee_id = u.id) \
         SELECT username, bio, image FROM u"
            .into(),
        vec![INT8, TEXT],
    ));
    s.push((
        "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a \
         WHERE a.slug = $2 ON CONFLICT DO NOTHING"
            .into(),
        vec![INT8, TEXT],
    ));
    s.push((
        "DELETE FROM favorites f USING articles a WHERE a.slug = $2 AND f.article_id = a.id \
         AND f.user_id = $1"
            .into(),
        vec![INT8, TEXT],
    ));
    s.push((
        "WITH a AS (SELECT id FROM articles WHERE slug = $2), \
         c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $3 FROM a \
         RETURNING id, body, created_at, updated_at, author_id) \
         SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
         FROM c JOIN users u ON u.id = c.author_id"
            .into(),
        vec![INT8, TEXT, TEXT],
    ));
    s.push((
        "WITH c AS (SELECT c.id, c.author_id FROM comments c \
         JOIN articles a ON a.id = c.article_id \
         WHERE c.id = $2 AND a.slug = $3), \
         d AS (DELETE FROM comments x USING c WHERE x.id = c.id AND c.author_id = $1) \
         SELECT author_id FROM c"
            .into(),
        vec![INT8, INT8, TEXT],
    ));
    s.push((
        "INSERT INTO articles (id, slug, author_id, title, description, body) \
         SELECT n.id, $5 || '-' || n.id, $1, $2, $3, $4 \
         FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n"
            .into(),
        vec![INT8, TEXT, TEXT, TEXT, TEXT],
    ));
    s.push((
        "INSERT INTO tags (name) SELECT DISTINCT n FROM unnest($1::text[]) n \
         WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = n) ORDER BY n \
         ON CONFLICT (name) DO NOTHING"
            .into(),
        vec![TEXT_ARRAY],
    ));
    s.push((
        format!(
            "INSERT INTO article_tags (article_id, tag_id) SELECT {currval}, t.id FROM tags t \
             WHERE t.name = ANY($1)"
        ),
        vec![TEXT_ARRAY],
    ));
    s.push((full(&format!("a.id = (SELECT {currval})")), vec![INT8]));
    s.push((
        format!(
            "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2), \
             upd AS (UPDATE articles a SET title = COALESCE($3, a.title), \
             description = COALESCE($4, a.description), body = COALESCE($5, a.body), \
             slug = CASE WHEN $3::text IS NULL THEN a.slug ELSE $6 || '-' || a.id END, \
             updated_at = now() FROM a0 WHERE a.id = a0.id AND a0.author_id = $1 \
             RETURNING a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, \
             a.author_id) \
             SELECT a0.author_id, upd.id, upd.slug, upd.title, upd.description, upd.body, \
             upd.created_at, upd.updated_at, {enrich} \
             FROM a0 LEFT JOIN upd ON true LEFT JOIN users u ON u.id = upd.author_id",
            enrich = enrich("upd", "upd.author_id", ""),
        ),
        vec![INT8, TEXT, TEXT, TEXT, TEXT, TEXT],
    ));
    s.push((
        "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2), \
         d AS (DELETE FROM articles a USING a0 WHERE a.id = a0.id AND a0.author_id = $1) \
         SELECT author_id FROM a0"
            .into(),
        vec![INT8, TEXT],
    ));
    assert_eq!(s.len(), SINGLE_COUNT);
    for single in BATCHABLE {
        let b = match single {
            TAGS => (
                format!(
                    "SELECT r.i, t.names FROM unnest($1::int8[]) WITH ORDINALITY AS r(v, i) \
                     CROSS JOIN (SELECT ARRAY(SELECT name FROM tags{tag_order}) AS names) t"
                ),
                vec![INT8_ARRAY],
            ),
            LIST_GLOBAL..=LIST_FEED => {
                let (count, ids, feed) = &lists[single - LIST_GLOBAL];
                (
                    list_batch(count, ids, *feed, &tags("a.id")),
                    vec![INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, TEXT_ARRAY],
                )
            }
            ARTICLE_BY_SLUG => (article_batch(&tags("a.id")), vec![INT8_ARRAY, TEXT_ARRAY]),
            COMMENTS => (comments_batch(), vec![INT8_ARRAY, TEXT_ARRAY]),
            _ => batch_form(&s[single].0, &s[single].1),
        };
        s.push(b);
    }
    s
}

fn subst(sql: &str, map: impl Fn(&str) -> String) -> String {
    let mut out = String::with_capacity(sql.len() + 64);
    let bytes = sql.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'$' && i + 1 < bytes.len() && bytes[i + 1].is_ascii_digit() {
            let mut j = i + 1;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                j += 1;
            }
            out.push_str(&map(&sql[i + 1..j]));
            i = j;
        } else {
            out.push(bytes[i] as char);
            i += 1;
        }
    }
    out
}

fn article_batch(tags: &str) -> String {
    format!(
        "WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::text[]) \
         WITH ORDINALITY AS r(v, k, i)), \
         m AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, \
         a.updated_at, {tags} AS tags, \
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, \
         u.username, u.bio, u.image, a.author_id \
         FROM (SELECT DISTINCT k FROM r) d JOIN articles a ON a.slug = d.k \
         JOIN users u ON u.id = a.author_id) \
         SELECT r.i, m.id, m.slug, m.title, m.description, m.body, m.created_at, m.updated_at, \
         m.tags, m.fc, \
         EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.v AND f.article_id = m.id), \
         m.username, m.bio, m.image, \
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v \
         AND fo.followee_id = m.author_id) \
         FROM r JOIN m ON m.slug = r.k ORDER BY r.i"
    )
}

fn comments_batch() -> String {
    "WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::text[]) \
     WITH ORDINALITY AS r(v, k, i)), \
     a AS MATERIALIZED (SELECT a.id, a.slug FROM (SELECT DISTINCT k FROM r) d \
     JOIN articles a ON a.slug = d.k), \
     c AS MATERIALIZED (SELECT a.slug, c2.id, c2.body, c2.created_at, c2.updated_at, \
     c2.author_id, u.username, u.bio, u.image FROM a CROSS JOIN LATERAL \
     (SELECT c3.id, c3.body, c3.created_at, c3.updated_at, c3.author_id FROM comments c3 \
     WHERE c3.article_id = a.id ORDER BY c3.created_at DESC, c3.id DESC LIMIT 100) c2 \
     JOIN users u ON u.id = c2.author_id) \
     SELECT r.i, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, \
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v \
     AND fo.followee_id = c.author_id) \
     FROM r JOIN a ON a.slug = r.k LEFT JOIN c ON c.slug = a.slug \
     ORDER BY r.i, c.created_at DESC, c.id DESC"
        .to_string()
}

fn list_batch(count: &str, ids: &str, feed: bool, tags: &str) -> String {
    let (page_key, count_key) = if feed {
        (["v", "l", "o"], "v")
    } else {
        (["l", "o", "k"], "k")
    };
    let col = |n: &str| match n {
        "1" => "v",
        "2" => "l",
        "3" => "o",
        _ => "k",
    };
    let ids = subst(ids, |n| format!("q.{}", col(n)));
    let count = subst(count, |n| format!("d.{}", col(n)));
    let keys = page_key.join(", ");
    let q_keys = page_key.map(|k| format!("q.{k}")).join(", ");
    let join = page_key.map(|k| format!("pg.{k} = r.{k}")).join(" AND ");
    let following = if feed {
        "true".to_string()
    } else {
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v \
         AND fo.followee_id = m.author_id)"
            .to_string()
    };
    format!(
        "WITH r AS MATERIALIZED (SELECT * FROM unnest($1::int8[], $2::int8[], $3::int8[], \
         $4::text[]) WITH ORDINALITY AS r(v, l, o, k, i)), \
         q AS MATERIALIZED (SELECT DISTINCT {keys} FROM r), \
         pg AS MATERIALIZED (SELECT {q_keys}, x.id FROM q CROSS JOIN LATERAL ({ids}) x), \
         d AS MATERIALIZED (SELECT DISTINCT {count_key} FROM r), \
         cnt AS MATERIALIZED (SELECT d.{count_key}, c.n FROM d CROSS JOIN LATERAL {count} c), \
         m AS MATERIALIZED (SELECT a.id, a.slug, a.title, a.description, a.created_at, \
         a.updated_at, {tags} AS tags, \
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc, \
         u.username, u.bio, u.image, a.author_id \
         FROM (SELECT DISTINCT id FROM pg) di JOIN articles a ON a.id = di.id \
         JOIN users u ON u.id = a.author_id) \
         SELECT r.i, cnt.n, m.id, m.slug, m.title, m.description, m.created_at, m.updated_at, \
         m.tags, m.fc, \
         EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.v AND f.article_id = m.id), \
         m.username, m.bio, m.image, {following} \
         FROM r JOIN cnt ON cnt.{count_key} = r.{count_key} \
         LEFT JOIN pg ON {join} LEFT JOIN m ON m.id = pg.id \
         ORDER BY r.i, m.id DESC"
    )
}

fn batch_form(sql: &str, types: &[u32]) -> (String, Vec<u32>) {
    let inner = subst(sql, |n| format!("r.p{n}"));
    let mut arrays = Vec::new();
    let mut cols = Vec::new();
    let mut array_types = Vec::new();
    for (n, &t) in types.iter().enumerate() {
        let (cast, oid) = if t == INT8 {
            ("int8[]", INT8_ARRAY)
        } else {
            ("text[]", TEXT_ARRAY)
        };
        arrays.push(format!("${}::{cast}", n + 1));
        cols.push(format!("p{}", n + 1));
        array_types.push(oid);
    }
    let sql = format!(
        "SELECT r.i, x.* FROM unnest({}) WITH ORDINALITY AS r({}, i) \
         CROSS JOIN LATERAL ({inner}) x",
        arrays.join(", "),
        cols.join(", "),
    );
    (sql, array_types)
}

#[cfg(test)]
mod tests {
    #[test]
    #[ignore]
    fn dump() {
        for (i, (sql, types)) in super::statements(true).iter().enumerate() {
            println!("-- s{i} {types:?}\n{sql};");
        }
    }
}
