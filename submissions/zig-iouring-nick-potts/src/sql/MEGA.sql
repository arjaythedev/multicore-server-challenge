WITH r AS MATERIALIZED (
  SELECT * FROM unnest($1::int4[], $2::int8[], $3::int8[], $4::int8[], $5::int8[], $6::text[])
    WITH ORDINALITY AS r(k, v, i1, i2, i3, t1, ord)),
lk AS MATERIALIZED (
  SELECT DISTINCT k, CASE WHEN k = 5 THEN v ELSE 0 END AS fv, i1 AS lim, i2 AS off, COALESCE(i3, 0) AS lpo, COALESCE(t1, '') AS t1
  FROM r WHERE k BETWEEN 1 AND 5),
la AS MATERIALIZED (
  SELECT lk.k, lk.fv, lk.lim, lk.off, lk.lpo, lk.t1,
    CASE WHEN lk.k = 5 THEN ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = lk.fv) END AS a
  FROM lk),
tf AS MATERIALIZED (
  SELECT x.f FROM la CROSS JOIN LATERAL unnest(la.a) x(f) GROUP BY x.f HAVING count(*) > 1
  ORDER BY count(*) DESC, x.f LIMIT 10),
big AS MATERIALIZED (
  SELECT ARRAY(SELECT tf.f FROM tf WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = tf.f
    ORDER BY a3.author_id DESC, a3.id OFFSET 999)) AS a),
lc AS MATERIALIZED (
  SELECT ck.k, ck.fv, ck.lim, ck.off, ck.lpo, ck.t1, ck.a, CASE ck.k
    WHEN 1 THEN (SELECT CASE WHEN EXISTS (SELECT id FROM articles ORDER BY id OFFSET 999) THEN 1000::bigint ELSE (SELECT count(*) FROM articles) END)
    WHEN 2 THEN (SELECT CASE WHEN EXISTS (SELECT at.tag_id, at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ck.t1) OFFSET 999 LIMIT 1) THEN 1000::bigint
                  ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ck.t1) LIMIT 1000) s) END)
    WHEN 3 THEN (SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = ck.t1) LIMIT 1000) s)
    WHEN 4 THEN (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ck.t1) LIMIT 1000) s)
    WHEN 5 THEN CASE WHEN ck.a && (SELECT big.a FROM big) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ck.a) ORDER BY a3.author_id DESC, a3.id LIMIT 1000) s) END
  END AS n
  FROM la ck),
pg AS MATERIALIZED (
  SELECT lk.k, lk.fv, lk.lim, lk.off, lk.lpo, lk.t1, lk.n, p.id
  FROM lc lk LEFT JOIN LATERAL (
      (SELECT b.id FROM (SELECT a2.id FROM articles a2 WHERE lk.k = 1 ORDER BY a2.id DESC LIMIT 100 OFFSET lk.off) b ORDER BY b.id DESC LIMIT lk.lim)
    UNION ALL
      (SELECT at.article_id FROM article_tags at WHERE lk.k = 2 AND at.tag_id = (SELECT t.id FROM tags t WHERE t.name = lk.t1)
       ORDER BY at.article_id DESC LIMIT lk.lim OFFSET lk.off)
    UNION ALL
      (SELECT a2.id FROM articles a2 WHERE lk.k = 3 AND a2.author_id = (SELECT au.id FROM users au WHERE au.username = lk.t1)
       ORDER BY a2.id DESC LIMIT lk.lim OFFSET lk.off)
    UNION ALL
      (SELECT f.article_id FROM favorites f WHERE lk.k = 4 AND f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = lk.t1)
       ORDER BY f.article_id DESC LIMIT lk.lim OFFSET lk.off)
    UNION ALL
      (SELECT x.id FROM unnest(lk.a) fo(followee_id) CROSS JOIN LATERAL (SELECT a3.id FROM articles a3 WHERE a3.author_id = fo.followee_id ORDER BY a3.id DESC LIMIT lk.lpo) x
       WHERE lk.k = 5 ORDER BY x.id DESC LIMIT lk.lim OFFSET lk.off)
  ) p ON true),
art AS MATERIALIZED (
  SELECT r.ord, r.v, a.id FROM r JOIN articles a ON a.slug = r.t1 WHERE r.k = 6
  UNION ALL
  SELECT r.ord, r.v, r.i1 FROM r WHERE r.k = 7),
ids AS MATERIALIZED (
  SELECT id FROM pg WHERE id IS NOT NULL UNION SELECT id FROM art),
tg AS MATERIALIZED (
  SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS tags
  FROM article_tags at JOIN tags t ON t.id = at.tag_id
  WHERE at.article_id = ANY (ARRAY(SELECT ids.id FROM ids ORDER BY 1))
  GROUP BY at.article_id),
e AS MATERIALIZED (
  SELECT a.id, a.slug, a.title, a.description, CASE WHEN a.id IN (SELECT art.id FROM art) THEN a.body END AS body, a.created_at, a.updated_at, a.author_id,
    COALESCE(tg.tags, '{}'::text[]) AS tags, COALESCE(fq.fc, 0) AS fc,
    u.username, u.bio, u.image
  FROM ids i JOIN articles a ON a.id = i.id JOIN users u ON u.id = a.author_id
  LEFT JOIN tg ON tg.article_id = a.id
  LEFT JOIN (SELECT f.article_id, count(*) AS fc FROM favorites f WHERE f.article_id = ANY (ARRAY(SELECT ids.id FROM ids ORDER BY 1))
             GROUP BY f.article_id) fq ON fq.article_id = a.id),
pa AS MATERIALIZED (
  SELECT pg.k, pg.fv, pg.lim, pg.off, pg.lpo, pg.t1, pg.n,
    array_agg(pg.id) FILTER (WHERE pg.id IS NOT NULL) AS ids, array_agg(e.author_id) FILTER (WHERE pg.id IS NOT NULL) AS aus
  FROM pg LEFT JOIN e ON e.id = pg.id
  GROUP BY pg.k, pg.fv, pg.lim, pg.off, pg.lpo, pg.t1, pg.n),
rl AS MATERIALIZED (
  SELECT r.ord, r.k, pa.n, pa.ids, pa.aus,
    ARRAY(SELECT f.article_id FROM favorites f WHERE f.user_id = r.v AND f.article_id = ANY (pa.ids)) AS fa,
    CASE WHEN r.k <> 5 THEN ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = ANY (pa.aus)) END AS fw
  FROM r
  JOIN pa ON pa.k = r.k AND pa.fv = CASE WHEN r.k = 5 THEN r.v ELSE 0 END AND pa.lim = r.i1 AND pa.off = r.i2
    AND pa.lpo = COALESCE(r.i3, 0) AND pa.t1 = COALESCE(r.t1, '')
  WHERE r.k BETWEEN 1 AND 5)
SELECT NULL::int8, e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tags, e.fc, NULL::bool,
  e.username, e.bio, e.image, NULL::bool, NULL::int8, NULL::text, -1::int8
FROM e
UNION ALL
SELECT rl.n, x.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  COALESCE(x.id = ANY (rl.fa), false),
  NULL, NULL, NULL,
  CASE WHEN rl.k = 5 THEN x.id IS NOT NULL ELSE COALESCE(x.au = ANY (rl.fw), false) END,
  NULL, NULL, rl.ord
FROM rl LEFT JOIN LATERAL unnest(rl.ids, rl.aus) x(id, au) ON true
UNION ALL
SELECT NULL, e.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = x.v),
  NULL, NULL, NULL,
  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = x.v AND fo.followee_id = e.author_id),
  NULL, NULL, x.ord
FROM art x JOIN e ON e.id = x.id
UNION ALL
SELECT NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, u.username, u.bio, u.image,
  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id),
  NULL, NULL, r.ord
FROM r JOIN users u ON u.username = r.t1
WHERE r.k = 9
UNION ALL
SELECT NULL, u.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, u.username, u.bio, u.image, NULL,
  NULL, u.email, r.ord
FROM r JOIN users u ON u.id = r.v
WHERE r.k = 10
UNION ALL
(SELECT 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ARRAY(SELECT name FROM tags ORDER BY name), NULL, NULL,
  NULL, NULL, NULL, NULL, NULL, NULL, -3
 FROM r
 WHERE r.k = 12
 LIMIT 1)
UNION ALL
SELECT 0, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, r.ord
FROM r
WHERE r.k = 12
