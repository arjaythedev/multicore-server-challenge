-- GET /api/articles/:slug, in one statement: who is asking (401 for a bad token), then the article (404).
WITH auth AS MATERIALIZED ({{_auth}})
SELECT coalesce(auth.status, CASE WHEN art.body IS NULL THEN 404 ELSE 200 END) AS status,
       CASE WHEN auth.status IS NOT NULL THEN auth.body
            WHEN art.body IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE art.body END AS body
  FROM auth
  LEFT JOIN LATERAL (SELECT jsonb_build_object('article', {{_article}})::text AS body
                       FROM articles a JOIN users u ON u.id = a.author_id
                      WHERE auth.status IS NULL AND a.slug = :slug::text) art ON true
