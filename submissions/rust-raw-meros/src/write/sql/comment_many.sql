-- A run of add-comment requests in one statement. $1 slugs text[], $2 viewers int8[], $3 bodies text[]; element i is job i.
-- Comment ids are taken from the identity sequence in job order, so the ids rise with the job order exactly as
-- they would for one statement per job. created_at / updated_at are the column defaults (now()), i.e. the values the
-- stored rows have; they are not read back.
-- Output: one row per job, in job order: article_id (NULL = no such article = 404), id, body, created_at,
-- updated_at, username, bio, image of the author (the viewer).
WITH j AS (
  SELECT j.ord, j.viewer, j.body, a.id AS article_id
    FROM unnest($1::text[], $2::int8[], $3::text[]) WITH ORDINALITY AS j(slug, viewer, body, ord)
    LEFT JOIN articles a ON a.slug = j.slug),
n AS (
  SELECT s.ord, s.viewer, s.body, s.article_id,
         nextval((SELECT pg_get_serial_sequence('comments', 'id'))::regclass) AS id
    FROM (SELECT ord, viewer, body, article_id FROM j WHERE article_id IS NOT NULL ORDER BY ord) s),
w AS (INSERT INTO comments (id, article_id, author_id, body) SELECT id, article_id, viewer, body FROM n)
SELECT j.article_id, n.id, j.body, now() AS created_at, now() AS updated_at, u.username, u.bio, u.image
  FROM j LEFT JOIN n ON n.ord = j.ord
  LEFT JOIN users u ON u.id = n.viewer
 ORDER BY j.ord
