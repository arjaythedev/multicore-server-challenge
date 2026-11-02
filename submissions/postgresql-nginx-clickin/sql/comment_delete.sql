-- DELETE /api/articles/:slug/comments/:id: a non-integer id is a 404, like an unknown one.
WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
            WHERE :comment_id::text ~ '^[0-9]{1,18}$'
              AND c.id = CASE WHEN :comment_id::text ~ '^[0-9]{1,18}$' THEN :comment_id::text::bigint END
              AND a.slug = :slug::text),
     d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = :viewer::bigint))
SELECT CASE WHEN c.id IS NULL THEN 404 WHEN c.author_id <> :viewer::bigint THEN 403 ELSE 204 END AS status,
       CASE WHEN c.id IS NULL THEN '{"errors":{"body":["comment not found"]}}'
            WHEN c.author_id <> :viewer::bigint THEN '{"errors":{"body":["only the author can delete a comment"]}}' END AS body
  FROM (SELECT 1) one LEFT JOIN c ON true
