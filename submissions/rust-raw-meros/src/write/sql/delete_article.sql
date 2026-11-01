-- DELETE /api/articles/:slug. $1 slug text, $2 viewer int8.
-- Output, one row: found_id (NULL = 404), found_author, deleted_id (NULL = not the author = 403).
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
     d AS (DELETE FROM articles a USING t WHERE a.id = t.id AND a.author_id = $2 RETURNING a.id)
SELECT (SELECT id FROM t) AS found_id, (SELECT author_id FROM t) AS found_author, (SELECT id FROM d) AS deleted_id
