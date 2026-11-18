-- GET /api/articles/:slug/comments for a batch of requests (one array element per request; one row per request
-- out). Requests for the same article share its newest 100 comments; "following" is each request's own.
WITH q AS MATERIALIZED (
  SELECT * FROM unnest(:authorization::text[], :slug::text[]) WITH ORDINALITY AS q(authz, slug, i)),
r AS MATERIALIZED (
  SELECT q.i, q.slug, au.status AS astatus, au.body AS abody, au.viewer FROM q CROSS JOIN LATERAL ({{_jwt}}) au),
cs AS MATERIALIZED (
  SELECT d.slug, a.id, c.authors, c.heads
    FROM (SELECT DISTINCT slug FROM r WHERE astatus IS NULL) d
    CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = d.slug OFFSET 0) a
    CROSS JOIN LATERAL (
      SELECT array_agg(x.author_id ORDER BY x.created_at DESC, x.id DESC) AS authors,
             array_agg(x.head ORDER BY x.created_at DESC, x.id DESC) AS heads
        FROM (SELECT c.id, c.created_at, c.author_id,
                     '{"id":' || c.id || ',"createdAt":"' || to_char(c.created_at AT TIME ZONE 'UTC', {{_ts}})
                     || '","updatedAt":"' || to_char(c.updated_at AT TIME ZONE 'UTC', {{_ts}}) || '","body":'
                     || to_json(c.body)::text || ',"author":{"username":' || to_json(u.username)::text
                     || ',"bio":' || coalesce(to_json(u.bio)::text, 'null')
                     || ',"image":' || coalesce(to_json(u.image)::text, 'null') || ',"following":' AS head
                FROM (SELECT * FROM comments c WHERE c.article_id = a.id
                       ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
                JOIN users u ON u.id = c.author_id) x) c)
SELECT r.i, coalesce(r.astatus, CASE WHEN cs.id IS NULL THEN 404 ELSE 200 END) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN cs.id IS NULL THEN '{"errors":{"body":["article not found"]}}'
            ELSE '{"comments":[' || coalesce(
                   (SELECT string_agg(e.head || (e.author_id = ANY (fl.following))::text || '}}', ',' ORDER BY e.n)
                      FROM unnest(cs.authors, cs.heads) WITH ORDINALITY AS e(author_id, head, n)), '') || ']}' END AS body
  FROM r LEFT JOIN cs ON cs.slug = r.slug
  LEFT JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo
                                   WHERE fo.follower_id = r.viewer AND fo.followee_id = ANY (cs.authors)) AS following) fl ON true
