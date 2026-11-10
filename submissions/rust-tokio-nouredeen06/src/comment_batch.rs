//! Share comment-thread reads only among requests already waiting for execution.
//! The database takes a fresh snapshot for each execution. Viewer-specific follow
//! sets are read independently, and no rows or request arguments survive the cohort.
use tokio_postgres::{Statement, types::Type};

use crate::read_batch::Batch;

pub async fn prepare(
    client: &tokio_postgres::Client,
    original: &Statement,
) -> Result<Batch, tokio_postgres::Error> {
    let types = &[Type::INT8_ARRAY, Type::TEXT_ARRAY];
    Ok(Batch {
        original: original.clone(),
        statement: client.prepare_typed(PLAIN, types).await?,
        shared: Some(client.prepare_typed(SHARED, types).await?),
        broadcast: false,
    })
}

// MATERIALIZED keeps the follow-set lookup outside the comment-row loop. With a
// correlated IN subquery in the outer SELECT it can otherwise run 100 times.
const PLAIN: &str = r#"
WITH requests AS MATERIALIZED (
 SELECT r.*, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer) AS followees
 FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, ord)
)
SELECT a.id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
 COALESCE(c.author_id = ANY(r.followees), false), r.ord::bigint AS __request_id
FROM requests r
JOIN articles a ON a.slug = r.slug
LEFT JOIN LATERAL (
 SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
 WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100
) c ON true
LEFT JOIN users u ON u.id = c.author_id
ORDER BY r.ord, c.created_at DESC, c.id DESC
"#;

// A missing article produces no rows (404), while an existing empty article
// produces a sentinel with its id and NULL comment fields ([]). Timestamp + id
// ordering and the per-thread 100-comment bound match the reference query.
const SHARED: &str = r#"
WITH requests AS MATERIALIZED (
 SELECT r.*, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer) AS followees
 FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, ord)
), threads AS MATERIALIZED (
 SELECT k.slug, a.id AS article_id, c.id, c.body, c.created_at, c.updated_at,
 c.author_id, u.username, u.bio, u.image
 FROM (SELECT DISTINCT slug FROM requests) k
 JOIN articles a ON a.slug = k.slug
 LEFT JOIN LATERAL (
  SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
  WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100
 ) c ON true
 LEFT JOIN users u ON u.id = c.author_id
)
SELECT t.article_id, t.id, t.body, t.created_at, t.updated_at, t.username, t.bio, t.image,
 COALESCE(t.author_id = ANY(r.followees), false), r.ord::bigint AS __request_id
FROM requests r JOIN threads t ON t.slug = r.slug
ORDER BY r.ord, t.created_at DESC, t.id DESC
"#;
