-- POST /api/profiles/:username/follow
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = :username::text),
     f AS (INSERT INTO follows (follower_id, followee_id) SELECT :viewer::bigint, id FROM u ON CONFLICT DO NOTHING)
SELECT CASE WHEN u.id IS NULL THEN 404 ELSE 200 END AS status,
       CASE WHEN u.id IS NULL THEN '{"errors":{"body":["profile not found"]}}'
            ELSE jsonb_build_object('profile', jsonb_build_object(
                   'username', u.username, 'bio', u.bio, 'image', u.image, 'following', true))::text END AS body
  FROM (SELECT 1) one LEFT JOIN u ON true
