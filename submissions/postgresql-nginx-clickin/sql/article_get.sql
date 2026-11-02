-- GET /api/articles/:slug
SELECT CASE WHEN a.id IS NULL THEN 404 ELSE 200 END AS status,
       CASE WHEN a.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE jsonb_build_object('article', {{_article}})::text END AS body
  FROM (SELECT 1) one
  LEFT JOIN (articles a JOIN users u ON u.id = a.author_id) ON a.slug = :slug::text
