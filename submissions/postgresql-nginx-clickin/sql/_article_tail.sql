  'tagList', ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                     FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
  'createdAt', to_char(a.created_at AT TIME ZONE 'UTC', {{_ts}}),
  'updatedAt', to_char(a.updated_at AT TIME ZONE 'UTC', {{_ts}}),
  'favorited', EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = auth.viewer),
  'favoritesCount', (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
  'author', jsonb_build_object(
    'username', u.username, 'bio', u.bio, 'image', u.image,
    'following', EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = auth.viewer AND fo.followee_id = a.author_id))
