-- POST /api/articles/:slug/favorite, 1/2 (article_out.sql answers with the article once this has committed)
WITH a AS (SELECT id FROM articles WHERE slug = :slug::text),
     f AS (INSERT INTO favorites (user_id, article_id) SELECT :viewer::bigint, id FROM a ON CONFLICT DO NOTHING)
SELECT CASE WHEN a.id IS NULL THEN 404 END AS status, '{"errors":{"body":["article not found"]}}' AS body,
       a.id AS article_id
  FROM (SELECT 1) one LEFT JOIN a ON true
