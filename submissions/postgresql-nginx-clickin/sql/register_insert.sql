-- POST /api/users, 2/4: the module has put the bcrypt hash of the password in :bcrypt_hash.
-- A taken username or email is a unique violation (23505): 422.
INSERT INTO users (username, email, password_hash) VALUES (:username::text, :email::text, :bcrypt_hash::text)
RETURNING id AS user_id, username, email, bio, image
