WITH
r AS MATERIALIZED (
  SELECT kind, viewer, lim, off, key, ord::int8
  FROM unnest($1::int4[], $2::int8[], $3::int4[], $4::int4[], $5::text[])
       WITH ORDINALITY r(kind, viewer, lim, off, key, ord)
),
uk AS MATERIALIZED (SELECT DISTINCT key FROM r WHERE kind IN (3,4,7)),
u AS MATERIALIZED (SELECT uk.key, x.id, x.username, x.bio, x.image FROM uk LEFT JOIN users x ON x.username = uk.key),
tk AS MATERIALIZED (SELECT DISTINCT key FROM r WHERE kind = 2),
t AS MATERIALIZED (SELECT tk.key, x.id FROM tk LEFT JOIN tags x ON x.name = tk.key),
ff AS MATERIALIZED (
  SELECT v.viewer, ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id = v.viewer) AS ids
  FROM (SELECT DISTINCT viewer FROM r WHERE kind = 5) v
),
hc AS MATERIALIZED (
  SELECT a.id FROM ff CROSS JOIN LATERAL unnest(ff.ids) a(id)
  GROUP BY a.id ORDER BY count(*) DESC, a.id LIMIT 8
),
heavy AS MATERIALIZED (
  SELECT hc.id FROM hc WHERE EXISTS (SELECT 1 FROM articles a WHERE a.author_id = hc.id OFFSET 999 LIMIT 1)
),
ck AS MATERIALIZED (SELECT DISTINCT kind, key, CASE WHEN kind = 5 THEN viewer ELSE 0::int8 END AS v FROM r WHERE kind <= 5),
counts AS MATERIALIZED (
  SELECT ck.*, CASE ck.kind
    WHEN 1 THEN (SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) x)
    WHEN 2 THEN (SELECT count(*) FROM (SELECT 1 FROM article_tags a WHERE a.tag_id = t.id LIMIT 1000) x)
    WHEN 3 THEN (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = u.id LIMIT 1000) x)
    WHEN 4 THEN (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = u.id LIMIT 1000) x)
    WHEN 5 THEN CASE WHEN EXISTS (SELECT 1 FROM heavy h WHERE h.id = ANY(ff.ids)) THEN 1000::int8
                    ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = ANY(ff.ids) LIMIT 1000) x) END
  END AS n
  FROM ck LEFT JOIN u ON ck.kind IN (3,4) AND u.key = ck.key
          LEFT JOIN t ON ck.kind = 2 AND t.key = ck.key
          LEFT JOIN ff ON ck.kind = 5 AND ff.viewer = ck.v
),
pk AS MATERIALIZED (SELECT DISTINCT kind, key, CASE WHEN kind = 5 THEN viewer ELSE 0::int8 END AS v, lim, off FROM r WHERE kind <= 5),
pages AS MATERIALIZED (
  SELECT pk.*, CASE pk.kind
    WHEN 1 THEN ARRAY(SELECT a.id FROM articles a ORDER BY a.id DESC OFFSET pk.off LIMIT pk.lim)
    WHEN 2 THEN ARRAY(SELECT a.article_id FROM article_tags a WHERE a.tag_id = t.id ORDER BY a.article_id DESC OFFSET pk.off LIMIT pk.lim)
    WHEN 3 THEN ARRAY(SELECT a.id FROM articles a WHERE a.author_id = u.id ORDER BY a.id DESC OFFSET pk.off LIMIT pk.lim)
    WHEN 4 THEN ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC OFFSET pk.off LIMIT pk.lim)
    WHEN 5 THEN ARRAY(SELECT x.id FROM unnest(ff.ids) f(id) CROSS JOIN LATERAL
                      (SELECT a.id FROM articles a WHERE a.author_id = f.id ORDER BY a.id DESC LIMIT pk.off + pk.lim) x
                      ORDER BY x.id DESC OFFSET pk.off LIMIT pk.lim)
  END AS ids
  FROM pk LEFT JOIN u ON pk.kind IN (3,4) AND u.key = pk.key
          LEFT JOIN t ON pk.kind = 2 AND t.key = pk.key
          LEFT JOIN ff ON pk.kind = 5 AND ff.viewer = pk.v
),
slugs AS MATERIALIZED (
  SELECT k.key, a.id FROM (SELECT DISTINCT key FROM r WHERE kind = 6) k LEFT JOIN articles a ON a.slug = k.key
),
ids AS MATERIALIZED (SELECT DISTINCT x.id FROM pages CROSS JOIN LATERAL unnest(pages.ids) x(id)
                     UNION SELECT id FROM slugs WHERE id IS NOT NULL),
favcounts AS MATERIALIZED (SELECT f.article_id, count(*) AS n FROM favorites f WHERE f.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY f.article_id),
names AS MATERIALIZED (SELECT a.article_id, array_agg(t.name ORDER BY t.name) AS tags FROM article_tags a JOIN tags t ON t.id = a.tag_id
                       WHERE a.article_id = ANY(ARRAY(SELECT id FROM ids)) GROUP BY a.article_id),
arts AS MATERIALIZED (
  SELECT a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at,
         CASE WHEN a.id IN (SELECT id FROM slugs) THEN a.body END AS body,
         COALESCE(names.tags, '{}'::text[]) AS tags, COALESCE(favcounts.n, 0::int8) AS favs, u.username, u.bio, u.image
  FROM ids JOIN articles a ON a.id = ids.id JOIN users u ON u.id = a.author_id
           LEFT JOIN names ON names.article_id = a.id LEFT JOIN favcounts ON favcounts.article_id = a.id
),
headers AS MATERIALIZED (
  SELECT r.ord, r.kind, r.viewer, c.n, p.ids, NULL::int8 AS author_id, NULL::text AS username, NULL::text AS bio, NULL::text AS image
  FROM r JOIN counts c ON c.kind = r.kind AND c.key = r.key AND c.v = CASE WHEN r.kind = 5 THEN r.viewer ELSE 0::int8 END
         JOIN pages p ON p.kind = r.kind AND p.key = r.key AND p.v = c.v AND p.lim = r.lim AND p.off = r.off
  UNION ALL
  SELECT r.ord, r.kind, r.viewer, CASE WHEN s.id IS NULL THEN 0 ELSE 1 END::int8,
         CASE WHEN s.id IS NULL THEN '{}'::int8[] ELSE ARRAY[s.id] END, NULL::int8, NULL::text, NULL::text, NULL::text
  FROM r JOIN slugs s ON s.key = r.key WHERE r.kind = 6
  UNION ALL
  SELECT r.ord, r.kind, r.viewer, CASE WHEN u.id IS NULL THEN 0 ELSE 1 END::int8, '{}'::int8[], u.id, u.username, u.bio, u.image
  FROM r JOIN u ON u.key = r.key WHERE r.kind = 7
  UNION ALL SELECT r.ord, r.kind, r.viewer, 1::int8, '{}'::int8[], NULL::int8, NULL::text, NULL::text, NULL::text FROM r WHERE r.kind = 8
),
va AS MATERIALIZED (SELECT h.viewer, array_agg(DISTINCT x.id) AS ids FROM headers h CROSS JOIN LATERAL unnest(h.ids) x(id) WHERE h.viewer <> 0 GROUP BY h.viewer),
vf AS MATERIALIZED (SELECT va.viewer, ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = va.viewer AND f.article_id = ANY(va.ids)) AS ids FROM va),
vu AS MATERIALIZED (
  SELECT v.viewer, array_agg(DISTINCT v.id) AS ids FROM (
    SELECT h.viewer, a.author_id AS id FROM headers h CROSS JOIN LATERAL unnest(h.ids) x(id) JOIN arts a ON a.id = x.id WHERE h.viewer <> 0 AND h.kind <> 5
    UNION ALL SELECT h.viewer, h.author_id FROM headers h WHERE h.viewer <> 0 AND h.author_id IS NOT NULL
  ) v GROUP BY v.viewer
),
vfol AS MATERIALIZED (SELECT vu.viewer, ARRAY(SELECT f.followee_id FROM follows f WHERE f.follower_id = vu.viewer AND f.followee_id = ANY(vu.ids)) AS ids FROM vu),
ha AS MATERIALIZED (SELECT h.ord, array_agg(DISTINCT a.author_id) AS ids FROM headers h
                    CROSS JOIN LATERAL unnest(h.ids) x(id) JOIN arts a ON a.id = x.id GROUP BY h.ord)
SELECT 0::int8 AS ord, NULL::int8 AS n, a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.body, a.tags, a.favs,
       a.username, a.bio, a.image, NULL::int8[] AS ids, NULL::int8[] AS fav_ids, NULL::int8[] AS follow_ids FROM arts a
UNION ALL
SELECT h.ord, h.n, NULL::int8, h.author_id, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text[], NULL::int8,
       h.username, h.bio, h.image, h.ids,
       ARRAY(SELECT x.id FROM unnest(vf.ids) x(id) WHERE x.id = ANY(h.ids)),
       ARRAY(SELECT x.id FROM unnest(vfol.ids) x(id) WHERE x.id = h.author_id OR x.id = ANY(ha.ids))
FROM headers h LEFT JOIN vf ON vf.viewer = h.viewer LEFT JOIN vfol ON vfol.viewer = h.viewer LEFT JOIN ha ON ha.ord = h.ord
UNION ALL
SELECT -1::int8, NULL::int8, NULL::int8, NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text,
       ARRAY(SELECT name FROM tags ORDER BY name), NULL::int8, NULL::text, NULL::text, NULL::text, NULL::int8[], NULL::int8[], NULL::int8[]
WHERE EXISTS (SELECT 1 FROM r WHERE kind = 8)
