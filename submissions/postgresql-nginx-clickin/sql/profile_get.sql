-- GET /api/profiles/:username, in one statement: who is asking (401), then the profile (404).
WITH auth AS MATERIALIZED ({{_auth}})
SELECT coalesce(auth.status, CASE WHEN u.id IS NULL THEN 404 ELSE 200 END) AS status,
       CASE WHEN auth.status IS NOT NULL THEN auth.body
            WHEN u.id IS NULL THEN '{"errors":{"body":["profile not found"]}}'
            ELSE jsonb_build_object('profile', jsonb_build_object(
                   'username', u.username, 'bio', u.bio, 'image', u.image,
                   'following', EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = auth.viewer AND fo.followee_id = u.id)))::text
       END AS body
  FROM auth LEFT JOIN users u ON auth.status IS NULL AND u.username = :username::text
