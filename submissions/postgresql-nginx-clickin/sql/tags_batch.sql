-- GET /api/tags for a batch of :batch_size requests: the tags are read once, and every request gets them.
SELECT i, 200 AS status, t.body
  FROM generate_series(1, :batch_size::int) i,
       (SELECT json_build_object('tags', coalesce(json_agg(name ORDER BY name), '[]'))::text AS body FROM tags) t
