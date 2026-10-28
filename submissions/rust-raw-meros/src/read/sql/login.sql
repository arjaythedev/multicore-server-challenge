-- POST /api/users/login: the stored hash by email. $1 email text[].
-- Output: one row per request in request order: ord, id (NULL when the email is unknown: 401), username, email, bio,
-- image, password_hash.
SELECT r.ord, u.id, u.username, u.email, u.bio, u.image, u.password_hash
  FROM unnest($1::text[]) WITH ORDINALITY AS r(email, ord)
  LEFT JOIN users u ON u.email = r.email
 ORDER BY r.ord
