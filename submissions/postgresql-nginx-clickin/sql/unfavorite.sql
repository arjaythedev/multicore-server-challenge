-- DELETE /api/articles/:slug/favorite, 1/2
WITH a AS (SELECT id FROM articles WHERE slug = :slug::text),
     f AS (DELETE FROM favorites WHERE user_id = :viewer::bigint AND article_id = (SELECT id FROM a))
SELECT CASE WHEN a.id IS NULL THEN 404 END AS status, '{"errors":{"body":["article not found"]}}' AS body,
       a.id AS article_id
  FROM (SELECT 1) one LEFT JOIN a ON true
