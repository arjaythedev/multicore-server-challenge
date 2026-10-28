WITH q AS MATERIALIZED (
  SELECT r.ord, r.v, a.id AS aid, min(r.ord) OVER w AS lead, count(*) OVER w AS n
  FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, s, ord)
  JOIN articles a ON a.slug = r.s
  WINDOW w AS (PARTITION BY a.id))
SELECT NULL::int8, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::text, NULL::bool,
 NULL::bool, NULL::int8, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v), q.lead, q.ord
FROM q
UNION ALL
SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, false, true, c.author_id, NULL, q.lead, -q.n
FROM q
LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
                   FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = q.aid
                   ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
WHERE q.ord = q.lead
