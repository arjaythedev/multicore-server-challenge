-- GET /api/user: the token's user; a token for a user that doesn't exist is a 401.
SELECT CASE WHEN u.email IS NULL THEN 401 ELSE 200 END AS status,
       CASE WHEN u.email IS NULL THEN '{"errors":{"body":["user not found"]}}' ELSE {{_user}} END AS body
  FROM (SELECT 1) one
  LEFT JOIN (SELECT email, :token::text AS token, username, bio, image FROM users WHERE id = :viewer::bigint) u ON true
