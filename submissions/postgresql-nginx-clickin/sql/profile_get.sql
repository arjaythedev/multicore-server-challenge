-- GET /api/profiles/:username
SELECT CASE WHEN u.id IS NULL THEN 404 ELSE 200 END AS status,
       CASE WHEN u.id IS NULL THEN '{"errors":{"body":["profile not found"]}}'
            ELSE jsonb_build_object('profile', jsonb_build_object(
                   'username', u.username, 'bio', u.bio, 'image', u.image,
                   'following', EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = :viewer::bigint AND fo.followee_id = u.id)))::text
       END AS body
  FROM (SELECT 1) one LEFT JOIN users u ON u.username = :username::text
