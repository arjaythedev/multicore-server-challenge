-- GET /api/user: users by id. $1 id int8[].
-- Output: one row per request in request order: ord, id (NULL when the user does not exist: 401), username, email,
-- bio, image.
SELECT r.ord, u.id, u.username, u.email, u.bio, u.image
  FROM unnest($1::int8[]) WITH ORDINALITY AS r(id, ord)
  LEFT JOIN users u ON u.id = r.id
 ORDER BY r.ord
