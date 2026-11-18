-- GET /api/tags
SELECT 200 AS status, jsonb_build_object('tags', coalesce(jsonb_agg(name ORDER BY name), '[]'))::text AS body
  FROM tags
