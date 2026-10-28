-- Step 4: the article that step 1 created. $1 viewer int8. Output: shape "article_full".
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
       ARRAY(SELECT t2.name FROM article_tags at JOIN tags t2 ON t2.id = at.tag_id WHERE at.article_id = a.id ORDER BY t2.name) AS tag_names,
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fav,
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
       u.username, u.bio, u.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
  FROM articles a JOIN users u ON u.id = a.author_id
 WHERE a.id = currval(pg_get_serial_sequence('articles', 'id'))
