//! Prepared SQL. Every read statement takes arrays of *distinct* keys for one batch and tags each output row with
//! the key's 1-based ordinal `k`. Results match SPEC.md's reference SQL; ordering of rows within a key is restored
//! in the application where the statement doesn't order them.

use crate::pg::{INT8_ARRAY, TEXT_ARRAY};

pub struct Stmt {
    pub name: &'static str,
    pub sql: String,
    pub types: &'static [u32],
}

fn s(name: &'static str, sql: impl Into<String>, types: &'static [u32]) -> Stmt {
    Stmt { name, sql: sql.into(), types }
}

/// A count capped at 1,000, in one pass over at most 1,000 index entries.
fn capped(rows: &str) -> String {
    format!("(SELECT count(*) FROM ({rows} LIMIT 1000) s)")
}

/// Article row columns, after `k`: [id, author_id, slug, title, description, created_at, updated_at].
const COLS: &str = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";
/// NULL padding for a count row in a list statement (matches COLS after the count).
const PAD: &str = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

pub fn read_statements() -> Vec<Stmt> {
    vec![
        s("tags", "SELECT id, name FROM tags ORDER BY name", &[]),
        s(
            "uid",
            "SELECT r.k, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) \
             JOIN users u ON u.id = r.id",
            &[INT8_ARRAY],
        ),
        s(
            "uemail",
            "SELECT r.k, u.id, u.username, u.email, u.bio, u.image, u.password_hash \
             FROM unnest($1::text[]) WITH ORDINALITY r(email, k) JOIN users u ON u.email = r.email",
            &[TEXT_ARRAY],
        ),
        s(
            "prof",
            "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) \
             JOIN users u ON u.username = r.username",
            &[TEXT_ARRAY],
        ),
        // Article rows: [k, id, author_id, slug, title, description, created_at, updated_at (, body)].
        s(
            "aslug",
            format!("SELECT r.k, {COLS}, a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug"),
            &[TEXT_ARRAY],
        ),
        s(
            "aid",
            format!("SELECT r.k, {COLS}, a.body FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN articles a ON a.id = r.id"),
            &[INT8_ARRAY],
        ),
        s(
            "cmts",
            "SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id \
             FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug \
             LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c \
               WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true",
            &[TEXT_ARRAY],
        ),
        // Lists: one statement per filter returns the capped counts (k <= 0: -k is the count key, the count in
        // column 1) and the page rows (k > 0, the article row layout above). The global count walks the primary key
        // from the oldest end, whose pages are all-visible, so it stays an index-only scan while new articles keep
        // the newest pages dirty.
        s(
            "global",
            format!(
                "SELECT 0::int8, CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999) THEN 1000::int8 \
                   ELSE (SELECT count(*) FROM articles) END, {PAD} \
                 UNION ALL \
                 SELECT r.k, {COLS} FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) \
                 CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a"
            ),
            &[INT8_ARRAY, INT8_ARRAY],
        ),
        s(
            "tag",
            format!(
                "SELECT -r.k, {}, {PAD} FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag \
                 UNION ALL \
                 SELECT r.k, {COLS} FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(tag, lim, off, k) \
                 JOIN tags t ON t.name = r.tag \
                 CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id \
                   ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p \
                 JOIN articles a ON a.id = p.article_id",
                "CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = t.id OFFSET 999) THEN 1000::int8 \
                 ELSE (SELECT count(*) FROM article_tags at WHERE at.tag_id = t.id) END"
            ),
            &[TEXT_ARRAY, TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        s(
            "author",
            format!(
                "SELECT -r.k, {}, {PAD} FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username \
                 UNION ALL \
                 SELECT r.k, {COLS} FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) \
                 JOIN users u ON u.username = r.username \
                 CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
                capped("SELECT 1 FROM articles a WHERE a.author_id = u.id")
            ),
            &[TEXT_ARRAY, TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        s(
            "favlist",
            format!(
                "SELECT -r.k, {}, {PAD} FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username \
                 UNION ALL \
                 SELECT r.k, {COLS} FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) \
                 JOIN users u ON u.username = r.username \
                 CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id \
                   ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p \
                 JOIN articles a ON a.id = p.article_id",
                capped("SELECT 1 FROM favorites f WHERE f.user_id = u.id")
            ),
            &[TEXT_ARRAY, TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        // Personal feeds: capped counts per distinct viewer ($1, k <= 0), pages per (viewer, limit, offset) (k > 0).
        // Followees shared by several viewers of the batch ("hubs", popular authors) are looked at once for the
        // whole batch: whether the most shared ones have 1,000+ articles (one big followee settles a viewer's count,
        // so checking every hub mostly repeats work) (then every viewer following one counts 1,000 without
        // scanning), and the id of their depth-th newest article (a floor: a page of depth d is made of articles at
        // least that new, so every other followee's scan stops there). Other followees are read per viewer, at most
        // limit + offset newest ids each, from articles_author_idx. Page rows are ids and authors only (index-only);
        // the articles' columns are read once per distinct article in phase B ("artrow"), since popular followees'
        // newest articles are on many viewers' pages at once.
        s(
            "feed",
            format!(
                "WITH u AS MATERIALIZED ( \
                   SELECT r.k, r.v, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS fids, \
                     COALESCE((SELECT max(p.lim + p.off) FROM unnest($2::int8[], $3::int8[], $4::int8[]) p(v, lim, off) \
                       WHERE p.v = r.v), 1) AS depth \
                   FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)), \
                 hubs AS MATERIALIZED ( \
                   SELECT h.fid, \
                     (SELECT a.id FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET h.depth - 1) AS floor_id, \
                     CASE WHEN h.rn <= (SELECT GREATEST(6, count(*) / 8) FROM u) \
                       THEN EXISTS (SELECT 1 FROM articles a WHERE a.author_id = h.fid ORDER BY a.id DESC LIMIT 1 OFFSET 999) \
                       ELSE false END AS big \
                   FROM (SELECT f.fid, max(u.depth) AS depth, row_number() OVER (ORDER BY count(*) DESC, f.fid) AS rn \
                     FROM u, unnest(u.fids) f(fid) \
                     GROUP BY f.fid HAVING count(*) >= 2 ORDER BY count(*) DESC, f.fid LIMIT 32) h), \
                 big AS MATERIALIZED (SELECT ARRAY(SELECT fid FROM hubs WHERE big) AS fids) \
                 SELECT -u.k, CASE WHEN u.fids && (SELECT fids FROM big) THEN 1000::int8 \
                   ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(u.fids) LIMIT 1000) s) END, {PAD} \
                 FROM u \
                 UNION ALL \
                 SELECT p.k, x.id, x.fid, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz \
                 FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY p(v, lim, off, k) \
                 JOIN u ON u.v = p.v \
                 CROSS JOIN LATERAL (SELECT COALESCE(max(h.floor_id), 0) AS floor_id FROM hubs h WHERE h.fid = ANY(u.fids)) fl \
                 CROSS JOIN LATERAL (SELECT y.id, y.fid FROM unnest(u.fids) f(fid) CROSS JOIN LATERAL \
                   (SELECT a2.id, f.fid FROM articles a2 WHERE a2.author_id = f.fid AND a2.id >= fl.floor_id \
                     ORDER BY a2.id DESC LIMIT p.lim + p.off) y \
                   ORDER BY y.id DESC LIMIT p.lim OFFSET p.off) x"
            ),
            &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        // ---- phase B: enrichment over the union of everything phase A referenced ----
        // Article columns for articles phase A only returned ids for (feed pages), in the page-row layout.
        s(
            "artrow",
            format!("SELECT 0::int8, {COLS} FROM articles a WHERE a.id = ANY($1::int8[])"),
            &[INT8_ARRAY],
        ),
        // Comment authors' profile columns, for the sorted distinct ids of every comment in the batch: one ordered
        // walk of the primary key instead of a probe per comment row.
        s("auser", "SELECT u.id, u.username, u.bio, u.image FROM users u WHERE u.id = ANY($1::int8[])", &[INT8_ARRAY]),
        // One row per distinct article: its tag ids, its favorite count, its author's profile columns.
        s(
            "artx",
            "SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), \
             (SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image \
             FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
            &[INT8_ARRAY, INT8_ARRAY],
        ),
        // Viewer flags: (0, viewer, article) for each favorited pair asked about, (1, viewer, followee) for each
        // followed pair. Each viewer's candidates go in one primary-key range scan (= ANY) instead of a probe each.
        s(
            "flags",
            "WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), \
             q AS (SELECT x.v, array_agg(x.u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) \
             SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL \
               (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.aa)) f \
             UNION ALL \
             SELECT 1::int8, q.v, x.fid FROM q CROSS JOIN LATERAL \
               (SELECT fo.followee_id AS fid FROM follows fo WHERE fo.follower_id = q.v) x WHERE x.fid = ANY(q.uu)",
            &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
    ]
}

const SLUGIFY: &str = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";

pub fn write_statements() -> Vec<Stmt> {
    vec![
        s(
            "register",
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING \
             RETURNING id, username, email, bio, image",
            &[crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT],
        ),
        s(
            "upduser",
            "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
             WHERE id = $1 RETURNING id, username, email, bio, image",
            &[crate::pg::INT8, crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT],
        ),
        s(
            "follow",
            "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
             w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
             SELECT username, bio, image FROM t",
            &[crate::pg::INT8, crate::pg::TEXT],
        ),
        s(
            "unfollow",
            "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
             w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) \
             SELECT username, bio, image FROM t",
            &[crate::pg::INT8, crate::pg::TEXT],
        ),
        s(
            "fav",
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), \
             w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
             SELECT id FROM t",
            &[crate::pg::INT8, crate::pg::TEXT],
        ),
        s(
            "unfav",
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), \
             w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) \
             SELECT id FROM t",
            &[crate::pg::INT8, crate::pg::TEXT],
        ),
        // Runs of the same kind of write in a group, as one statement over arrays (row k = the run's k-th write; the
        // columns after k are the single statement's). Inserts take their rows in key order, so concurrent groups lock
        // in the same order.
        s(
            "fav_n",
            "WITH r AS (SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) \
               JOIN articles a ON a.slug = x.slug), \
             w AS (INSERT INTO favorites (user_id, article_id) SELECT DISTINCT uid, aid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING) \
             SELECT k, aid FROM r",
            &[INT8_ARRAY, TEXT_ARRAY],
        ),
        s(
            "unfav_n",
            "WITH r AS (SELECT x.k, x.uid, a.id AS aid FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(uid, slug, k) \
               JOIN articles a ON a.slug = x.slug), \
             w AS (DELETE FROM favorites f USING r WHERE f.user_id = r.uid AND f.article_id = r.aid) \
             SELECT k, aid FROM r",
            &[INT8_ARRAY, TEXT_ARRAY],
        ),
        s(
            "follow_n",
            "WITH r AS (SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image \
               FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) JOIN users u ON u.username = x.uname), \
             w AS (INSERT INTO follows (follower_id, followee_id) SELECT DISTINCT fid, tid FROM r ORDER BY 1, 2 ON CONFLICT DO NOTHING) \
             SELECT k, username, bio, image FROM r",
            &[INT8_ARRAY, TEXT_ARRAY],
        ),
        s(
            "unfollow_n",
            "WITH r AS (SELECT x.k, x.fid, u.id AS tid, u.username, u.bio, u.image \
               FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY x(fid, uname, k) JOIN users u ON u.username = x.uname), \
             w AS (DELETE FROM follows fo USING r WHERE fo.follower_id = r.fid AND fo.followee_id = r.tid) \
             SELECT k, username, bio, image FROM r",
            &[INT8_ARRAY, TEXT_ARRAY],
        ),
        // New comments: ids drawn in request order, so comments made in one transaction (same created_at) still list
        // newest first.
        s(
            "newcmt_n",
            "WITH r AS MATERIALIZED (SELECT x.k, x.uid, x.body, a.id AS aid \
               FROM unnest($1::int8[], $2::text[], $3::text[]) WITH ORDINALITY x(uid, slug, body, k) \
               JOIN articles a ON a.slug = x.slug ORDER BY x.k), \
             ids AS MATERIALIZED (SELECT s.k, s.uid, s.body, s.aid, nextval('comments_id_seq'::regclass) AS id \
               FROM (SELECT * FROM r ORDER BY k OFFSET 0) s), \
             c AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, aid, uid, body FROM ids \
               RETURNING id, body, created_at, updated_at, author_id) \
             SELECT ids.k, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
             FROM c JOIN ids ON ids.id = c.id JOIN users u ON u.id = c.author_id",
            &[INT8_ARRAY, TEXT_ARRAY, TEXT_ARRAY],
        ),
        // A new article and its whole response row (its tag list is the request's, distinct and in the database's
        // name order, as article_tags will hold it): no read-back after the commit.
        s(
            "newart",
            format!(
                "WITH n AS (INSERT INTO articles (id, slug, author_id, title, description, body) \
                   SELECT n.id, {SLUGIFY} || '-' || n.id, $1, $2, $3, $4 \
                   FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n RETURNING id, slug, created_at, updated_at) \
                 SELECT n.id, n.slug, n.created_at, n.updated_at, u.username, u.bio, u.image, \
                   ARRAY(SELECT DISTINCT x FROM unnest($5::text[]) x ORDER BY x), \
                   EXISTS (SELECT 1 FROM follows f WHERE f.follower_id = $1 AND f.followee_id = $1) \
                 FROM n JOIN users u ON u.id = $1"
            ),
            &[crate::pg::INT8, crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT, TEXT_ARRAY],
        ),
        s(
            "newtags",
            "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ORDER BY 1 ON CONFLICT (name) DO NOTHING",
            &[TEXT_ARRAY],
        ),
        // currval: the id the preceding "newart" drew from the sequence in this session.
        s(
            "arttags",
            "INSERT INTO article_tags (article_id, tag_id) \
             SELECT currval('articles_id_seq'::regclass), t.id FROM tags t WHERE t.name = ANY($1::text[])",
            &[TEXT_ARRAY],
        ),
        s(
            "updart",
            format!(
                "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
                 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), \
                   body = COALESCE($4, body), \
                   slug = CASE WHEN $2::text IS NULL THEN slug ELSE {SLUGIFY} || '-' || id END, updated_at = now() \
                   WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1) \
                 SELECT t.id, t.author_id FROM t"
            ),
            &[crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT, crate::pg::INT8],
        ),
        s(
            "delart",
            "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
             w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) \
             SELECT author_id FROM t",
            &[crate::pg::TEXT, crate::pg::INT8],
        ),
        s(
            "newcmt",
            "WITH t AS (SELECT id FROM articles WHERE slug = $1), \
             c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t \
               RETURNING id, body, created_at, updated_at, author_id) \
             SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
             FROM c JOIN users u ON u.id = c.author_id",
            &[crate::pg::TEXT, crate::pg::INT8, crate::pg::TEXT],
        ),
        s(
            "delcmt",
            "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
               WHERE c.id = $1 AND a.slug = $2), \
             w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) \
             SELECT author_id FROM t",
            &[crate::pg::INT8, crate::pg::TEXT, crate::pg::INT8],
        ),
    ]
}

#[cfg(test)]
mod dump {
    /// Prints every statement, for EXPLAIN by hand: cargo test --release dump_sql -- --ignored --nocapture
    #[test]
    #[ignore]
    fn dump_sql() {
        for s in super::read_statements().into_iter().chain(super::write_statements()) {
            println!("--@{}\n{};", s.name, s.sql);
        }
    }
}
