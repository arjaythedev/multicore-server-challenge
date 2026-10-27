pub const get_sql =
    \\SELECT u.id, u.username, u.bio, u.image,
    \\       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
    \\  FROM users u WHERE u.username = $2
;

pub const follow_sql =
    \\WITH target AS MATERIALIZED (
    \\    SELECT id, username, bio, image FROM users WHERE username = $2
    \\), changed AS (
    \\    INSERT INTO follows (follower_id, followee_id)
    \\    SELECT $1::bigint, id FROM target ON CONFLICT DO NOTHING
    \\    RETURNING followee_id
    \\)
    \\SELECT t.id, t.username, t.bio, t.image, true AS following
    \\  FROM target t CROSS JOIN (SELECT count(*) FROM changed) applied
;

pub const unfollow_sql =
    \\WITH target AS MATERIALIZED (
    \\    SELECT id, username, bio, image FROM users WHERE username = $2
    \\), changed AS (
    \\    DELETE FROM follows fo USING target t
    \\     WHERE fo.follower_id = $1::bigint AND fo.followee_id = t.id
    \\    RETURNING fo.followee_id
    \\)
    \\SELECT t.id, t.username, t.bio, t.image, false AS following
    \\  FROM target t CROSS JOIN (SELECT count(*) FROM changed) applied
;

pub const Profile = struct { username: []const u8, bio: ?[]const u8, image: ?[]const u8, following: bool };
