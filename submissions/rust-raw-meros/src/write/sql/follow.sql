-- POST /api/profiles/:username/follow. $1 viewer int8, $2 username text. Returns the profile (no row = 404).
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, t.id FROM t ON CONFLICT DO NOTHING)
SELECT id, username, bio, image FROM t
