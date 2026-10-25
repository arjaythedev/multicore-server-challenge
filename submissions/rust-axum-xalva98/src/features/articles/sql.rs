//! The article statements. `$1` is always the viewer. A list cuts its page of ids first, so the per-article
//! columns run only for the rows it returns, and its capped count rides in the same statement.

// One primary-key lookup per tag: as a join, the generic plan hashes all 200 tags for every article.
macro_rules! tag_list {
    () => {
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                 FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list"
    };
}

macro_rules! favorites_count {
    () => {
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
    };
}

macro_rules! author {
    () => {
        "u.username, u.bio, u.image,
         EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following"
    };
}

/// Every column of the full article except the two favorites columns, which a favorite change computes itself.
macro_rules! full_columns_with {
    ($favorites_count:expr, $favorited:expr) => {
        concat!(
            "a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ",
            $crate::features::articles::sql::tag_list!(),
            ", ",
            $favorites_count,
            " AS favorites_count, ",
            $favorited,
            " AS favorited, ",
            $crate::features::articles::sql::author!()
        )
    };
}

macro_rules! slugify {
    ($param:literal) => {
        concat!("trim(both '-' from lower(regexp_replace(", $param, ", '[^A-Za-z0-9]+', '-', 'g')))")
    };
}

pub(crate) use {author, favorites_count, full_columns_with, tag_list};

macro_rules! list_columns {
    () => {
        concat!(
            "a.slug, a.title, a.description, NULL::text AS body, a.created_at, a.updated_at, ",
            tag_list!(),
            ", ",
            favorites_count!(),
            " AS favorites_count,
             EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, ",
            author!()
        )
    };
}

macro_rules! page_of {
    ($ids:literal, $count:expr) => {
        concat!(
            "SELECT ",
            list_columns!(),
            ", (",
            $count,
            ") AS articles_count
               FROM (",
            $ids,
            ") p
               JOIN articles a ON a.id = p.id
               JOIN users u ON u.id = a.author_id
              ORDER BY a.id DESC"
        )
    };
}

// Counts walk their index from the oldest end: those pages are all-visible, so no heap fetches.
macro_rules! count_all {
    () => {
        "SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s"
    };
}

macro_rules! count_tag {
    ($tag:literal) => {
        concat!(
            "SELECT count(*) FROM (SELECT 1 FROM article_tags at
                WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ",
            $tag,
            ") ORDER BY at.article_id LIMIT 1000) s"
        )
    };
}

macro_rules! count_author {
    ($author:literal) => {
        concat!(
            "SELECT count(*) FROM (SELECT 1 FROM articles a2
                WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = ",
            $author,
            ") ORDER BY a2.id LIMIT 1000) s"
        )
    };
}

macro_rules! count_favorited {
    ($username:literal) => {
        concat!(
            "SELECT count(*) FROM (SELECT 1 FROM favorites f
                WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ",
            $username,
            ") ORDER BY f.article_id LIMIT 1000) s"
        )
    };
}

macro_rules! count_feed {
    () => {
        "SELECT count(*) FROM (SELECT 1 FROM articles a2
            WHERE a2.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"
    };
}

pub const LIST_ALL: &str = page_of!("SELECT id FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3", count_all!());
pub const LIST_TAG: &str = page_of!(
    "SELECT at.article_id AS id FROM article_tags at
      WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
      ORDER BY at.article_id DESC LIMIT $2 OFFSET $3",
    count_tag!("$4")
);
pub const LIST_AUTHOR: &str = page_of!(
    "SELECT a2.id FROM articles a2
      WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4)
      ORDER BY a2.id DESC LIMIT $2 OFFSET $3",
    count_author!("$4")
);
pub const LIST_FAVORITED: &str = page_of!(
    "SELECT f.article_id AS id FROM favorites f
      WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)
      ORDER BY f.article_id DESC LIMIT $2 OFFSET $3",
    count_favorited!("$4")
);
pub const LIST_FEED: &str = page_of!(
    "SELECT x.id FROM follows fo CROSS JOIN LATERAL
            (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
              ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
      WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3",
    count_feed!()
);

pub const COUNT_ALL: &str = count_all!();
pub const COUNT_TAG: &str = count_tag!("$1");
pub const COUNT_AUTHOR: &str = count_author!("$1");
pub const COUNT_FAVORITED: &str = count_favorited!("$1");
pub const COUNT_FEED: &str = count_feed!();

pub const BY_SLUG: &str = concat!(
    "SELECT ",
    full_columns_with!(favorites_count!(), "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)"),
    " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"
);
pub const BY_ID: &str = concat!(
    "SELECT ",
    full_columns_with!(favorites_count!(), "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)"),
    " FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2"
);

pub const INSERT: &str = concat!(
    "INSERT INTO articles (id, slug, author_id, title, description, body)
     SELECT n.id, ",
    slugify!("$2"),
    " || '-' || n.id, $1, $2, $3, $4
       FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
     RETURNING id"
);
pub const INSERT_TAGS: &str = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING";
pub const LINK_TAGS: &str =
    "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])";

/// Only the author's own article changes; the row names the author so a stranger gets 403, not 404.
pub const UPDATE: &str = concat!(
    "WITH target AS (SELECT id, author_id FROM articles WHERE slug = $1),
          changed AS (
            UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description),
                   body = COALESCE($5, body),
                   slug = CASE WHEN $3::text IS NULL THEN slug ELSE ",
    slugify!("$3"),
    " || '-' || id END,
                   updated_at = now()
             WHERE id = (SELECT id FROM target WHERE author_id = $2))
     SELECT id, author_id FROM target"
);
pub const DELETE: &str = "WITH target AS (SELECT id, author_id FROM articles WHERE slug = $1),
          removed AS (DELETE FROM articles WHERE id = (SELECT id FROM target WHERE author_id = $2))
     SELECT id, author_id FROM target";

