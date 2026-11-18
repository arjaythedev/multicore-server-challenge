-- GET /api/articles/feed for a batch of requests (one array element per request; one row per request out): the
-- newest articles by the users each viewer follows. Requests for the same viewer and page share it, and each
-- article on any page of the batch is built once.
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
         ARRAY(SELECT x.id FROM follows fo CROSS JOIN LATERAL
                      (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                        ORDER BY a2.id DESC LIMIT k.page_limit + k.page_offset) x
                WHERE fo.follower_id = k.viewer
                ORDER BY x.id DESC LIMIT k.page_limit OFFSET k.page_offset) AS ids
    FROM k),
ids AS MATERIALIZED (SELECT DISTINCT unnest(ids) AS id FROM pages),
tg AS MATERIALIZED ({{_tags}}),
arts AS MATERIALIZED (
  SELECT a.id, {{_art_parts}}
    FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id
    LEFT JOIN tg ON tg.article_id = a.id),
cnt AS MATERIALIZED (
  SELECT v.viewer, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN
                      (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = v.viewer) LIMIT 1000) s) AS n
    FROM (SELECT DISTINCT viewer FROM k) v),
-- a feed lists only authors the viewer follows (read in the same snapshot), so "following" is always true
items AS (
  SELECT r.i, (SELECT string_agg(ar.p1 || ar.p2 || (ar.id = ANY (fav.ids))::text || ar.p3 || 'true}}', ',' ORDER BY e.n)
                 FROM unnest(p.ids) WITH ORDINALITY AS e(id, n) JOIN arts ar ON ar.id = e.id) AS items
    FROM r JOIN pages p ON p.viewer = r.viewer AND p.page_limit = r.page_limit AND p.page_offset = r.page_offset
    CROSS JOIN LATERAL (SELECT ARRAY(SELECT f.article_id FROM favorites f
                                      WHERE f.user_id = r.viewer AND f.article_id = ANY (p.ids)) AS ids) fav)
SELECT r.i, coalesce(r.astatus, r.pstatus, 200) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN r.pstatus IS NOT NULL THEN r.pbody
            ELSE '{"articles":[' || coalesce(it.items, '') || '],"articlesCount":' || c.n || '}' END AS body
  FROM r LEFT JOIN items it ON it.i = r.i
         LEFT JOIN cnt c ON c.viewer = r.viewer
