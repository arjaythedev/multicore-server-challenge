-- POST /api/articles/:slug/favorite. $1 viewer int8, $2 slug text. Output: shape "article_full" (no row = 404). The statement cannot see its
-- own write, so the count is adjusted by the rows the write touched; "favorited" is a constant.
WITH t AS (SELECT id FROM articles WHERE slug = $2),
     w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING RETURNING 1)
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
       ARRAY(SELECT t2.name FROM article_tags at JOIN tags t2 ON t2.id = at.tag_id WHERE at.article_id = a.id ORDER BY t2.name) AS tag_names,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM w) AS fav, true AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id
