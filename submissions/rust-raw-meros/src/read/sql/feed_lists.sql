-- Personal feed, phase A: the per-followee work of the whole batch, shared between viewers.
-- $1 viewer int8[], $2 limit int8[], $3 offset int8[] (one entry per request), $4 cap int8 (a request whose
-- limit + offset exceeds the cap is "deep": its page is computed by phase B, see feed_articles.sql).
-- Output (read/feed.rs), one column set for two kinds of row:
--   kind 0: id = a followee, ids = that followee's newest articles, newest first, as many as the most demanding
--           shallow viewer who follows them needs (limit + offset); followees without articles are left out;
--   kind 1: ord = request position, ids = the viewer's followee ids, total = the capped count min(n, 1000).
-- A batch of 512 viewers has 10 534 follow rows but only 6 093 distinct followees: one index probe per followee
-- instead of one per follow row. The merge of the followees' lists into pages is done by the caller.
-- The count: probe for a 1000th row with OFFSET 999 (a bare scan, no aggregate on top) and count only when there
-- is none (see list_tag.sql for the measurement).
WITH req AS MATERIALIZED (
  SELECT r.viewer, r.lim + r.off AS need, r.ord
    FROM unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(viewer, lim, off, ord)),
vkeys AS MATERIALIZED (
  SELECT viewer, max(need) FILTER (WHERE need <= $4) AS need FROM req GROUP BY viewer),
fol AS MATERIALIZED (
  SELECT k.viewer, fo.followee_id, k.need FROM vkeys k JOIN follows fo ON fo.follower_id = k.viewer),
fe AS MATERIALIZED (
  SELECT followee_id, max(need) AS need FROM fol WHERE need IS NOT NULL GROUP BY followee_id),
lists AS MATERIALIZED (
  SELECT f.followee_id, ARRAY(SELECT a.id FROM articles a WHERE a.author_id = f.followee_id ORDER BY a.id DESC LIMIT f.need) AS ids
    FROM fe f),
fa AS MATERIALIZED (
  SELECT viewer, array_agg(followee_id) AS ids FROM fol GROUP BY viewer),
-- Authors followed by two or more viewers of this batch, most shared first, that have 1000 articles or more. One
-- such followee proves the viewer's capped count is 1000 without counting (min(n, 1000) = 1000 whenever one
-- author alone has 1000). Most viewers follow one of the few very prolific authors; the proof is computed once per
-- author for the whole batch and dies with it.
shared AS MATERIALIZED (
  SELECT followee_id FROM fol GROUP BY followee_id HAVING count(*) >= 2 ORDER BY count(*) DESC, followee_id LIMIT 16),
big AS MATERIALIZED (
  SELECT s.followee_id FROM shared s
   WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = s.followee_id OFFSET 999 LIMIT 1)),
totals AS MATERIALIZED (
  SELECT k.viewer,
         CASE WHEN EXISTS (SELECT 1 FROM fol f JOIN big b ON b.followee_id = f.followee_id WHERE f.viewer = k.viewer)
              THEN 1000::int8
              WHEN EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = k.viewer) OFFSET 999 LIMIT 1)
              THEN 1000::int8
              ELSE (SELECT count(*) FROM articles a4 WHERE a4.author_id IN (SELECT fo2.followee_id FROM follows fo2 WHERE fo2.follower_id = k.viewer)) END AS n
    FROM vkeys k)
SELECT 0::int4 AS kind, NULL::int8 AS ord, followee_id AS id, ids, NULL::int8 AS total
  FROM lists WHERE cardinality(ids) > 0
UNION ALL
SELECT 1, r.ord, NULL, COALESCE(fa.ids, '{}'::int8[]), t.n
  FROM req r
  JOIN totals t ON t.viewer = r.viewer
  LEFT JOIN fa ON fa.viewer = r.viewer
