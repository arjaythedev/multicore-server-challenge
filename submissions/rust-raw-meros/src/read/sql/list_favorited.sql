-- Favorited list. The key is the username whose favorites are listed.
-- $1 viewer int8[], $2 limit int8[], $3 offset int8[], $4 key text[] (one entry per request).
-- Output (shape "articles", see read/articles.rs): article rows (kind 0) once per distinct article, then one row per
-- request (kind 1) with its capped count, page ids in order, the page ids the viewer favorited, and the ids the viewer
-- follows (ALL of the viewer's followees, a superset of the page's authors: the renderer only tests membership, and
-- one index scan of ~20 entries is much cheaper than intersecting with the batch's article rows once per request).
-- The count is min(n, 1000): probe for a 1000th row with OFFSET 999 (a bare scan, no aggregate on top) and count
-- only when there is none (see list_tag.sql for the measurement).
WITH req AS MATERIALIZED (
  SELECT r.viewer, r.lim, r.off, r.key, r.ord
    FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(viewer, lim, off, key, ord)),
pages AS MATERIALIZED (
  SELECT k.key, k.lim, k.off, p.id
    FROM (SELECT DISTINCT key, lim, off FROM req) k
   CROSS JOIN LATERAL (SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = k.key) ORDER BY f.article_id DESC LIMIT k.lim OFFSET k.off) p),
totals AS MATERIALIZED (
  SELECT k.key, c.n
    FROM (SELECT DISTINCT key FROM req) k
  LEFT JOIN LATERAL (SELECT fu.id FROM users fu WHERE fu.username = k.key) uf ON true
   CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = uf.id OFFSET 999 LIMIT 1)
                                   THEN 1000::int8
                                   ELSE (SELECT count(*) FROM favorites f2 WHERE f2.user_id = uf.id) END AS n) c),
ids AS MATERIALIZED (SELECT DISTINCT id FROM pages),
art AS MATERIALIZED (
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT at.tag_id::int8 FROM article_tags at WHERE at.article_id = a.id) AS tag_ids,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fav,
         u.username, u.bio, u.image
    FROM ids
    JOIN articles a ON a.id = ids.id
    JOIN users u ON u.id = a.author_id)
SELECT 0::int4 AS kind, NULL::int8 AS ord, id, slug, title, description, NULL::text AS body, created_at, updated_at,
       author_id, tag_ids, fav, username, bio, image,
       NULL::int8 AS total, NULL::int8[] AS page_ids, NULL::int8[] AS favorited_ids, NULL::int8[] AS followed_ids
  FROM art
UNION ALL
SELECT 1, r.ord, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       t.n, COALESCE(pg.ids, '{}'::int8[]),
       CASE WHEN r.viewer = 0 OR pg.ids IS NULL THEN '{}'::int8[]
            ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = ANY(pg.ids)) END,
       CASE WHEN r.viewer = 0 OR pg.ids IS NULL THEN '{}'::int8[]
            ELSE ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer) END
  FROM req r
  JOIN totals t ON t.key = r.key
 CROSS JOIN LATERAL (SELECT array_agg(p.id ORDER BY p.id DESC) AS ids FROM pages p
                      WHERE p.key = r.key AND p.lim = r.lim AND p.off = r.off) pg
