-- GET /api/articles/feed: newest articles by the users the viewer follows.
WITH ids AS (
  SELECT x.id FROM follows fo CROSS JOIN LATERAL
         (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
           ORDER BY a2.id DESC LIMIT (:page_limit::int + :page_offset::int)) x
   WHERE fo.follower_id = :viewer::bigint
   ORDER BY x.id DESC LIMIT :page_limit::int OFFSET :page_offset::int)
SELECT 200 AS status,
       jsonb_build_object(
         'articles', coalesce((SELECT jsonb_agg({{_article}} - 'body' ORDER BY a.id DESC)
                                 FROM articles a JOIN users u ON u.id = a.author_id
                                WHERE a.id IN (SELECT id FROM ids)), '[]'),
         'articlesCount',
           (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
              (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = :viewer::bigint) LIMIT 1000) s)
       )::text AS body
