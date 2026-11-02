-- The last step of every write that answers with an article: {"article": Article} for :article_id,
-- or 404 when another request deleted it after this write committed.
SELECT coalesce(art.status, 404) AS status,
       coalesce(art.body, '{"errors":{"body":["article not found"]}}') AS body
  FROM (SELECT 1) one
  LEFT JOIN LATERAL (SELECT :ok_status::int AS status, jsonb_build_object('article', {{_article}})::text AS body
                       FROM articles a JOIN users u ON u.id = a.author_id
                      CROSS JOIN (SELECT :viewer::bigint AS viewer) auth
                      WHERE a.id = :article_id::bigint) art ON true
