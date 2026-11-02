-- GET /api/user, in one statement: who is asking (401), then that user (a token for a user that doesn't exist is
-- a 401 too).
WITH auth AS MATERIALIZED ({{_auth}})
SELECT coalesce(auth.status, CASE WHEN u.email IS NULL THEN 401 ELSE 200 END) AS status,
       CASE WHEN auth.status IS NOT NULL THEN auth.body
            WHEN u.email IS NULL THEN '{"errors":{"body":["user not found"]}}' ELSE {{_user}} END AS body
  FROM auth
  LEFT JOIN (SELECT id, email, username, bio, image FROM users) u0 ON auth.status IS NULL AND u0.id = auth.viewer
  CROSS JOIN LATERAL (SELECT u0.email, auth.token, u0.username, u0.bio, u0.image) u
