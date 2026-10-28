-- DELETE /api/articles/:slug/comments/:id. $1 comment id int8, $2 slug text, $3 viewer int8.
-- Output, one row: found_id (NULL = 404), found_author, deleted_id (NULL = not the author = 403).
WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
            WHERE c.id = $1 AND a.slug = $2),
     d AS (DELETE FROM comments c USING t WHERE c.id = t.id AND c.author_id = $3 RETURNING c.id)
SELECT (SELECT id FROM t) AS found_id, (SELECT author_id FROM t) AS found_author, (SELECT id FROM d) AS deleted_id
