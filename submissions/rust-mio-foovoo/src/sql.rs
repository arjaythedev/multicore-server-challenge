//! Every statement the server runs, prepared once per Postgres connection as `s<index>`.
//!
//! Results match SPEC.md's reference SQL. Differences are in how many statements a request needs: list pages and their
//! capped counts are one statement, slug lookups are folded into the statement that needs them, and writes return
//! the response row themselves. `$1` is always the viewer where a statement has one.
//!
//! Two plan-level rewrites (same results): tag names are fetched per tag through `tags_pkey`, because the reference
//! join hash-joins a seq scan of every tag for every article row; and every page picks its ids first, so the per-row
//! subqueries run for the returned rows only, not for the rows OFFSET skips.

pub const INT8: u32 = 20;
pub const TEXT: u32 = 25;
pub const TEXT_ARRAY: u32 = 1009;

pub struct StmtDef {
    pub sql: &'static str,
    pub params: &'static [u32],
}

macro_rules! slugify {
    ($x:literal) => {
        concat!("trim(both '-' from lower(regexp_replace(", $x, ", '[^A-Za-z0-9]+', '-', 'g')))")
    };
}

/// ARTICLE_LIST_SELECT's columns. Column order is what `handlers::write_article` reads.
macro_rules! list_cols {
    ($following:literal) => {
        concat!("a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
         ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, \
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
         EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
         u.username, u.bio, u.image, ", $following, " AS following")
    };
}

/// ARTICLE_FULL_SELECT's columns (list columns plus `a.body` after `a.description`).
macro_rules! full_cols {
    () => {
        full_cols!("$1")
    };
    ($viewer:literal) => {
        concat!(
            "a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ",
            "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list, ",
            "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, ",
            "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = ", $viewer, ") AS favorited, ",
            "u.username, u.bio, u.image, ",
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ", $viewer, " AND fo.followee_id = a.author_id) AS following"
        )
    };
}

/// min(1000, number of rows) as `n`. A 1000th row (OFFSET 999) proves the cap without aggregating 1000 rows;
/// only smaller sets are counted exactly.
macro_rules! capped_count {
    ($from:literal, $key:literal) => {
        concat!(
            "SELECT CASE WHEN EXISTS (SELECT 1 ", $from, " ORDER BY ", $key, " OFFSET 999 LIMIT 1) ",
            "THEN 1000::bigint ELSE (SELECT count(*) ", $from, ") END AS n"
        )
    };
}

/// One list page plus its capped count. The LATERAL keeps the count row when the page is empty
/// (then every page column is NULL).
macro_rules! list_page {
    ($count:expr, $page_where:expr, $page_tail:expr) => {
        list_page_n!(concat!("SELECT count(*) AS n FROM (", $count, ") s"), $page_where, $page_tail)
    };
}

/// `list_page!` with the count row given as a full SELECT producing `n`.
macro_rules! list_page_n {
    ($n:expr, $page_where:expr, $page_tail:expr) => {
        list_page_n!($n, $page_where, $page_tail,
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)")
    };
    ($n:expr, $page_where:expr, $page_tail:expr, $following:literal) => {
        concat!(
            "WITH c AS (", $n, ") ",
            "SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT ", list_cols!($following),
            " FROM articles a JOIN users u ON u.id = a.author_id ", $page_where, " ", $page_tail,
            ") p ON true ORDER BY p.id DESC"
        )
    };
}

pub const LIST_ALL: usize = 0;
pub const LIST_TAG: usize = 1;
pub const LIST_AUTHOR: usize = 2;
pub const LIST_FAVORITED: usize = 3;
pub const FEED: usize = 4;
pub const ARTICLE_BY_SLUG: usize = 5;
pub const COMMENTS: usize = 6;
pub const TAGS: usize = 7;
pub const PROFILE: usize = 8;
pub const FOLLOW: usize = 9;
pub const UNFOLLOW: usize = 10;
pub const FAVORITE: usize = 11;
pub const UNFAVORITE: usize = 12;
pub const COMMENT_CREATE: usize = 13;
pub const COMMENT_DELETE: usize = 14;
pub const COMMENT_PROBE: usize = 15;
pub const ARTICLE_DELETE: usize = 16;
pub const ARTICLE_PROBE: usize = 17;
pub const ARTICLE_UPDATE: usize = 18;
pub const ARTICLE_INSERT: usize = 19;
pub const TAGS_INSERT: usize = 20;
pub const ARTICLE_TAGS_INSERT: usize = 21;
pub const ARTICLE_BY_CURRVAL: usize = 22;
pub const USER_INSERT: usize = 23;
pub const USER_BY_EMAIL: usize = 24;
pub const USER_BY_ID: usize = 25;
pub const USER_UPDATE: usize = 26;
const PAGE: &[u32] = &[INT8, INT8, INT8];
const PAGE_FILTER: &[u32] = &[INT8, INT8, INT8, TEXT];

pub static STATEMENTS: [StmtDef; 27] = [
    // LIST_ALL ($1 viewer, $2 limit, $3 offset)
    StmtDef {
        sql: list_page_n!(
            capped_count!("FROM articles a", "a.id"),
            "WHERE a.id IN (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT $2 OFFSET $3)",
            "ORDER BY a.id DESC"
        ),
        params: PAGE,
    },
    // LIST_TAG (+ $4 tag)
    StmtDef {
        sql: list_page_n!(
            capped_count!(
                "FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)",
                "at.article_id"
            ),
            "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)",
            "ORDER BY a.id DESC"
        ),
        params: PAGE_FILTER,
    },
    // LIST_AUTHOR (+ $4 username)
    StmtDef {
        sql: list_page!(
            "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000",
            "WHERE a.id IN (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3)",
            "ORDER BY a.id DESC"
        ),
        params: PAGE_FILTER,
    },
    // LIST_FAVORITED (+ $4 username)
    StmtDef {
        sql: list_page!(
            "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000",
            "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)",
            "ORDER BY a.id DESC"
        ),
        params: PAGE_FILTER,
    },
    // FEED (+ $4 = limit + offset, saturated in Rust so a huge offset can't overflow bigint)
    StmtDef {
        // Feed membership proves following in the same snapshot; the outer join still null-extends empty pages.
        sql: list_page_n!(
            "SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
            "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)",
            "ORDER BY a.id DESC",
            "true"
        ),
        params: &[INT8, INT8, INT8, INT8],
    },
    // ARTICLE_BY_SLUG ($1 viewer, $2 slug)
    StmtDef {
        sql: concat!("SELECT ", full_cols!(), " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"),
        params: &[INT8, TEXT],
    },
    // COMMENTS ($1 viewer, $2 slug): no row = unknown article; one row with NULL x.id = no comments.
    StmtDef {
        sql: "SELECT a.id, x.id, x.body, x.created_at, x.updated_at, x.username, x.bio, x.image, x.following \
              FROM articles a LEFT JOIN LATERAL ( \
                SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
                       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
                  FROM comments c JOIN users u ON u.id = c.author_id \
                 WHERE c.article_id = a.id \
                 ORDER BY c.created_at DESC, c.id DESC \
                 LIMIT 100) x ON true \
              WHERE a.slug = $2 \
              ORDER BY x.created_at DESC, x.id DESC",
        params: &[INT8, TEXT],
    },
    // TAGS
    StmtDef { sql: "SELECT ARRAY(SELECT name FROM tags ORDER BY name)", params: &[] },
    // PROFILE ($1 viewer, $2 username)
    StmtDef {
        sql: "SELECT u.id, u.username, u.bio, u.image, \
              EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
              FROM users u WHERE u.username = $2",
        params: &[INT8, TEXT],
    },
    // FOLLOW ($1 viewer, $2 username). Data-modifying CTEs run even when unreferenced.
    StmtDef {
        sql: "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
              w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING) \
              SELECT t.username, t.bio, t.image FROM t",
        params: &[INT8, TEXT],
    },
    // UNFOLLOW ($1 viewer, $2 username)
    StmtDef {
        sql: "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), \
              w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = $1 AND fo.followee_id = t.id) \
              SELECT t.username, t.bio, t.image FROM t",
        params: &[INT8, TEXT],
    },
    // FAVORITE ($1 viewer, $2 slug). The count subquery runs on the statement's snapshot, which can't see the CTE's
    // own insert, so the inserted row count is added back.
    StmtDef {
        sql: concat!(
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), ",
            "w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING RETURNING 1) ",
            "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ",
            "ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), ",
            "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w), ",
            "true, u.username, u.bio, u.image, ",
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) ",
            "FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id"
        ),
        params: &[INT8, TEXT],
    },
    // UNFAVORITE ($1 viewer, $2 slug)
    StmtDef {
        sql: concat!(
            "WITH t AS (SELECT id FROM articles WHERE slug = $2), ",
            "w AS (DELETE FROM favorites f USING t WHERE f.user_id = $1 AND f.article_id = t.id RETURNING 1) ",
            "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ",
            "ARRAY(SELECT (SELECT tg.name FROM tags tg WHERE tg.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1), ",
            "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM w), ",
            "false, u.username, u.bio, u.image, ",
            "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) ",
            "FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id"
        ),
        params: &[INT8, TEXT],
    },
    // COMMENT_CREATE ($1 viewer, $2 slug, $3 body): no row = unknown article.
    StmtDef {
        sql: "WITH c AS (INSERT INTO comments (article_id, author_id, body) \
                         SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2 \
                         RETURNING id, body, created_at, updated_at, author_id) \
              SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
                FROM c JOIN users u ON u.id = c.author_id",
        params: &[INT8, TEXT, TEXT],
    },
    // COMMENT_DELETE ($1 viewer, $2 comment id, $3 slug): deletes only the viewer's own comment.
    StmtDef {
        sql: "DELETE FROM comments c USING articles a \
              WHERE c.id = $2 AND a.id = c.article_id AND a.slug = $3 AND c.author_id = $1 RETURNING c.id",
        params: &[INT8, INT8, TEXT],
    },
    // COMMENT_PROBE ($1 comment id, $2 slug): after a 0-row delete, tells 404 from 403.
    StmtDef {
        sql: "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
        params: &[INT8, TEXT],
    },
    // ARTICLE_DELETE ($1 viewer, $2 slug)
    StmtDef { sql: "DELETE FROM articles WHERE slug = $2 AND author_id = $1 RETURNING id", params: &[INT8, TEXT] },
    // ARTICLE_PROBE ($1 slug)
    StmtDef { sql: "SELECT author_id FROM articles WHERE slug = $1", params: &[TEXT] },
    // ARTICLE_UPDATE ($1 viewer, $2 slug, $3 title, $4 description, $5 body). The CTE is named `a` so the full column
    // list applies to the updated row.
    StmtDef {
        sql: concat!(
            "WITH a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), ",
            "body = COALESCE($5, body), ",
            "slug = CASE WHEN $3::text IS NULL THEN slug ELSE ", slugify!("$3"), " || '-' || id END, ",
            "updated_at = now() WHERE slug = $2 AND author_id = $1 ",
            "RETURNING id, slug, title, description, body, created_at, updated_at, author_id) ",
            "SELECT ", full_cols!(), " FROM a JOIN users u ON u.id = a.author_id"
        ),
        params: &[INT8, TEXT, TEXT, TEXT, TEXT],
    },
    // ARTICLE_INSERT ($1 viewer, $2 title, $3 description, $4 body). First statement of the create group.
    StmtDef {
        sql: concat!(
            "INSERT INTO articles (id, slug, author_id, title, description, body) ",
            "SELECT n.id, ", slugify!("$2"), " || '-' || n.id, $1, $2, $3, $4 ",
            "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id"
        ),
        params: &[INT8, TEXT, TEXT, TEXT],
    },
    // TAGS_INSERT ($1 tags). Sorted so concurrent creates lock new tag keys in the same order (no deadlock).
    StmtDef {
        sql: "INSERT INTO tags (name) SELECT DISTINCT n FROM unnest($1::text[]) AS n ORDER BY n ON CONFLICT (name) DO NOTHING",
        params: &[TEXT_ARRAY],
    },
    // ARTICLE_TAGS_INSERT ($1 tags). currval is session-local: the create group runs on one connection.
    StmtDef {
        sql: "INSERT INTO article_tags (article_id, tag_id) \
              SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
        params: &[TEXT_ARRAY],
    },
    // ARTICLE_BY_CURRVAL ($1 viewer): the create group's response row. currval is volatile: compared directly it
    // disqualifies the primary key index (a 500k-row seq scan per create); as a scalar subquery it is evaluated once.
    StmtDef {
        sql: concat!(
            "SELECT ", full_cols!(),
            " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))"
        ),
        params: &[INT8],
    },
    // USER_INSERT ($1 username, $2 email, $3 password hash)
    StmtDef {
        sql: "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
        params: &[TEXT, TEXT, TEXT],
    },
    // USER_BY_EMAIL ($1 email)
    StmtDef {
        sql: "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
        params: &[TEXT],
    },
    // USER_BY_ID ($1 viewer)
    StmtDef { sql: "SELECT id, username, email, bio, image FROM users WHERE id = $1", params: &[INT8] },
    // USER_UPDATE ($1 viewer, $2 email, $3 username, $4 password hash, $5 bio, $6 image)
    StmtDef {
        sql: "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
              password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
              WHERE id = $1 RETURNING id, username, email, bio, image",
        params: &[INT8, TEXT, TEXT, TEXT, TEXT, TEXT],
    },
];

/// Statement names, `s0`..`s26`, so Bind can reference them without formatting per request.
pub static NAMES: [&str; 27] = [
    "s0", "s1", "s2", "s3", "s4", "s5", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13", "s14", "s15", "s16", "s17",
    "s18", "s19", "s20", "s21", "s22", "s23", "s24", "s25", "s26",
];

/// Typical Postgres execution time per statement (microseconds, pg_stat_statements means on the full seed at 64k
/// users, 4 backends on 4 cores). Only the ratios matter: they let routing compare queued work, not queued count.
pub static COST_US: [u32; 27] = [
    185, // LIST_ALL
    235, // LIST_TAG
    185, // LIST_AUTHOR
    195, // LIST_FAVORITED
    440, // FEED
    76,  // ARTICLE_BY_SLUG
    85,  // COMMENTS
    21,  // TAGS
    14,  // PROFILE
    110, // FOLLOW
    110, // UNFOLLOW
    105, // FAVORITE
    105, // UNFAVORITE
    220, // COMMENT_CREATE
    100, // COMMENT_DELETE
    20,  // COMMENT_PROBE
    100, // ARTICLE_DELETE
    20,  // ARTICLE_PROBE
    150, // ARTICLE_UPDATE
    116, // ARTICLE_INSERT
    50,  // TAGS_INSERT
    63,  // ARTICLE_TAGS_INSERT
    80,  // ARTICLE_BY_CURRVAL
    60,  // USER_INSERT
    20,  // USER_BY_EMAIL
    15,  // USER_BY_ID
    60,  // USER_UPDATE
];

#[cfg(test)]
mod tests {
    /// `SQL_DUMP=<dir> cargo test dump_sql -- --ignored` writes every statement as `s<i>.sql` for EXPLAIN work.
    #[test]
    #[ignore]
    fn dump_sql() {
        let dir = std::env::var("SQL_DUMP").expect("SQL_DUMP");
        for (i, st) in super::STATEMENTS.iter().enumerate() {
            let types: Vec<&str> = st.params.iter().map(|&o| match o {
                super::INT8 => "int8",
                super::TEXT => "text",
                super::TEXT_ARRAY => "text[]",
                _ => unreachable!(),
            }).collect();
            std::fs::write(format!("{dir}/s{i}.sql"), format!("PREPARE s{i}({}) AS {};\n", types.join(","), st.sql)).unwrap();
        }
    }
}
