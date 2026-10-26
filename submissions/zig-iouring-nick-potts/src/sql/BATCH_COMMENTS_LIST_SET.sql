SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image,
 COALESCE((r.v, c.author_id) IN (SELECT fo.follower_id, fo.followee_id FROM follows fo WHERE fo.follower_id = ANY ($1::int8[])), false),
 r.ord
FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, s, ord)
JOIN articles a ON a.slug = r.s
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
                   FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
