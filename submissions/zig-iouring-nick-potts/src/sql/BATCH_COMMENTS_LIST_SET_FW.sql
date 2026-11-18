WITH q AS MATERIALIZED (
  SELECT r.ord, r.v, a.id AS aid, min(r.ord) OVER w AS lead, count(*) OVER w AS n
  FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY AS r(v, s, ord)
  JOIN articles a ON a.slug = r.s
  WINDOW w AS (PARTITION BY a.id)),
t AS MATERIALIZED (
  SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.author_id, q.lead, q.n
  FROM q
  LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
                     FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = q.aid
                     ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
  WHERE q.ord = q.lead),
au AS MATERIALIZED (
  SELECT t.lead, array_agg(DISTINCT t.author_id ORDER BY t.author_id) FILTER (WHERE t.author_id IS NOT NULL) AS a FROM t GROUP BY t.lead)
SELECT NULL::int8, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::text, NULL::bool,
 NULL::bool, NULL::int8, ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY (au.a)), q.lead, q.ord
FROM q JOIN au ON au.lead = q.lead
UNION ALL
SELECT t.id, t.body, t.created_at, t.updated_at, t.username, t.bio, t.image, false, true, t.author_id, NULL, t.lead, -t.n
FROM t
