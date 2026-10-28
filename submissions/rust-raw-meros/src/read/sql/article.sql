-- Single articles by slug, many requests at once: the article (with body) once per distinct slug.
-- $1 viewer int8[], $2 slug text[]. Output: shape "articles" (same columns as the list statements). Request rows have
-- page_ids = [article id] (empty when the slug does not exist: 404), and favorited_ids / followed_ids of the viewer.
WITH req AS MATERIALIZED (
  SELECT r.viewer, r.slug, r.ord
    FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, slug, ord)),
art AS MATERIALIZED (
  SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT at.tag_id::int8 FROM article_tags at WHERE at.article_id = a.id) AS tag_ids,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fav,
         u.username, u.bio, u.image
    FROM (SELECT DISTINCT slug FROM req) s
    JOIN articles a ON a.slug = s.slug
    JOIN users u ON u.id = a.author_id)
SELECT 0::int4 AS kind, NULL::int8 AS ord, id, slug, title, description, body, created_at, updated_at,
       author_id, tag_ids, fav, username, bio, image,
       NULL::int8 AS total, NULL::int8[] AS page_ids, NULL::int8[] AS favorited_ids, NULL::int8[] AS followed_ids
  FROM art
UNION ALL
SELECT 1, r.ord, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, CASE WHEN a.id IS NULL THEN '{}'::int8[] ELSE ARRAY[a.id] END,
       CASE WHEN r.viewer = 0 OR a.id IS NULL THEN '{}'::int8[]
            ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = a.id) END,
       CASE WHEN r.viewer = 0 OR a.id IS NULL THEN '{}'::int8[]
            ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = a.author_id) END
  FROM req r
  LEFT JOIN art a ON a.slug = r.slug
