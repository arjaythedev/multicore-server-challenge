-- GET /api/articles/:slug for a batch of requests (one array element per request; one row per request out).
-- Requests for the same article share its lookup; "favorited" and "following" are each request's own.
WITH q AS MATERIALIZED (
  SELECT * FROM unnest(:authorization::text[], :slug::text[]) WITH ORDINALITY AS q(authz, slug, i)),
r AS MATERIALIZED (
  SELECT q.i, q.slug, au.status AS astatus, au.body AS abody, au.viewer FROM q CROSS JOIN LATERAL ({{_jwt}}) au),
m AS MATERIALIZED (
  SELECT a.* FROM (SELECT DISTINCT slug FROM r WHERE astatus IS NULL) d JOIN articles a ON a.slug = d.slug),
ids AS (SELECT id FROM m),
tg AS MATERIALIZED ({{_tags}}),
arts AS MATERIALIZED (
  SELECT a.slug, a.id, a.author_id, {{_art_parts}}, ',"body":' || to_json(a.body)::text AS pb
    FROM m a JOIN users u ON u.id = a.author_id LEFT JOIN tg ON tg.article_id = a.id)
SELECT r.i, coalesce(r.astatus, CASE WHEN ar.id IS NULL THEN 404 ELSE 200 END) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN ar.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE '{"article":' || ar.p1 || ar.pb || ar.p2
                 || EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = ar.id AND f.user_id = r.viewer)::text
                 || ar.p3
                 || EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = ar.author_id)::text
                 || '}}}' END AS body
  FROM r LEFT JOIN arts ar ON ar.slug = r.slug
