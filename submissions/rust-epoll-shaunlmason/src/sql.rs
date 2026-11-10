//! Prepared statements. Reads take arrays of distinct keys for a whole batch and tag every output row with the key's
//! 1-based ordinal `k` (from `WITH ORDINALITY`). Answers match SPEC.md's reference SQL; where a statement doesn't
//! order rows within a key, the application does.

use crate::pg::{INT8, INT8_ARRAY, TEXT, TEXT_ARRAY};

pub type Stmt = (&'static str, String, &'static [u32]);

fn s(name: &'static str, sql: impl Into<String>, types: &'static [u32]) -> Stmt {
    (name, sql.into(), types)
}

/// Article page columns after `k`: id, author_id, slug, title, description, created_at, updated_at.
const ART: &str = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";

/// `count(*)` of `rows`, stopping at the 1,000 cap: a 1,000th row proves the cap without aggregating (the form
/// rust-epoll-WorriedArrow uses).
fn capped(rows: &str) -> String {
    format!("CASE WHEN EXISTS ({rows} OFFSET 999) THEN 1000::int8 ELSE (SELECT count(*) FROM ({rows} LIMIT 1000) c) END")
}

/// Phase A: everything a request names directly.
pub fn phase_a() -> Vec<Stmt> {
    vec![
        s("tags", "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", &[]),
        s(
            "uid",
            "SELECT r.k, u.id, u.username, u.email, u.bio, u.image \
             FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN users u ON u.id = r.id",
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
            "SELECT r.k, u.id, u.username, u.bio, u.image \
             FROM unnest($1::text[]) WITH ORDINALITY r(username, k) JOIN users u ON u.username = r.username",
            &[TEXT_ARRAY],
        ),
        s(
            "aslug",
            format!("SELECT r.k, {ART}, a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug"),
            &[TEXT_ARRAY],
        ),
        s(
            "aid",
            format!("SELECT r.k, {ART}, a.body FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN articles a ON a.id = r.id"),
            &[INT8_ARRAY],
        ),
        // One row per found slug with no comments (c.id NULL), else one per comment (newest 100).
        s(
            "cmts",
            "SELECT r.k, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image \
             FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug \
             LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c \
               WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true \
             LEFT JOIN users u ON u.id = c.author_id",
            &[TEXT_ARRAY],
        ),
        // Pages: one row per article, keyed by the (filter, limit, offset) ordinal.
        s(
            "pglobal",
            format!(
                "SELECT r.k, {ART} FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) \
                 CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a"
            ),
            &[INT8_ARRAY, INT8_ARRAY],
        ),
        s(
            "ptag",
            format!(
                "SELECT r.k, {ART} FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY r(tag, lim, off, k) \
                 JOIN tags t ON t.name = r.tag \
                 CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id \
                   ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p \
                 JOIN articles a ON a.id = p.article_id"
            ),
            &[TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        s(
            "pauthor",
            format!(
                "SELECT r.k, {ART} FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY r(username, lim, off, k) \
                 JOIN users u ON u.username = r.username \
                 CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id \
                   ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a"
            ),
            &[TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        s(
            "pfav",
            format!(
                "SELECT r.k, {ART} FROM unnest($1::text[], $2::int8[], $3::int8[]) WITH ORDINALITY r(username, lim, off, k) \
                 JOIN users u ON u.username = r.username \
                 CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id \
                   ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p \
                 JOIN articles a ON a.id = p.article_id"
            ),
            &[TEXT_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
        // Reads at most limit + offset of each followee's newest ids from articles_author_idx, then merges.
        s(
            "pfeed",
            format!(
                "SELECT r.k, {ART} FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY r(v, lim, off, k) \
                 CROSS JOIN LATERAL (SELECT y.id FROM follows fo CROSS JOIN LATERAL \
                   (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.lim + r.off) y \
                   WHERE fo.follower_id = r.v ORDER BY y.id DESC LIMIT r.lim OFFSET r.off) x \
                 JOIN articles a ON a.id = x.id"
            ),
            &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
    ]
}

/// Phase B: counts that a page didn't settle, and enrichment of every article and author phase A found.
pub fn phase_b() -> Vec<Stmt> {
    vec![
        // Walks the primary key from the oldest end, whose heap pages are all-visible (an idea from
        // rust-epoll-WorriedArrow): new articles keep the newest pages dirty.
        s("cglobal", "SELECT (SELECT count(*) FROM (SELECT 1 FROM articles a ORDER BY a.id LIMIT 1000) c)", &[]),
        s(
            "ctag",
            format!(
                "SELECT r.k, {} FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) JOIN tags t ON t.name = r.tag",
                capped("SELECT 1 FROM article_tags at WHERE at.tag_id = t.id")
            ),
            &[TEXT_ARRAY],
        ),
        s(
            "cauthor",
            format!(
                "SELECT r.k, {} FROM unnest($1::text[]) WITH ORDINALITY r(username, k) JOIN users u ON u.username = r.username",
                capped("SELECT 1 FROM articles a WHERE a.author_id = u.id")
            ),
            &[TEXT_ARRAY],
        ),
        s(
            "cfav",
            format!(
                "SELECT r.k, {} FROM unnest($1::text[]) WITH ORDINALITY r(username, k) JOIN users u ON u.username = r.username",
                capped("SELECT 1 FROM favorites f WHERE f.user_id = u.id")
            ),
            &[TEXT_ARRAY],
        ),
        s(
            "cfeed",
            format!(
                "SELECT r.k, {} FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)",
                capped(
                    "SELECT 1 FROM articles a WHERE a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) \
                     ORDER BY a.author_id, a.id DESC"
                )
            ),
            &[INT8_ARRAY],
        ),
        // Per distinct article: tag ids, favorite count, and the author's profile columns.
        s(
            "artx",
            "SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), \
             (SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image \
             FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
            &[INT8_ARRAY, INT8_ARRAY],
        ),
        // Names of the tags those articles carry, in name order (tagList is sorted by name).
        s(
            "tagnames",
            "SELECT t.id, t.name FROM tags t WHERE t.id IN \
             (SELECT at.tag_id FROM article_tags at WHERE at.article_id = ANY($1::int8[])) ORDER BY t.name",
            &[INT8_ARRAY],
        ),
        // (0, viewer, article) per favorited pair, (1, viewer, user) per followed pair, among the pairs asked about.
        // Each viewer's candidates go in one primary-key scan (= ANY) rather than a probe each.
        s(
            "flags",
            "WITH p AS (SELECT x.v, array_agg(x.a) aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), \
             q AS (SELECT x.v, array_agg(x.u) uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) \
             SELECT 0::int8, p.v, f.article_id FROM p JOIN favorites f ON f.user_id = p.v AND f.article_id = ANY(p.aa) \
             UNION ALL \
             SELECT 1::int8, q.v, fo.followee_id FROM q JOIN follows fo ON fo.follower_id = q.v AND fo.followee_id = ANY(q.uu)",
            &[INT8_ARRAY, INT8_ARRAY, INT8_ARRAY, INT8_ARRAY],
        ),
    ]
}

const SLUGIFY: &str = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";

pub fn writes() -> Vec<Stmt> {
    vec![
        s("begin", "BEGIN", &[]),
        s("commit", "COMMIT", &[]),
        s("rollback", "ROLLBACK", &[]),
        // ON CONFLICT: a taken username/email gives no row (422) instead of aborting the group's transaction.
        s(
            "register",
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING \
             RETURNING id, username, email, bio, image",
            &[TEXT, TEXT, TEXT],
        ),
        s(
            "upduser",
            "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
             WHERE id = $1 RETURNING id, username, email, bio, image",
            &[INT8, TEXT, TEXT, TEXT, TEXT, TEXT],
        ),
        s(
            "follow",
            "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
             w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
             SELECT username, bio, image FROM t",
            &[INT8, TEXT],
        ),
        s(
            "unfollow",
            "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
             w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) \
             SELECT username, bio, image FROM t",
            &[INT8, TEXT],
        ),
        s(
            "fav",
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), \
             w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) \
             SELECT id FROM t",
            &[INT8, TEXT],
        ),
        s(
            "unfav",
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), \
             w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) \
             SELECT id FROM t",
            &[INT8, TEXT],
        ),
        // Article, new tags and its tag links in one statement. The tags subquery can't see rows the `t` CTE inserts
        // (one snapshot), so the new tags come from its RETURNING and the existing ones from the table.
        s(
            "newart",
            format!(
                "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id), \
                 a AS (INSERT INTO articles (id, slug, author_id, title, description, body) \
                   SELECT n.id, {SLUGIFY} || '-' || n.id, $1, $2, $3, $4 FROM n RETURNING id), \
                 t AS (INSERT INTO tags (name) SELECT DISTINCT unnest($5::text[]) ON CONFLICT (name) DO NOTHING RETURNING id), \
                 l AS (INSERT INTO article_tags (article_id, tag_id) \
                   SELECT a.id, x.id FROM a, (SELECT id FROM t UNION SELECT id FROM tags WHERE name = ANY($5::text[])) x) \
                 SELECT id FROM a"
            ),
            &[INT8, TEXT, TEXT, TEXT, TEXT_ARRAY],
        ),
        // Returns the article whether or not the viewer may change it; the caller answers 403 when not the author.
        s(
            "updart",
            format!(
                "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
                 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), \
                   body = COALESCE($4, body), \
                   slug = CASE WHEN $2::text IS NULL THEN slug ELSE {SLUGIFY} || '-' || id END, updated_at = now() \
                   WHERE id = (SELECT id FROM t WHERE author_id = $5)) \
                 SELECT id, author_id FROM t"
            ),
            &[TEXT, TEXT, TEXT, TEXT, INT8],
        ),
        s(
            "delart",
            "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), \
             w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) \
             SELECT author_id FROM t",
            &[TEXT, INT8],
        ),
        s(
            "newcmt",
            "WITH t AS (SELECT id FROM articles WHERE slug = $1), \
             c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t \
               RETURNING id, body, created_at, updated_at, author_id) \
             SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
             FROM c JOIN users u ON u.id = c.author_id",
            &[TEXT, INT8, TEXT],
        ),
        s(
            "delcmt",
            "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
               WHERE c.id = $1 AND a.slug = $2), \
             w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) \
             SELECT author_id FROM t",
            &[INT8, TEXT, INT8],
        ),
    ]
}
