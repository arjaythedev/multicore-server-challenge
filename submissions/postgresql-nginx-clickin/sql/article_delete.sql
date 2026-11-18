-- DELETE /api/articles/:slug: 404, 403, or 204 with no body.
WITH a AS (SELECT id, author_id FROM articles WHERE slug = :slug::text),
     d AS (DELETE FROM articles WHERE id = (SELECT id FROM a WHERE author_id = :viewer::bigint))
SELECT CASE WHEN a.id IS NULL THEN 404 WHEN a.author_id <> :viewer::bigint THEN 403 ELSE 204 END AS status,
       CASE WHEN a.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            WHEN a.author_id <> :viewer::bigint THEN '{"errors":{"body":["only the author can delete an article"]}}' END AS body
  FROM (SELECT 1) one LEFT JOIN a ON true
