-- GET /api/articles/:slug/comments, in one statement: who is asking (401), the article (404), the newest 100.
WITH auth AS MATERIALIZED ({{_auth}})
SELECT coalesce(auth.status, CASE WHEN a.id IS NULL THEN 404 ELSE 200 END) AS status,
       CASE WHEN auth.status IS NOT NULL THEN auth.body
            WHEN a.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE jsonb_build_object('comments', coalesce(
                   (SELECT jsonb_agg({{_comment}} ORDER BY c.created_at DESC, c.id DESC)
                      FROM (SELECT c.*, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = auth.viewer
                                                                         AND fo.followee_id = c.author_id) AS following
                              FROM comments c WHERE c.article_id = a.id
                             ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
                      JOIN users u ON u.id = c.author_id), '[]'))::text END AS body
  FROM auth LEFT JOIN articles a ON auth.status IS NULL AND a.slug = :slug::text
