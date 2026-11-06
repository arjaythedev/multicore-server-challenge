-- Author list. The key is the author's username; an unknown user gives an empty page and a zero count.
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
   CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = k.key) ORDER BY a2.id DESC LIMIT k.lim OFFSET k.off) p),
totals AS MATERIALIZED (
  SELECT k.key, c.n
    FROM (SELECT DISTINCT key FROM req) k
  LEFT JOIN LATERAL (SELECT au.id FROM users au WHERE au.username = k.key) ua ON true
   CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = ua.id OFFSET 999 LIMIT 1)
                                   THEN 1000::int8
                                   ELSE (SELECT count(*) FROM articles a4 WHERE a4.author_id = ua.id) END AS n) c),
-- One array of page ids per distinct (key, limit, offset), joined to the requests by hash: looking each request's
-- page up with a scan of `pages` costs time proportional to the square of the batch size.
pa AS MATERIALIZED (
  SELECT p.key, p.lim, p.off, array_agg(p.id ORDER BY p.id DESC) AS ids FROM pages p GROUP BY p.key, p.lim, p.off),
ids AS MATERIALIZED (SELECT DISTINCT id FROM pages),
art AS MATERIALIZED (
  SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id,
         COALESCE(t.tag_ids, '{}'::int8[]) AS tag_ids, COALESCE(f.n, 0) AS fav,
         u.username, u.bio, u.image
    FROM articles a
    JOIN users u ON u.id = a.author_id
    LEFT JOIN (SELECT at.article_id, array_agg(at.tag_id::int8) AS tag_ids FROM article_tags at
                WHERE at.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY at.article_id) t ON t.article_id = a.id
    LEFT JOIN (SELECT fv.article_id, count(*) AS n FROM favorites fv
                WHERE fv.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY fv.article_id) f ON f.article_id = a.id
   WHERE a.id = ANY(ARRAY(SELECT id FROM ids)))
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
 LEFT JOIN pa pg ON pg.key = r.key AND pg.lim = r.lim AND pg.off = r.off
