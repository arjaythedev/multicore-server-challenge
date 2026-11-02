-- POST /api/articles/:slug/comments, 2/2
WITH a AS (SELECT id FROM articles WHERE slug = :slug::text),
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, :viewer::bigint, :comment_body::text FROM a
           RETURNING id, body, created_at, updated_at, author_id, false AS following)
SELECT CASE WHEN a.id IS NULL THEN 404 ELSE 201 END AS status,
       CASE WHEN a.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE (SELECT jsonb_build_object('comment', {{_comment}})::text FROM c JOIN users u ON u.id = c.author_id) END AS body
  FROM (SELECT 1) one LEFT JOIN a ON true
