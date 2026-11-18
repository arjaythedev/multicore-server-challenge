-- PUT /api/user, 2/2: :bcrypt_hash is the new password's hash, or NULL when there is none.
WITH u AS (
  UPDATE users SET email = COALESCE(:new_email::text, email), username = COALESCE(:new_username::text, username),
                   password_hash = COALESCE(:bcrypt_hash::text, password_hash),
                   bio = COALESCE(:new_bio::text, bio), image = COALESCE(:new_image::text, image)
   WHERE id = :viewer::bigint
  RETURNING email, :token::text AS token, username, bio, image)
SELECT CASE WHEN u.email IS NULL THEN 401 ELSE 200 END AS status,
       CASE WHEN u.email IS NULL THEN '{"errors":{"body":["user not found"]}}' ELSE {{_user}} END AS body
  FROM (SELECT 1) one LEFT JOIN u ON true
