-- GET /api/articles/feed, in one statement: who is asking (401 when anonymous), ?limit/?offset (422), then the
-- newest articles by the users the viewer follows.
WITH auth AS MATERIALIZED ({{_auth}}),
page AS MATERIALIZED ({{_page}}),
ids AS (
  SELECT x.id FROM follows fo CROSS JOIN LATERAL
         (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
           ORDER BY a2.id DESC LIMIT ((SELECT page_limit FROM page) + (SELECT page_offset FROM page))) x
   WHERE fo.follower_id = (SELECT viewer FROM auth)
   ORDER BY x.id DESC LIMIT (SELECT page_limit FROM page) OFFSET (SELECT page_offset FROM page))
SELECT coalesce(auth.status, page.status, 200) AS status,
       CASE WHEN auth.status IS NOT NULL THEN auth.body
            WHEN page.status IS NOT NULL THEN page.body
            ELSE jsonb_build_object(
              'articles', coalesce((SELECT jsonb_agg({{_article_list}} ORDER BY a.id DESC)
                                      FROM articles a JOIN users u ON u.id = a.author_id
                                     WHERE a.id IN (SELECT id FROM ids)), '[]'),
              'articlesCount',
                (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
                   (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = auth.viewer) LIMIT 1000) s)
            )::text END AS body
  FROM auth, page
