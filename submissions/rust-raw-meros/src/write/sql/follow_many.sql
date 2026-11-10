-- A run of follow / unfollow requests in one statement (see batch.rs for when a run may be sent like this).
-- $1 viewers int8[], $2 usernames text[], $3 flags int8[] (1 = follow, 0 = unfollow); element i is job i.
-- Precondition (checked in Rust): no (viewer, username) pair occurs twice, so the writes are independent.
-- Output: one row per job, in job order: id, username, bio, image (id NULL = no such user = 404).
WITH j AS (
  SELECT j.ord, j.viewer, j.flag, u.id, u.username, u.bio, u.image
    FROM unnest($1::int8[], $2::text[], $3::int8[]) WITH ORDINALITY AS j(viewer, username, flag, ord)
    LEFT JOIN users u ON u.username = j.username),
ins AS (INSERT INTO follows (follower_id, followee_id)
        SELECT viewer, id FROM j WHERE flag = 1 AND id IS NOT NULL ON CONFLICT DO NOTHING),
del AS (DELETE FROM follows f USING j WHERE j.flag = 0 AND f.follower_id = j.viewer AND f.followee_id = j.id)
SELECT id, username, bio, image FROM j ORDER BY ord
