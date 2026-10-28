-- DELETE /api/profiles/:username/follow. $1 viewer int8, $2 username text. Returns the profile (no row = 404).
WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2),
     w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM t))
SELECT id, username, bio, image FROM t
