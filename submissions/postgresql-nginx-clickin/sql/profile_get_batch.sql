-- GET /api/profiles/:username for a batch of requests (one array element per request; one row per request out).
WITH q AS MATERIALIZED (
  SELECT * FROM unnest(:authorization::text[], :username::text[]) WITH ORDINALITY AS q(authz, username, i)),
r AS MATERIALIZED (
  SELECT q.i, q.username, au.status AS astatus, au.body AS abody, au.viewer FROM q CROSS JOIN LATERAL ({{_jwt}}) au)
SELECT r.i, coalesce(r.astatus, CASE WHEN u.id IS NULL THEN 404 ELSE 200 END) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN u.id IS NULL THEN '{"errors":{"body":["profile not found"]}}'
            ELSE '{"profile":{"username":' || to_json(u.username)::text || ',"bio":' || coalesce(to_json(u.bio)::text, 'null')
                 || ',"image":' || coalesce(to_json(u.image)::text, 'null') || ',"following":'
                 || EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.viewer AND fo.followee_id = u.id)::text
                 || '}}' END AS body
  FROM r LEFT JOIN LATERAL (SELECT u.id, u.username, u.bio, u.image FROM users u
                             WHERE r.astatus IS NULL AND u.username = r.username OFFSET 0) u ON true
