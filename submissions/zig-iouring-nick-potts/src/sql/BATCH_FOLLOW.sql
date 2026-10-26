WITH r AS (SELECT * FROM unnest($1::bigint[], $2::text[]) WITH ORDINALITY AS r(v, uname, ord)),
 t AS (SELECT r.ord, r.v, u.id, u.username, u.bio, u.image FROM r
       CROSS JOIN LATERAL (SELECT id, username, bio, image FROM users WHERE username = r.uname) u),
 w AS (INSERT INTO follows (follower_id, followee_id) SELECT v, id FROM t ON CONFLICT DO NOTHING)
SELECT username, bio, image, ord FROM t
