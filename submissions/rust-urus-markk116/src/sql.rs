//! Every statement the server runs.
//!
//! The SQL is SPEC.md's reference SQL, with two kinds of change:
//!
//! - Writes are keyed by slug or username instead of a looked-up id, so a handler can send
//!   [write, read back] as one batch: one round trip, one transaction. An unknown slug or
//!   username makes the write a no-op and the read empty (404).
//! - Article selects build the tag list with a per-tag `tags_pkey` lookup instead of a join,
//!   which the planner otherwise turns into a seq scan of all tags per article row (~65% of
//!   list-page cost). Same rows, same order.
//!
//! Each SELECT lists its columns in the field order of the model it is read into (see
//! `model.rs`).

use crate::db::oid::{INT8, TEXT, TEXT_ARR};
use crate::db::Stmt;

/// Columns of [`crate::model::Article`]; `$body` is `a.body` or, for list pages, `NULL`.
macro_rules! article_select {
    ($body:literal) => {
        concat!(
            "SELECT a.slug, a.title, a.description, ",
            $body,
            " AS body, \
             ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at \
                   WHERE at.article_id = a.id ORDER BY 1) AS tag_list, \
             a.created_at, a.updated_at, \
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
             (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
             u.username, u.bio, u.image, \
             EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following \
             FROM articles a JOIN users u ON u.id = a.author_id"
        )
    };
}

/// `slug` for a title: lowercase, runs of anything but letters and digits as one '-'.
macro_rules! slugify {
    ($title:literal) => {
        concat!("trim(both '-' from lower(regexp_replace(", $title, ", '[^A-Za-z0-9]+', '-', 'g')))")
    };
}

// ---- users ----

pub static USER_INSERT: Stmt = Stmt::write(
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) \
     RETURNING id, email, username, bio, image",
    &[TEXT, TEXT, TEXT],
);
pub static CREDENTIALS_BY_EMAIL: Stmt = Stmt::read(
    "SELECT id, email, username, bio, image, password_hash FROM users WHERE email = $1",
    &[TEXT],
);
pub static USER_BY_ID: Stmt = Stmt::read("SELECT id, email, username, bio, image FROM users WHERE id = $1", &[INT8]);
pub static USER_UPDATE: Stmt = Stmt::write(
    "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), \
     password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) \
     WHERE id = $1 RETURNING id, email, username, bio, image",
    &[INT8, TEXT, TEXT, TEXT, TEXT, TEXT],
);

// ---- profiles ----

pub static PROFILE: Stmt = Stmt::read(
    "SELECT u.username, u.bio, u.image, \
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
     FROM users u WHERE u.username = $2",
    &[INT8, TEXT],
);
pub static FOLLOW: Stmt = Stmt::write(
    "INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM users u WHERE u.username = $2 \
     ON CONFLICT DO NOTHING",
    &[INT8, TEXT],
);
pub static UNFOLLOW: Stmt = Stmt::write(
    "DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2)",
    &[INT8, TEXT],
);

// ---- article lists: $1 viewer, $2 limit, $3 offset, $4 filter value ----

pub static LIST_ALL: Stmt = Stmt::read(
    concat!(article_select!("NULL"), " ORDER BY a.id DESC LIMIT $2 OFFSET $3"),
    &[INT8, INT8, INT8],
);
pub static LIST_BY_TAG: Stmt = Stmt::read(
    concat!(
        article_select!("NULL"),
        " WHERE a.id IN (SELECT at.article_id FROM article_tags at \
           WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) \
           ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) \
         ORDER BY a.id DESC"
    ),
    &[INT8, INT8, INT8, TEXT],
);
pub static LIST_BY_AUTHOR: Stmt = Stmt::read(
    concat!(
        article_select!("NULL"),
        " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) \
         ORDER BY a.id DESC LIMIT $2 OFFSET $3"
    ),
    &[INT8, INT8, INT8, TEXT],
);
pub static LIST_FAVORITED_BY: Stmt = Stmt::read(
    concat!(
        article_select!("NULL"),
        " WHERE a.id IN (SELECT f.article_id FROM favorites f \
           WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) \
           ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) \
         ORDER BY a.id DESC"
    ),
    &[INT8, INT8, INT8, TEXT],
);
pub static LIST_FEED: Stmt = Stmt::read(
    concat!(
        article_select!("NULL"),
        " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL \
           (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id \
            ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x \
           WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) \
         ORDER BY a.id DESC"
    ),
    &[INT8, INT8, INT8],
);

// ---- article counts, capped at 1,000 ----

pub static COUNT_ALL: Stmt = Stmt::read("SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s", &[]);
pub static COUNT_BY_TAG: Stmt = Stmt::read(
    "SELECT count(*) FROM (SELECT 1 FROM article_tags at \
     WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
    &[TEXT],
);
pub static COUNT_BY_AUTHOR: Stmt = Stmt::read(
    "SELECT count(*) FROM (SELECT 1 FROM articles a \
     WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
    &[TEXT],
);
pub static COUNT_FAVORITED_BY: Stmt = Stmt::read(
    "SELECT count(*) FROM (SELECT 1 FROM favorites f \
     WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
    &[TEXT],
);
pub static COUNT_FEED: Stmt = Stmt::read(
    "SELECT count(*) FROM (SELECT 1 FROM articles a \
     WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
    &[INT8],
);

// ---- single articles: $1 viewer ----

pub static ARTICLE_BY_SLUG: Stmt = Stmt::read(concat!(article_select!("a.body"), " WHERE a.slug = $2"), &[INT8, TEXT]);
pub static ARTICLE_BY_ID: Stmt = Stmt::read(concat!(article_select!("a.body"), " WHERE a.id = $2"), &[INT8, INT8]);
/// The article just inserted by [`ARTICLE_INSERT`] in the same batch. `currval` must stay in a
/// scalar subquery: it is volatile, so compared directly it is re-evaluated per row and the
/// lookup becomes a sequential scan of every article (seconds per call on the full seed).
pub static NEW_ARTICLE: Stmt = Stmt::read(
    concat!(article_select!("a.body"), " WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))"),
    &[INT8],
);
pub static ARTICLE_OWNER: Stmt = Stmt::read("SELECT id, author_id FROM articles WHERE slug = $1", &[TEXT]);

pub static ARTICLE_INSERT: Stmt = Stmt::write(
    concat!(
        "INSERT INTO articles (id, slug, author_id, title, description, body) \
         SELECT n.id, ",
        slugify!("$2"),
        " || '-' || n.id, $1, $2, $3, $4 \
         FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n"
    ),
    &[INT8, TEXT, TEXT, TEXT],
);
pub static TAGS_INSERT: Stmt = Stmt::write(
    "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
    &[TEXT_ARR],
);
/// Tags the article just inserted by [`ARTICLE_INSERT`] in the same batch.
pub static NEW_ARTICLE_TAGS: Stmt = Stmt::write(
    "INSERT INTO article_tags (article_id, tag_id) \
     SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
    &[TEXT_ARR],
);
/// A new title also gives the article a new slug.
pub static ARTICLE_UPDATE: Stmt = Stmt::write(
    concat!(
        "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), \
         body = COALESCE($4, body), slug = CASE WHEN $2::text IS NULL THEN slug ELSE ",
        slugify!("$2"),
        " || '-' || id END, updated_at = now() WHERE id = $1"
    ),
    &[INT8, TEXT, TEXT, TEXT],
);
/// Deletes only for the author: $1 slug, $2 viewer.
pub static ARTICLE_DELETE: Stmt =
    Stmt::write("DELETE FROM articles WHERE slug = $1 AND author_id = $2", &[TEXT, INT8]);
pub static FAVORITE: Stmt = Stmt::write(
    "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 \
     ON CONFLICT DO NOTHING",
    &[INT8, TEXT],
);
pub static UNFAVORITE: Stmt = Stmt::write(
    "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
    &[INT8, TEXT],
);

pub static TAGS: Stmt = Stmt::read("SELECT name FROM tags ORDER BY name", &[]);

// ---- comments ----

pub static ARTICLE_EXISTS: Stmt = Stmt::read("SELECT 1 FROM articles WHERE slug = $1", &[TEXT]);
/// The newest 100 comments: $1 viewer, $2 slug.
pub static COMMENTS: Stmt = Stmt::read(
    "SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, \
     EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
     FROM comments c JOIN articles a ON a.id = c.article_id JOIN users u ON u.id = c.author_id \
     WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC LIMIT 100",
    &[INT8, TEXT],
);
/// No row for an unknown slug. The author is the viewer, who doesn't follow themselves.
pub static COMMENT_INSERT: Stmt = Stmt::write(
    "WITH a AS (SELECT id FROM articles WHERE slug = $1), \
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a \
           RETURNING id, created_at, updated_at, body, author_id) \
     SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, false AS following \
     FROM c JOIN users u ON u.id = c.author_id",
    &[TEXT, INT8, TEXT],
);
/// $1 comment id, $2 slug.
pub static COMMENT_AUTHOR: Stmt = Stmt::read(
    "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2",
    &[INT8, TEXT],
);
/// Deletes only for the author: $1 comment id, $2 slug, $3 viewer.
pub static COMMENT_DELETE: Stmt = Stmt::write(
    "DELETE FROM comments c USING articles a \
     WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3",
    &[INT8, TEXT, INT8],
);
