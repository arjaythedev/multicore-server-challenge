-- PUT /api/articles/:slug. $1 slug text, $2 viewer int8, $3 title text, $4 description text, $5 body text,
-- $6 new slug base text (used only when the title changes).
-- Output, always one row: found_id (NULL = no such article = 404), found_author, then the updated article in shape
-- "article_full" (NULL columns when the viewer is not the author = 403).
WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1),
     u AS (UPDATE articles a
              SET title = COALESCE($3, a.title), description = COALESCE($4, a.description), body = COALESCE($5, a.body),
                  slug = CASE WHEN $3::text IS NULL THEN a.slug ELSE $6 || '-' || a.id END, updated_at = now()
             FROM t WHERE a.id = t.id AND a.author_id = $2
         RETURNING a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id)
SELECT (SELECT id FROM t) AS found_id, (SELECT author_id FROM t) AS found_author,
       u.id, u.slug, u.title, u.description, u.body, u.created_at, u.updated_at, u.author_id,
       ARRAY(SELECT t2.name FROM article_tags at JOIN tags t2 ON t2.id = at.tag_id WHERE at.article_id = u.id ORDER BY t2.name) AS tag_names,
       (SELECT count(*) FROM favorites f WHERE f.article_id = u.id) AS fav,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = u.id AND f.user_id = $2) AS favorited,
       usr.username, usr.bio, usr.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = u.author_id) AS following
  FROM (SELECT 1) one
  LEFT JOIN u ON true
  LEFT JOIN users usr ON usr.id = u.author_id
