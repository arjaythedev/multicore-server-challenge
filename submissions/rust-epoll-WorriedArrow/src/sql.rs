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

/// Proof that a count reaches the 1,000 cap without aggregating, else the exact count.
fn capped(rows: &str) -> String {
    format!("CASE WHEN EXISTS ({rows} OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM ({rows} LIMIT 1000) s) END")
}

/// Article row columns, after `k`: [id, author_id, slug, title, description, created_at, updated_at].
const COLS: &str = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";
/// NULL padding for a count row in a list statement (matches COLS after the count).
const PAD: &str = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

pub fn read_statements() -> Vec<Stmt> {
    vec![
        s("tags", "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", &[]),
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
            "SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image \
             FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug \
             LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c \
               WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true \
             LEFT JOIN users u ON u.id = c.author_id",
            &[TEXT_ARRAY],
        ),
        // Lists: one statement per filter returns the capped counts (k <= 0: -k is the count key, the count in
        // column 1) and the page rows (k > 0, the article row layout above). The global count walks the primary key
        // from the oldest end, whose pages are all-visible, so it stays an index-only scan while new articles keep
        // the newest pages dirty.
        s(
            "global",
            format!(
                "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), {PAD} \
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
                capped("SELECT 1 FROM article_tags at WHERE at.tag_id = t.id")
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
        // The page reads at most limit + offset of each followee's newest ids from articles_author_idx.
        s(
            "feed",
            format!(
                "SELECT -r.k, {}, {PAD} FROM unnest($1::int8[]) WITH ORDINALITY r(v, k) \
                 UNION ALL \
                 SELECT r.k, {COLS} FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY r(v, lim, off, k) \
                 CROSS JOIN LATERAL (SELECT y.id FROM follows fo CROSS JOIN LATERAL \
                   (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.lim + r.off) y \
                   WHERE fo.follower_id = r.v ORDER BY y.id DESC LIMIT r.lim OFFSET r.off) x \
                 JOIN articles a ON a.id = x.id",
                capped(
                    "SELECT 1 FROM articles a WHERE a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) \
                     ORDER BY a.author_id, a.id DESC"
                )
            ),
            &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        // ---- phase B: enrichment over the union of everything phase A referenced ----
        // One row per distinct article: its tag ids, its favorite count, its author's profile columns.
        s(
            "artx",
            "SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), \
             (SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image \
             FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
            &[INT8_ARRAY, INT8_ARRAY],
        ),
        // The names of every tag those articles carry, in the database's name order (tagList is sorted by name).
        s(
            "tagnames",
            "SELECT t.id, t.name FROM tags t WHERE t.id IN \
             (SELECT at.tag_id FROM article_tags at WHERE at.article_id = ANY($1::int8[])) ORDER BY t.name",
            &[INT8_ARRAY],
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
             SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL \
               (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.uu)) fo",
            &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
    ]
}

const SLUGIFY: &str = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";

pub fn write_statements() -> Vec<Stmt> {
    vec![
        s("begin", "BEGIN", &[]),
        s("commit", "COMMIT", &[]),
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
        s(
            "newart",
            format!(
                "INSERT INTO articles (id, slug, author_id, title, description, body) \
                 SELECT n.id, {SLUGIFY} || '-' || n.id, $1, $2, $3, $4 \
                 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id"
            ),
            &[crate::pg::INT8, crate::pg::TEXT, crate::pg::TEXT, crate::pg::TEXT],
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
             SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
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
