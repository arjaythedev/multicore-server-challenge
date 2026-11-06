-- A run of favorite / unfavorite requests in one statement (see batch.rs for when a run may be sent like this).
-- $1 viewers int8[], $2 slugs text[], $3 flags int8[] (1 = favorite, 0 = unfavorite); equal lengths, element i is job i.
-- Precondition (checked in Rust): no (viewer, slug) pair occurs twice, so the writes of the jobs are independent of
-- each other and each one succeeds or is a no-op exactly as if it ran alone.
-- Output: one row per job, in job order, shape "article_full" (id NULL = no such article = 404).
-- "fav" of job i is what the sequential statements would have shown: the count before the run, plus the rows the jobs
-- up to and including i wrote to the same article (running sum over the job order). "favorited" is the job's flag.
-- Article, tags and author are read once per distinct article, not once per job.
WITH j AS (
  SELECT j.ord, j.viewer, j.flag, a.id AS article_id
    FROM unnest($1::int8[], $2::text[], $3::int8[]) WITH ORDINALITY AS j(viewer, slug, flag, ord)
    LEFT JOIN articles a ON a.slug = j.slug),
ins AS (INSERT INTO favorites (user_id, article_id)
        SELECT viewer, article_id FROM j WHERE flag = 1 AND article_id IS NOT NULL
        ON CONFLICT DO NOTHING RETURNING user_id, article_id),
del AS (DELETE FROM favorites f USING j
         WHERE j.flag = 0 AND f.user_id = j.viewer AND f.article_id = j.article_id
        RETURNING f.user_id, f.article_id),
d AS (
  SELECT j.ord, j.viewer, j.flag, j.article_id,
         sum(CASE WHEN ins.user_id IS NOT NULL THEN 1 WHEN del.user_id IS NOT NULL THEN -1 ELSE 0 END)
           OVER (PARTITION BY j.article_id ORDER BY j.ord) AS delta
    FROM j
    LEFT JOIN ins ON ins.user_id = j.viewer AND ins.article_id = j.article_id
    LEFT JOIN del ON del.user_id = j.viewer AND del.article_id = j.article_id),
art AS (
  SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
         ARRAY(SELECT t2.name FROM article_tags at JOIN tags t2 ON t2.id = at.tag_id WHERE at.article_id = a.id ORDER BY t2.name) AS tag_names,
         (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fav,
         u.username, u.bio, u.image
    FROM (SELECT DISTINCT article_id FROM j WHERE article_id IS NOT NULL) x
    JOIN articles a ON a.id = x.article_id JOIN users u ON u.id = a.author_id)
SELECT art.id, art.slug, art.title, art.description, art.body, art.created_at, art.updated_at, art.author_id,
       art.tag_names, art.fav + d.delta AS fav, d.flag = 1 AS favorited,
       art.username, art.bio, art.image,
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = d.viewer AND fo.followee_id = art.author_id) AS following
  FROM d LEFT JOIN art ON art.id = d.article_id
 ORDER BY d.ord
