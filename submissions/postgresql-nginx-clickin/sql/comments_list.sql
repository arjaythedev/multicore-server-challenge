-- GET /api/articles/:slug/comments: the newest 100.
SELECT CASE WHEN a.id IS NULL THEN 404 ELSE 200 END AS status,
       CASE WHEN a.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE jsonb_build_object('comments', coalesce(
                   (SELECT jsonb_agg({{_comment}} ORDER BY c.created_at DESC, c.id DESC)
                      FROM (SELECT c.*, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = :viewer::bigint
                                                                         AND fo.followee_id = c.author_id) AS following
                              FROM comments c WHERE c.article_id = a.id
                             ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
                      JOIN users u ON u.id = c.author_id), '[]'))::text END AS body
  FROM (SELECT 1) one LEFT JOIN articles a ON a.slug = :slug::text
