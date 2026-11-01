-- Comment threads by slug, many requests at once: the newest 100 comments once per distinct slug.
-- $1 viewer int8[], $2 slug text[].
-- Output (shape "comments"): kind 0 = a comment (article_id, comment fields, author fields); kind 1 = a request
-- (ord, article_id or NULL when the slug does not exist: 404, and the ids the viewer follows: ALL of the viewer's
-- followees, a superset of the thread's authors, because the renderer only tests membership and one index scan of ~20
-- entries is much cheaper than intersecting with the batch's comment rows once per request).
WITH req AS MATERIALIZED (
  SELECT r.viewer, r.slug, r.ord
    FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, ord)),
arts AS MATERIALIZED (
  SELECT a.id AS article_id, a.slug
    FROM (SELECT DISTINCT slug FROM req) s
    JOIN articles a ON a.slug = s.slug),
thread AS MATERIALIZED (
  SELECT x.article_id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
    FROM arts x
   CROSS JOIN LATERAL (SELECT c2.id, c2.body, c2.created_at, c2.updated_at, c2.author_id
                         FROM comments c2 WHERE c2.article_id = x.article_id
                        ORDER BY c2.created_at DESC, c2.id DESC LIMIT 100) c
    JOIN users u ON u.id = c.author_id)
SELECT 0::int4 AS kind, NULL::int8 AS ord, article_id, id, body, created_at, updated_at, author_id, username, bio, image,
       NULL::int8[] AS followed_ids
  FROM thread
UNION ALL
SELECT 1, r.ord, a.article_id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       CASE WHEN r.viewer = 0 OR a.article_id IS NULL THEN '{}'::int8[]
            ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer) END
  FROM req r
  LEFT JOIN arts a ON a.slug = r.slug
