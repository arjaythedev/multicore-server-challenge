//! SQL for every endpoint.
//!
//! Design rules:
//!  * Every request is ONE round trip: a few Bind/Execute pairs followed by a single Sync, so the
//!    statements run in one implicit transaction that is committed before ReadyForQuery arrives
//!    (the response is only written after that, so "committed before you respond" holds).
//!  * No explicit BEGIN/COMMIT (an error would leave the connection in an aborted transaction).
//!  * Where the reference does "SELECT, then decide, then UPDATE", the decision is moved into SQL
//!    (conditional INSERT/UPDATE/DELETE) and a second statement in the same batch returns the data.
//!  * All parameters are sent in binary format with explicit type OIDs.
//!  * LIMIT is a literal (one lazily-prepared statement per limit value). With
//!    plan_cache_mode=force_generic_plan a `LIMIT $n` makes the planner assume 10% of the table
//!    and it can pick a hash join + seq scan; a literal keeps the "walk the index and stop" plan.

use crate::pg::{self, PgConn};

pub const I8: u32 = 20; // int8 / bigint
pub const TXT: u32 = 25; // text
pub const TXTA: u32 = 1009; // text[]

pub const S_TAGS: usize = 0;
pub const S_USER_BY_ID: usize = 1;
pub const S_USER_BY_EMAIL: usize = 2;
pub const S_USER_INSERT: usize = 3;
pub const S_USER_UPDATE: usize = 4;
pub const S_PROFILE: usize = 5;
pub const S_FOLLOW: usize = 6;
pub const S_UNFOLLOW: usize = 7;
pub const S_ARTICLE_SLUG: usize = 8;
pub const S_ARTICLE_CURR: usize = 9;
pub const S_ART_INSERT: usize = 10;
pub const S_TAGS_INSERT: usize = 11;
pub const S_AT_INSERT: usize = 12;
pub const S_ART_AUTH: usize = 13;
pub const S_ART_UPDATE: usize = 14;
pub const S_ART_DELETE: usize = 15;
pub const S_FAV: usize = 16;
pub const S_UNFAV: usize = 17;
pub const S_ART_ID: usize = 18;
pub const S_COMMENTS: usize = 19;
pub const S_COMMENT_INSERT: usize = 20;
pub const S_COMMENT_AUTH: usize = 21;
pub const S_COMMENT_DELETE: usize = 22;
pub const S_COUNT_NONE: usize = 23;
pub const S_COUNT_TAG: usize = 24;
pub const S_COUNT_AUTHOR: usize = 25;
pub const S_COUNT_FAV: usize = 26;
pub const S_COUNT_FEED: usize = 27;
pub const N_STATIC: usize = 28;

static NAMES: [&[u8]; N_STATIC] = [
    b"s00\0", b"s01\0", b"s02\0", b"s03\0", b"s04\0", b"s05\0", b"s06\0", b"s07\0", b"s08\0",
    b"s09\0", b"s10\0", b"s11\0", b"s12\0", b"s13\0", b"s14\0", b"s15\0", b"s16\0", b"s17\0",
    b"s18\0", b"s19\0", b"s20\0", b"s21\0", b"s22\0", b"s23\0", b"s24\0", b"s25\0", b"s26\0",
    b"s27\0",
];

/// NUL-terminated prepared-statement name of a static statement.
pub fn name(idx: usize) -> &'static [u8] {
    NAMES[idx]
}

/// Columns of an article row. `$1` is the viewer id (0 = anonymous). Column order:
/// 0 id, 1 slug, 2 title, 3 description, 4 created_at, 5 updated_at, 6 tag names (text[]),
/// 7 favorites count, 8 favorited, 9 author username, 10 author bio, 11 author image,
/// 12 following author. Full article queries append `a.body` as column 13.
const COLS: &str = "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
 ARRAY(SELECT t.name FROM article_tags atg JOIN tags t ON t.id = atg.tag_id WHERE atg.article_id = a.id ORDER BY t.name), \
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id), \
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1), \
 u.username, u.bio, u.image, \
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)";

const SLUGIFY_TITLE: &str =
    "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))";
const SLUGIFY_TITLE_3: &str =
    "trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g')))";

/// Statement table, in index order (checked at startup).
pub fn build() -> Vec<(String, Vec<u32>)> {
    let mut v: Vec<(String, Vec<u32>)> = Vec::with_capacity(N_STATIC);
    {
        let mut add = |idx: usize, sql: String, oids: &[u32]| {
            assert_eq!(v.len(), idx, "statement table out of order");
            v.push((sql, oids.to_vec()));
        };

        add(S_TAGS, "SELECT name FROM tags ORDER BY name".to_string(), &[]);

        add(
            S_USER_BY_ID,
            "SELECT id, username, email, bio, image FROM users WHERE id = $1".to_string(),
            &[I8],
        );

        add(
            S_USER_BY_EMAIL,
            "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
                .to_string(),
            &[TXT],
        );

        add(
            S_USER_INSERT,
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) \
             RETURNING id, username, email, bio, image"
                .to_string(),
            &[TXT, TXT, TXT],
        );

        // $1 id, $2 email, $3 username, $4 password_hash, $5 bio, $6 image (NULL = keep)
        add(
            S_USER_UPDATE,
            "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), \
             image = COALESCE($6, image) WHERE id = $1 \
             RETURNING id, username, email, bio, image"
                .to_string(),
            &[I8, TXT, TXT, TXT, TXT, TXT],
        );

        // $1 viewer, $2 username
        add(
            S_PROFILE,
            "SELECT u.username, u.bio, u.image, \
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) \
             FROM users u WHERE u.username = $2"
                .to_string(),
            &[I8, TXT],
        );

        add(
            S_FOLLOW,
            "INSERT INTO follows (follower_id, followee_id) \
             SELECT $1, u.id FROM users u WHERE u.username = $2 ON CONFLICT DO NOTHING"
                .to_string(),
            &[I8, TXT],
        );

        add(
            S_UNFOLLOW,
            "DELETE FROM follows WHERE follower_id = $1 \
             AND followee_id = (SELECT id FROM users WHERE username = $2)"
                .to_string(),
            &[I8, TXT],
        );

        // $1 viewer, $2 slug
        add(
            S_ARTICLE_SLUG,
            format!(
                "SELECT {}, a.body FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
                COLS
            ),
            &[I8, TXT],
        );

        // $1 viewer; the article created earlier in the same batch (same session/transaction).
        // currval() is volatile and could not be an index condition; wrapping it in a scalar
        // subquery turns it into an InitPlan, so this stays a primary-key lookup.
        add(
            S_ARTICLE_CURR,
            format!(
                "SELECT {}, a.body FROM articles a JOIN users u ON u.id = a.author_id \
                 WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))",
                COLS
            ),
            &[I8],
        );

        // $1 author, $2 title, $3 description, $4 body
        add(
            S_ART_INSERT,
            format!(
                "INSERT INTO articles (id, slug, author_id, title, description, body) \
                 SELECT n.id, {} || '-' || n.id, $1, $2, $3, $4 \
                 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n",
                SLUGIFY_TITLE
            ),
            &[I8, TXT, TXT, TXT],
        );

        add(
            S_TAGS_INSERT,
            "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"
                .to_string(),
            &[TXTA],
        );

        add(
            S_AT_INSERT,
            "INSERT INTO article_tags (article_id, tag_id) \
             SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id \
             FROM tags t WHERE t.name = ANY($1::text[])"
                .to_string(),
            &[TXTA],
        );

        add(
            S_ART_AUTH,
            "SELECT author_id FROM articles WHERE slug = $1".to_string(),
            &[TXT],
        );

        // $1 viewer (= required author), $2 slug, $3 title, $4 description, $5 body (NULL = keep)
        add(
            S_ART_UPDATE,
            format!(
                "WITH upd AS (UPDATE articles SET title = COALESCE($3, title), \
                 description = COALESCE($4, description), body = COALESCE($5, body), \
                 slug = CASE WHEN $3::text IS NULL THEN slug ELSE {} || '-' || id END, \
                 updated_at = now() WHERE slug = $2 AND author_id = $1 \
                 RETURNING id, slug, title, description, body, created_at, updated_at, author_id) \
                 SELECT {}, a.body FROM upd a JOIN users u ON u.id = a.author_id",
                SLUGIFY_TITLE_3, COLS
            ),
            &[I8, TXT, TXT, TXT, TXT],
        );

        add(
            S_ART_DELETE,
            "DELETE FROM articles WHERE slug = $1 AND author_id = $2".to_string(),
            &[TXT, I8],
        );

        add(
            S_FAV,
            "INSERT INTO favorites (user_id, article_id) \
             SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING"
                .to_string(),
            &[I8, TXT],
        );

        add(
            S_UNFAV,
            "DELETE FROM favorites WHERE user_id = $1 \
             AND article_id = (SELECT id FROM articles WHERE slug = $2)"
                .to_string(),
            &[I8, TXT],
        );

        add(
            S_ART_ID,
            "SELECT id FROM articles WHERE slug = $1".to_string(),
            &[TXT],
        );

        // $1 viewer, $2 slug
        add(
            S_COMMENTS,
            "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) \
             FROM comments c JOIN users u ON u.id = c.author_id \
             WHERE c.article_id = (SELECT id FROM articles WHERE slug = $2) \
             ORDER BY c.created_at DESC, c.id DESC LIMIT 100"
                .to_string(),
            &[I8, TXT],
        );

        // $1 slug, $2 author, $3 body
        add(
            S_COMMENT_INSERT,
            "WITH c AS (INSERT INTO comments (article_id, author_id, body) \
             SELECT a.id, $2, $3 FROM articles a WHERE a.slug = $1 \
             RETURNING id, body, created_at, updated_at, author_id) \
             SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
             FROM c JOIN users u ON u.id = c.author_id"
                .to_string(),
            &[TXT, I8, TXT],
        );

        // $1 comment id, $2 slug
        add(
            S_COMMENT_AUTH,
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
             WHERE c.id = $1 AND a.slug = $2"
                .to_string(),
            &[I8, TXT],
        );

        // $1 comment id, $2 slug, $3 author (viewer)
        add(
            S_COMMENT_DELETE,
            "DELETE FROM comments WHERE id = $1 AND author_id = $3 \
             AND article_id = (SELECT id FROM articles WHERE slug = $2)"
                .to_string(),
            &[I8, TXT, I8],
        );

        add(
            S_COUNT_NONE,
            "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s".to_string(),
            &[],
        );

        add(
            S_COUNT_TAG,
            "SELECT count(*) FROM (SELECT 1 FROM article_tags atg \
             WHERE atg.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"
                .to_string(),
            &[TXT],
        );

        add(
            S_COUNT_AUTHOR,
            "SELECT count(*) FROM (SELECT 1 FROM articles a \
             WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"
                .to_string(),
            &[TXT],
        );

        add(
            S_COUNT_FAV,
            "SELECT count(*) FROM (SELECT 1 FROM favorites f \
             WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"
                .to_string(),
            &[TXT],
        );

        add(
            S_COUNT_FEED,
            "SELECT count(*) FROM (SELECT 1 FROM articles a \
             WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) \
             LIMIT 1000) s"
                .to_string(),
            &[I8],
        );
    }
    v
}

// ---------------------------------------------------------------------------- list pages

pub const LIST_NONE: usize = 0;
pub const LIST_TAG: usize = 1;
pub const LIST_AUTHOR: usize = 2;
pub const LIST_FAV: usize = 3;
pub const LIST_FEED: usize = 4;
pub const LIST_KINDS: usize = 5;
pub const LIMIT_SLOTS: usize = 128;

static OIDS_2: [u32; 2] = [I8, I8];
static OIDS_3: [u32; 3] = [I8, I8, TXT];

/// One page of articles. Params: $1 viewer, $2 offset, ($3 tag / author / favoriting username).
/// The inner subquery picks the ids (cheap, index only); the outer query evaluates the expensive
/// per-row columns only for rows that are actually returned.
pub fn list_sql(kind: usize, limit: usize) -> (String, &'static [u32]) {
    let inner = match kind {
        LIST_NONE => format!(
            "SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT {} OFFSET $2",
            limit
        ),
        LIST_TAG => format!(
            "SELECT at2.article_id AS id FROM article_tags at2 \
             WHERE at2.tag_id = (SELECT t2.id FROM tags t2 WHERE t2.name = $3) \
             ORDER BY at2.article_id DESC LIMIT {} OFFSET $2",
            limit
        ),
        LIST_AUTHOR => format!(
            "SELECT a2.id FROM articles a2 \
             WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $3) \
             ORDER BY a2.id DESC LIMIT {} OFFSET $2",
            limit
        ),
        LIST_FAV => format!(
            "SELECT f2.article_id AS id FROM favorites f2 \
             WHERE f2.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $3) \
             ORDER BY f2.article_id DESC LIMIT {} OFFSET $2",
            limit
        ),
        _ => format!(
            "SELECT x.id FROM follows fo2 CROSS JOIN LATERAL \
             (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo2.followee_id \
              ORDER BY a3.id DESC LIMIT ({} + $2)) x \
             WHERE fo2.follower_id = $1 ORDER BY x.id DESC LIMIT {} OFFSET $2",
            limit, limit
        ),
    };
    let sql = format!(
        "SELECT {} FROM ({}) p JOIN articles a ON a.id = p.id \
         JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
        COLS, inner
    );
    let oids: &'static [u32] = match kind {
        LIST_NONE => &OIDS_2,
        LIST_FEED => &OIDS_2,
        _ => &OIDS_3,
    };
    (sql, oids)
}

/// NUL-terminated name of the lazily prepared list statement, e.g. `l1010\0` (kind 1, limit 10).
pub fn list_name(kind: usize, limit: usize, buf: &mut [u8; 8]) -> &[u8] {
    buf[0] = b'l';
    buf[1] = b'0' + kind as u8;
    buf[2] = b'0' + (limit / 100) as u8;
    buf[3] = b'0' + ((limit / 10) % 10) as u8;
    buf[4] = b'0' + (limit % 10) as u8;
    buf[5] = 0;
    &buf[..6]
}

/// Appends a Parse message for the list statement the first time this connection needs it.
/// Later Bind messages in the same pipelined batch refer to it by name (Parse is always sent first).
pub fn ensure_list(pg_conn: &mut PgConn, kind: usize, limit: usize) {
    let slot = kind * LIMIT_SLOTS + limit;
    if pg_conn.list_prepared[slot] {
        return;
    }
    pg_conn.list_prepared[slot] = true;
    let (sql, oids) = list_sql(kind, limit);
    let mut nm = [0u8; 8];
    let nm_slice = list_name(kind, limit, &mut nm);
    pg::parse_msg(&mut pg_conn.tx_pending, nm_slice, &sql, oids);
}
