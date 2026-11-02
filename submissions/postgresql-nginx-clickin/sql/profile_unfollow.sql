-- DELETE /api/profiles/:username/follow
WITH u AS (SELECT id, username, bio, image FROM users WHERE username = :username::text),
     f AS (DELETE FROM follows WHERE follower_id = :viewer::bigint AND followee_id = (SELECT id FROM u))
SELECT CASE WHEN u.id IS NULL THEN 404 ELSE 200 END AS status,
       CASE WHEN u.id IS NULL THEN '{"errors":{"body":["profile not found"]}}'
            ELSE jsonb_build_object('profile', jsonb_build_object(
                   'username', u.username, 'bio', u.bio, 'image', u.image, 'following', false))::text END AS body
  FROM (SELECT 1) one LEFT JOIN u ON true
