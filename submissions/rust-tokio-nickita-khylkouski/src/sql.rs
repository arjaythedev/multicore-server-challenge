//! Prepared SQL. Each mutation is one statement; favorites and article updates
//! re-read with a fresh snapshot after commit. Results match SPEC.md's reference SQL.
//!
//! `$1` is always the viewer (0 = anonymous) in statements that compute `favorited` / `following`.

/// The Article columns over a row source `a` (id, slug, title, description, [body], created_at, updated_at,
/// author_id) joined to `users u`. The expensive per-row subqueries sit in the outer query, over a page that has
/// already been cut to LIMIT/OFFSET, so rows skipped by OFFSET never compute them. Tag names come from primary-key
/// lookups (1–4 per article) instead of the hash join over all of `tags` that a generic plan picks for the JOIN.
macro_rules! article_cols {
    ($body:literal) => {
        concat!(
            "a.id, a.slug, a.title, a.description, ",
            $body,
            "a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1),
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)"
        )
    };
}

/// A list page and its capped count in one statement: `c` is the count (one row), left-joined to the page so an
/// empty page still returns the count. Row layout: n, then the list Article columns (all NULL on an empty page).
macro_rules! list_stmt {
    ($count:expr, $page:expr) => {
        concat!(
            "WITH c AS (SELECT count(*) AS n FROM (",
            $count,
            " LIMIT 1000) s) SELECT c.n, ",
            article_cols!(""),
            " FROM c LEFT JOIN (",
            $page,
            ") a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
        )
    };
}

// The count walks the primary key from the oldest end: those pages are frozen and all-visible, so it stays an
// index-only scan with no heap fetches while new articles keep the newest pages dirty. min(count, 1000) either way.
pub const LIST_ALL: &str = r#"WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT * FROM (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET $3) bounded ORDER BY bounded.id DESC LIMIT $2) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC"#;

pub const LIST_TAG: &str = r#"WITH c AS (SELECT CASE WHEN EXISTS (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s) END AS n) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 fv.fc,
 fv.fav,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id LEFT JOIN LATERAL (SELECT count(*) AS fc, COALESCE(bool_or(f.user_id = $1),false) AS fav FROM favorites f WHERE f.article_id = a.id) fv ON true ORDER BY a.id DESC"#;

pub const LIST_AUTHOR: &str = list_stmt!(
    "SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = $4)",
    "SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a2.id DESC LIMIT $2 OFFSET $3"
);

pub const LIST_FAVORITED: &str = r#"WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s) SELECT c.n, a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
 ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
 (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
 COALESCE(a.id = ANY(ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = $1)), false),
 u.username, u.bio, u.image,
 COALESCE(a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)), false) FROM c LEFT JOIN (SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.article_id) a ON true LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"#;

pub const LIST_FEED: &str = list_stmt!(
    "SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) ORDER BY a3.author_id, a3.id DESC",
    "SELECT a2.id, a2.slug, a2.title, a2.description, a2.created_at, a2.updated_at, a2.author_id FROM (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) p JOIN articles a2 ON a2.id = p.id"
);

/// Full Article row layout: id, slug, title, description, body, created_at, updated_at, tags, count, favorited,
/// username, bio, image, following.
pub const ARTICLE_BY_SLUG: &str = concat!(
    "SELECT ",
    article_cols!("a.body, "),
    " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"
);

pub const ARTICLE_BY_ID: &str = concat!(
    "SELECT ",
    article_cols!("a.body, "),
    " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2"
);

/// RETURNING through the article lookup also distinguishes an absent slug.
/// Read the article in a separate statement after this implicit transaction commits.
pub const FAVORITE: &str = "WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT id FROM t";

pub const UNFAVORITE: &str = "WITH t AS (SELECT id FROM articles WHERE slug = $2),
 w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t))
SELECT id FROM t";

/// Create an article with its tags in one statement (one implicit transaction). `ON CONFLICT DO UPDATE` returns
/// the id of a concurrently created tag absent from our snapshot. Existing tags are read
/// without updating or locking them. RETURNING covers the concurrent-insert case.
/// Same row layout as ARTICLE_BY_ID; a new article has no favorites.
pub const ARTICLE_CREATE: &str = "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id),
 a AS (INSERT INTO articles (id, slug, author_id, title, description, body)
       SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 FROM n
       RETURNING id, slug, title, description, body, created_at, updated_at, author_id),
 existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($5::text[])),
 t AS (INSERT INTO tags (name)
       SELECT name FROM (SELECT DISTINCT unnest($5::text[]) AS name) names
       WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name)
       ORDER BY name ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name),
 all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t),
 x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at,
 ARRAY(SELECT name FROM all_tags ORDER BY name), 0::bigint, false,
 u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)
FROM a JOIN users u ON u.id = a.author_id";

/// Returns (id, author_id) of the article; the UPDATE only applies when the viewer ($5) is the author.
pub const ARTICLE_UPDATE: &str = "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
       slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
       updated_at = now()
       WHERE id = (SELECT id FROM t WHERE author_id = $5) RETURNING 1)
SELECT t.id, t.author_id, (SELECT count(*) FROM w) FROM t";

/// Returns the article's author_id; the DELETE only applies when the viewer ($2) is the author.
pub const ARTICLE_DELETE: &str = "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
 w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2))
SELECT author_id FROM t";

/// Article id, then up to 100 comments (all comment columns NULL when there are none). No row = no article.
pub const COMMENTS_LIST: &str = "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)
FROM articles a
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
LEFT JOIN users u ON u.id = c.author_id
WHERE a.slug = $2
ORDER BY c.created_at DESC, c.id DESC";

/// Materialize the viewer's followee set once for all comments in this execution.
pub const COMMENTS_LIST_SET: &str = "SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 COALESCE(c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1), false)
FROM articles a
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c WHERE c.article_id = a.id
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
LEFT JOIN users u ON u.id = c.author_id
WHERE a.slug = $2
ORDER BY c.created_at DESC, c.id DESC";

/// No row = no article.
pub const COMMENT_CREATE: &str = "WITH t AS (SELECT id FROM articles WHERE slug = $1),
 c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t
       RETURNING id, body, created_at, updated_at, author_id)
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id";

/// Returns the comment's author_id; the DELETE only applies when the viewer ($3) is the author.
pub const COMMENT_DELETE: &str =
    "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                WHERE c.id = $1 AND a.slug = $2),
 w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3))
SELECT author_id FROM t";

pub const PROFILE: &str = "SELECT u.username, u.bio, u.image,
 EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id)
FROM users u WHERE u.username = $2";

pub const FOLLOW: &str =
    "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image FROM t";

pub const UNFOLLOW: &str =
    "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
 w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t))
SELECT username, bio, image FROM t";

pub const TAGS: &str = "SELECT ARRAY(SELECT name FROM tags ORDER BY name)";

/// User row layout everywhere: id, username, email, bio, image.
pub const USER_BY_ID: &str = "SELECT id, username, email, bio, image FROM users WHERE id = $1";

pub const USER_BY_EMAIL: &str =
    "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";

pub const USER_INSERT: &str =
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
RETURNING id, username, email, bio, image";

pub const USER_UPDATE: &str =
    "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
WHERE id = $1
RETURNING id, username, email, bio, image";
