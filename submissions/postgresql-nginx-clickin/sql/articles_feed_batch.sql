-- GET /api/articles/feed for a batch of requests (one array element per request; one row per request out): the
-- newest articles by the users each viewer follows. Requests for the same viewer and page share it.
WITH q AS MATERIALIZED (
  SELECT * FROM unnest(:authorization::text[], :limit::text[], :offset::text[]) WITH ORDINALITY AS q(authz, lim, off, i)),
r AS MATERIALIZED (
  SELECT q.i, au.status AS astatus, au.body AS abody, au.viewer, pg.status AS pstatus, pg.body AS pbody,
         pg.page_limit, pg.page_offset
    FROM q CROSS JOIN LATERAL ({{_jwt}}) au CROSS JOIN LATERAL ({{_paging}}) pg),
k AS MATERIALIZED (
  SELECT DISTINCT viewer, page_limit, page_offset FROM r WHERE astatus IS NULL AND pstatus IS NULL),
pages AS MATERIALIZED (
  SELECT k.viewer, k.page_limit, k.page_offset,
         array_agg(ar.id ORDER BY ar.id DESC) AS ids, array_agg(ar.author_id ORDER BY ar.id DESC) AS authors,
         array_agg(ar.p1 || ar.p2 ORDER BY ar.id DESC) AS heads, array_agg(ar.p3 ORDER BY ar.id DESC) AS mids
    FROM k CROSS JOIN LATERAL (
      SELECT x.id FROM follows fo CROSS JOIN LATERAL
             (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
               ORDER BY a2.id DESC LIMIT k.page_limit + k.page_offset) x
       WHERE fo.follower_id = k.viewer
       ORDER BY x.id DESC LIMIT k.page_limit OFFSET k.page_offset) x
    CROSS JOIN LATERAL (SELECT a.id, a.author_id, {{_art_parts}}
                          FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = x.id OFFSET 0) ar
   GROUP BY k.viewer, k.page_limit, k.page_offset),
cnt AS MATERIALIZED (
  SELECT v.viewer, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
                      (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = v.viewer) LIMIT 1000) s) AS n
    FROM (SELECT DISTINCT viewer FROM k) v),
items AS (
  SELECT r.i, (SELECT string_agg(e.head
                                 || EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = r.viewer)::text
                                 || e.mid || 'true}}', ',' ORDER BY e.n)
                 FROM unnest(p.ids, p.authors, p.heads, p.mids) WITH ORDINALITY AS e(id, author_id, head, mid, n)) AS items
    FROM r JOIN pages p ON p.viewer = r.viewer AND p.page_limit = r.page_limit AND p.page_offset = r.page_offset)
SELECT r.i, coalesce(r.astatus, r.pstatus, 200) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN r.pstatus IS NOT NULL THEN r.pbody
            ELSE '{"articles":[' || coalesce(it.items, '') || '],"articlesCount":' || c.n || '}' END AS body
  FROM r LEFT JOIN items it ON it.i = r.i
         LEFT JOIN cnt c ON c.viewer = r.viewer
