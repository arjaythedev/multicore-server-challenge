UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
 password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
WHERE id = $1
RETURNING id, username, email, bio, image