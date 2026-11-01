-- POST /api/articles/:slug/comments. $1 slug text, $2 viewer int8, $3 body text.
-- Output, one row: article_id (NULL = no such article = 404), then the new comment and its author.
WITH a AS (SELECT id FROM articles WHERE slug = $1),
     c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a
           RETURNING id, body, created_at, updated_at, author_id)
SELECT (SELECT id FROM a) AS article_id, c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
  FROM (SELECT 1) one
  LEFT JOIN c ON true
  LEFT JOIN users u ON u.id = c.author_id
