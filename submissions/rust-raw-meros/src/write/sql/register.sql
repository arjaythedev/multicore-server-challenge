-- POST /api/users. $1 username text, $2 email text, $3 password_hash text.
-- No row back = a unique violation (username or email taken) = 422. ON CONFLICT keeps the group's transaction alive.
INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING
RETURNING id, username, email, bio, image
