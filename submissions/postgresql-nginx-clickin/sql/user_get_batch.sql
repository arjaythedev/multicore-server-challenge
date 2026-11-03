-- GET /api/user for a batch of requests (one array element per request; one row per request out). A token for a
-- user that doesn't exist is a 401.
WITH q AS MATERIALIZED (
  SELECT * FROM unnest(:authorization::text[]) WITH ORDINALITY AS q(authz, i)),
r AS MATERIALIZED (
  SELECT q.i, au.status AS astatus, au.body AS abody, au.viewer, au.token FROM q CROSS JOIN LATERAL ({{_jwt}}) au)
SELECT r.i, coalesce(r.astatus, CASE WHEN u.id IS NULL THEN 401 ELSE 200 END) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN u.id IS NULL THEN '{"errors":{"body":["user not found"]}}'
            ELSE '{"user":{"email":' || to_json(u.email)::text || ',"token":' || to_json(r.token)::text
                 || ',"username":' || to_json(u.username)::text || ',"bio":' || coalesce(to_json(u.bio)::text, 'null')
                 || ',"image":' || coalesce(to_json(u.image)::text, 'null') || '}}' END AS body
  FROM r LEFT JOIN LATERAL (SELECT u.id, u.email, u.username, u.bio, u.image FROM users u
                             WHERE r.astatus IS NULL AND u.id = r.viewer OFFSET 0) u ON true
