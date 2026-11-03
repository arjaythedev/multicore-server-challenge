-- GET /api/articles for a batch of requests (see "Batches" in the module). Each request value is an array with
-- one element per request; the answer is one row per request: i (its place in the arrays), status, body.
-- Requests that ask for the same page share its ids and count, and each article on any page of the batch is built
-- once; "favorited" and "following" are each request's own.
WITH q AS MATERIALIZED (
  SELECT * FROM unnest(:authorization::text[], :limit::text[], :offset::text[], :tag::text[], :author::text[],
                       :favorited::text[]) WITH ORDINALITY AS q(authz, lim, off, tag, author, favorited, i)),
r AS MATERIALIZED (
  SELECT q.i, au.status AS astatus, au.body AS abody, au.viewer, pg.status AS pstatus, pg.body AS pbody,
         CASE WHEN nullif(q.tag, '') IS NOT NULL THEN 1 WHEN nullif(q.author, '') IS NOT NULL THEN 2
              WHEN nullif(q.favorited, '') IS NOT NULL THEN 3 ELSE 0 END AS kind,
         coalesce(nullif(q.tag, ''), nullif(q.author, ''), nullif(q.favorited, ''), '') AS key,
         pg.page_limit, pg.page_offset
    FROM q CROSS JOIN LATERAL ({{_jwt}}) au CROSS JOIN LATERAL ({{_paging}}) pg),
k AS MATERIALIZED (
  SELECT DISTINCT kind, key, page_limit, page_offset FROM r WHERE astatus IS NULL AND pstatus IS NULL),
pages AS MATERIALIZED (
  SELECT k.kind, k.key, k.page_limit, k.page_offset, ARRAY(SELECT x.id FROM (
      (SELECT a.id FROM articles a WHERE k.kind = 0
        ORDER BY a.id DESC LIMIT k.page_limit OFFSET k.page_offset)
      UNION ALL
      (SELECT at.article_id FROM article_tags at
        WHERE k.kind = 1 AND at.tag_id = (SELECT t.id FROM tags t WHERE t.name = k.key)
        ORDER BY at.article_id DESC LIMIT k.page_limit OFFSET k.page_offset)
      UNION ALL
      (SELECT a.id FROM articles a
        WHERE k.kind = 2 AND a.author_id = (SELECT au.id FROM users au WHERE au.username = k.key)
        ORDER BY a.id DESC LIMIT k.page_limit OFFSET k.page_offset)
      UNION ALL
      (SELECT fa.article_id FROM favorites fa
        WHERE k.kind = 3 AND fa.user_id = (SELECT fu.id FROM users fu WHERE fu.username = k.key)
        ORDER BY fa.article_id DESC LIMIT k.page_limit OFFSET k.page_offset)) x ORDER BY x.id DESC) AS ids
    FROM k),
ids AS MATERIALIZED (SELECT DISTINCT unnest(ids) AS id FROM pages),
tg AS MATERIALIZED ({{_tags}}),
arts AS MATERIALIZED (
  SELECT a.id, a.author_id, {{_art_parts}}
    FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id
    LEFT JOIN tg ON tg.article_id = a.id),
cnt AS MATERIALIZED (
  SELECT kk.kind, kk.key,
         CASE kk.kind
           WHEN 0 THEN (SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s)
           WHEN 1 THEN (SELECT count(*) FROM (SELECT 1 FROM article_tags at
                          WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = kk.key) LIMIT 1000) s)
           WHEN 2 THEN (SELECT count(*) FROM (SELECT 1 FROM articles a
                          WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = kk.key) LIMIT 1000) s)
           ELSE (SELECT count(*) FROM (SELECT 1 FROM favorites fa
                   WHERE fa.user_id = (SELECT fu.id FROM users fu WHERE fu.username = kk.key) LIMIT 1000) s)
         END AS n
    FROM (SELECT DISTINCT kind, key FROM k) kk),
items AS (
  SELECT r.i, (SELECT string_agg(ar.p1 || ar.p2 || (ar.id = ANY (v.favorited))::text || ar.p3
                                 || (ar.author_id = ANY (v.following))::text || '}}', ',' ORDER BY e.n)
                 FROM unnest(p.ids) WITH ORDINALITY AS e(id, n) JOIN arts ar ON ar.id = e.id) AS items
    FROM r JOIN (SELECT pg.*, ARRAY(SELECT ar.author_id FROM unnest(pg.ids) e(id) JOIN arts ar ON ar.id = e.id) AS authors
                   FROM pages pg) p
      ON p.kind = r.kind AND p.key = r.key AND p.page_limit = r.page_limit AND p.page_offset = r.page_offset
    CROSS JOIN LATERAL ({{_viewer_marks}}) v)
SELECT r.i, coalesce(r.astatus, r.pstatus, 200) AS status,
       CASE WHEN r.astatus IS NOT NULL THEN r.abody
            WHEN r.pstatus IS NOT NULL THEN r.pbody
            ELSE '{"articles":[' || coalesce(it.items, '') || '],"articlesCount":' || c.n || '}' END AS body
  FROM r LEFT JOIN items it ON it.i = r.i
         LEFT JOIN cnt c ON c.kind = r.kind AND c.key = r.key
