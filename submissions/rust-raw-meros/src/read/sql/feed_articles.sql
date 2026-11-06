-- Personal feed, phase B: the article rows of the pages that phase A (feed_lists.sql) let the caller merge.
-- $1 viewer, $2 limit, $3 offset, $4 total (the capped count from phase A), $5 start, $6 count (one entry per
-- request, in request order); $7 ids int8[] (the pages' ids back to back, newest first within a page).
-- A request's page is ids[start : start + count - 1] (start is 1-based). count = -1 marks a deep request (limit +
-- offset above the cap): its page is computed here, from the reference ordering (per followee the newest
-- limit + offset articles, then the newest `limit` after `offset` of those).
-- Output (shape "articles", see read/articles.rs): article rows (kind 0) once per distinct article, then one row per
-- request (kind 1) with its total, page ids in order and the page ids the viewer favorited. followed_ids is always
-- empty: the renderer marks every author of a feed as followed without looking.
WITH req AS MATERIALIZED (
  SELECT r.viewer, r.lim, r.off, r.total, r.start, r.cnt, r.ord
    FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::int8[], $5::int8[], $6::int8[])
         WITH ORDINALITY AS r(viewer, lim, off, total, start, cnt, ord)),
pg AS MATERIALIZED (
  SELECT q.ord,
         CASE WHEN q.cnt >= 0 THEN ($7::int8[])[q.start : q.start + q.cnt - 1]
              ELSE ARRAY(SELECT x.id FROM follows fo
                          CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (q.lim + q.off)) x
                         WHERE fo.follower_id = q.viewer ORDER BY x.id DESC LIMIT q.lim OFFSET q.off) END AS ids
    FROM req q),
ids AS MATERIALIZED (SELECT DISTINCT unnest(ids) AS id FROM pg),
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
       r.total, pg.ids,
       CASE WHEN r.viewer = 0 OR cardinality(pg.ids) = 0 THEN '{}'::int8[]
            ELSE ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = ANY(pg.ids)) END,
       '{}'::int8[]
  FROM req r
  JOIN pg ON pg.ord = r.ord
