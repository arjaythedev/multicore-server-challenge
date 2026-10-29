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
  SELECT x.f, GREATEST(max(la.lpo), 1) AS d FROM la CROSS JOIN LATERAL unnest(la.a) x(f) GROUP BY x.f HAVING count(*) > 1
  ORDER BY count(*) DESC, x.f LIMIT 20),
hf AS MATERIALIZED (
  SELECT tf.f,
    ARRAY(SELECT a4.id FROM articles a4 WHERE a4.author_id = tf.f ORDER BY a4.id DESC LIMIT LEAST(tf.d, 100)) AS ids,
    CASE WHEN tf.d > 100 THEN (SELECT a4.id FROM articles a4 WHERE a4.author_id = tf.f ORDER BY a4.id DESC OFFSET tf.d - 1 LIMIT 1) END AS fl
  FROM tf),
big AS MATERIALIZED (
  SELECT ARRAY(SELECT tf.f FROM tf WHERE EXISTS (SELECT 1 FROM articles a3 WHERE a3.author_id = tf.f
    ORDER BY a3.author_id DESC, a3.id OFFSET 999)) AS a),
lc1 AS MATERIALIZED (
  SELECT ck.k, ck.fv, ck.lim, ck.off, ck.lpo, ck.t1, ck.a, CASE WHEN row_number() OVER (PARTITION BY ck.k, ck.fv, ck.t1 ORDER BY ck.lim, ck.off, ck.lpo) = 1 THEN CASE ck.k
    WHEN 1 THEN (SELECT CASE WHEN EXISTS (SELECT id FROM articles ORDER BY id OFFSET 999) THEN 1000::bigint ELSE (SELECT count(*) FROM articles) END)
    WHEN 2 THEN (SELECT CASE WHEN EXISTS (SELECT at.tag_id, at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ck.t1) OFFSET 999 LIMIT 1) THEN 1000::bigint
                  ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = ck.t1) LIMIT 1000) s) END)
    WHEN 3 THEN (SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id = (SELECT au.id FROM users au WHERE au.username = ck.t1) LIMIT 1000) s)
    WHEN 4 THEN (SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = ck.t1) LIMIT 1000) s)
    WHEN 5 THEN CASE WHEN ck.a && (SELECT big.a FROM big) THEN 1000::bigint ELSE (SELECT count(*) FROM (SELECT 1 FROM articles a3 WHERE a3.author_id = ANY(ck.a) ORDER BY a3.author_id DESC, a3.id LIMIT 1000) s) END
  END END AS n
  FROM la ck),
lc AS MATERIALIZED (
  SELECT k, fv, lim, off, lpo, t1, a, max(n) OVER (PARTITION BY k, fv, t1) AS n,
    CASE WHEN k = 5 THEN (SELECT max(CASE WHEN lc1.lpo <= 100 THEN hf.ids[GREATEST(lc1.lpo, 1)::int] ELSE hf.fl END)
      FROM hf WHERE hf.f = ANY(lc1.a)) END AS fl FROM lc1),
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
      (SELECT x.id FROM unnest(lk.a) fo(followee_id) CROSS JOIN LATERAL (SELECT a3.id FROM articles a3
         WHERE a3.author_id = fo.followee_id AND a3.id >= COALESCE(lk.fl, 0) ORDER BY a3.id DESC LIMIT lk.lpo) x
       ORDER BY x.id DESC LIMIT lk.lim OFFSET lk.off)
  ) p ON true),
art AS MATERIALIZED (
  SELECT x.ord, x.v, a.id
  FROM (SELECT r.t1, array_agg(r.ord) AS ords, array_agg(r.v) AS vs FROM r WHERE r.k = 6 GROUP BY r.t1) g
  JOIN articles a ON a.slug = g.t1 CROSS JOIN LATERAL unnest(g.ords, g.vs) x(ord, v)
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
  e.username, e.bio, e.image, NULL::bool, NULL::int8[], NULL::int8[], NULL::int8[], NULL::int8[], -1::int8
FROM e
UNION ALL
SELECT rl.n, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  rl.ids, rl.aus, rl.fa, rl.fw, rl.ord
FROM rl
UNION ALL
SELECT NULL, e.id, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
  EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = e.id AND f.user_id = x.v),
  NULL, NULL, NULL,
  EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = x.v AND fo.followee_id = e.author_id),
  NULL, NULL, NULL, NULL, x.ord
FROM art x JOIN e ON e.id = x.id
