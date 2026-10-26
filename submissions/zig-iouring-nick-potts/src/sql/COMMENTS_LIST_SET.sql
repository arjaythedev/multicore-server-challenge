SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,
 COALESCE(c.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1), false)
FROM articles a
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
                   FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
WHERE a.slug = $2
