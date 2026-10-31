-- Run with: psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f test/sql/feed_check.sql
-- The batch query below mirrors Stmt.FEED_BATCH. Empty databases produce fewer samples.
BEGIN ISOLATION LEVEL REPEATABLE READ;

CREATE TEMP TABLE feed_samples ON COMMIT DROP AS
WITH follow_counts AS MATERIALIZED (
    SELECT u.id, count(f.followee_id) AS follows
    FROM users u LEFT JOIN follows f ON f.follower_id = u.id
    GROUP BY u.id
), choices AS (
    (SELECT id, 1 AS priority FROM follow_counts ORDER BY follows, id LIMIT 250)
    UNION ALL
    (SELECT id, 2 FROM follow_counts ORDER BY follows DESC, id LIMIT 250)
    UNION ALL
    (SELECT id, 3 FROM follow_counts ORDER BY md5(id::text) LIMIT 2000)
), selected AS (
    SELECT id, min(priority) AS priority FROM choices GROUP BY id
), viewers AS (
    SELECT 0::bigint AS viewer, 0 AS priority
    UNION ALL
    (SELECT id, priority FROM selected ORDER BY priority, md5(id::text) LIMIT 1999)
)
SELECT row_number() OVER (ORDER BY priority, viewer)::int AS sample_id, viewer,
       (ARRAY[1, 20, 100])[(row_number() OVER (ORDER BY priority, viewer) % 3 + 1)::int] AS lim,
       (ARRAY[0, 1, 20, 100, 1000])[(row_number() OVER (ORDER BY priority, viewer) % 5 + 1)::int] AS off
FROM viewers;

CREATE TEMP TABLE feed_actual ON COMMIT DROP AS
WITH batches AS MATERIALIZED (
    SELECT (sample_id - 1) / 32 AS batch,
           array_agg(viewer ORDER BY sample_id) AS viewers,
           array_agg(lim ORDER BY sample_id) AS limits,
           array_agg(off ORDER BY sample_id) AS offsets
    FROM feed_samples GROUP BY (sample_id - 1) / 32
)
SELECT b.batch * 32 + q.i AS sample_id,
       array_agg(q.id ORDER BY q.id DESC) FILTER (WHERE q.id IS NOT NULL) AS ids,
       min(q.n) AS n
FROM batches b CROSS JOIN LATERAL (
    WITH r AS MATERIALIZED (
        SELECT * FROM unnest(b.viewers, b.limits, b.offsets) WITH ORDINALITY AS r(viewer, lim, off, i)
    ), hubs AS MATERIALIZED (
        SELECT fo.followee_id AS fid, count(*) AS c, max(r.lim::bigint + r.off::bigint) AS depth
        FROM r JOIN follows fo ON fo.follower_id = r.viewer
        GROUP BY fo.followee_id ORDER BY count(*) DESC, fo.followee_id LIMIT 32
    ), hub_floors AS MATERIALIZED (
        SELECT h.fid, (
            SELECT a.id FROM articles a WHERE a.author_id = h.fid
            ORDER BY a.id DESC OFFSET h.depth - 1 LIMIT 1
        ) AS floor_id FROM hubs h
    ), prolific AS MATERIALIZED (
        SELECT c.fid AS followee_id, EXISTS (
            SELECT 1 FROM articles a WHERE a.author_id = c.fid
            ORDER BY a.id DESC OFFSET 999 LIMIT 1
        ) AS proven FROM (SELECT fid FROM hubs ORDER BY c DESC, fid LIMIT 4) c
    )
    SELECT r.i::int AS i, q.*
    FROM r CROSS JOIN LATERAL (
        WITH page AS (
            SELECT id FROM (
                SELECT x.id FROM (
                    SELECT COALESCE(max(hf.floor_id), 0::bigint) AS f FROM hub_floors hf
                    JOIN follows fh ON fh.follower_id = r.viewer AND fh.followee_id = hf.fid
                ) fl CROSS JOIN follows fo CROSS JOIN LATERAL (
                    SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id AND a2.id >= fl.f
                    ORDER BY a2.id DESC LIMIT (r.lim::bigint + r.off::bigint)
                ) x WHERE fo.follower_id = r.viewer
                ORDER BY x.id DESC LIMIT r.lim OFFSET r.off
            ) pg LIMIT 100
        ), cnt AS (
            SELECT CASE WHEN EXISTS (
                SELECT 1 FROM prolific c JOIN follows fo
                  ON fo.follower_id = r.viewer AND fo.followee_id = c.followee_id
                WHERE c.proven
            ) THEN 1000::bigint ELSE (
                SELECT count(*) FROM (
                    SELECT 1 FROM articles a WHERE a.author_id IN (
                        SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.viewer
                    ) LIMIT 1000
                ) s
            ) END AS n
        )
        SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name),
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
               EXISTS(SELECT 1 FROM favorites f WHERE f.user_id = r.viewer AND f.article_id = a.id),
               u.username, u.bio, u.image,
               EXISTS(SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = a.author_id), cnt.n
        FROM cnt LEFT JOIN page p ON true LEFT JOIN articles a ON a.id = p.id
        LEFT JOIN users u ON u.id = a.author_id ORDER BY a.id DESC
    ) q ORDER BY r.i, q.id DESC
) q GROUP BY b.batch, q.i;

WITH reference AS (
    SELECT s.sample_id, s.viewer, s.lim, s.off,
           ARRAY(SELECT a.id FROM articles a JOIN users u ON u.id = a.author_id
                 WHERE a.id IN (
                     SELECT x.id FROM follows fo CROSS JOIN LATERAL (
                         SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                         ORDER BY a2.id DESC LIMIT (s.lim::bigint + s.off::bigint)
                     ) x WHERE fo.follower_id = s.viewer
                     ORDER BY x.id DESC LIMIT s.lim OFFSET s.off
                 ) ORDER BY a.id DESC) AS ids,
           (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (
               SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = s.viewer
           ) LIMIT 1000) c) AS n
    FROM feed_samples s
), mismatches AS (
    SELECT r.sample_id, r.viewer, r.lim, r.off, r.ids AS expected_ids,
           coalesce(a.ids, ARRAY[]::bigint[]) AS actual_ids, r.n AS expected_count, a.n AS actual_count
    FROM reference r LEFT JOIN feed_actual a USING (sample_id)
    WHERE a.sample_id IS NULL OR r.ids IS DISTINCT FROM coalesce(a.ids, ARRAY[]::bigint[])
       OR r.n IS DISTINCT FROM a.n
)
SELECT * FROM mismatches ORDER BY sample_id;

SELECT count(*) AS sampled_viewers FROM feed_samples;
ROLLBACK;
