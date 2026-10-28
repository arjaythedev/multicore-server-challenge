-- Profiles by username. $1 viewer int8[], $2 username text[].
-- Output: one row per request in request order: ord, id (NULL when the user does not exist: 404), username, bio,
-- image, following.
SELECT r.ord, u.id, u.username, u.bio, u.image,
       (r.viewer <> 0 AND u.id IS NOT NULL
        AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = u.id)) AS following
  FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(viewer, username, ord)
  LEFT JOIN users u ON u.username = r.username
 ORDER BY r.ord
