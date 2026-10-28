-- PUT /api/user. $1 id int8, $2 email text, $3 username text, $4 password_hash text, $5 bio text, $6 image text.
-- NULL parameters leave the column unchanged. A unique violation raises an error: the group is retried statement by
-- statement and this one ends as 422.
UPDATE users
   SET email = COALESCE($2, email), username = COALESCE($3, username),
       password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
 WHERE id = $1
RETURNING id, username, email, bio, image
