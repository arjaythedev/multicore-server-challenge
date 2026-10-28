module Conduit::ReadSql
  MIXED_SQL = <<-SQL
    WITH r AS MATERIALIZED (
      SELECT *, CASE WHEN t = 4 THEN v ELSE 0 END AS kv
      FROM unnest($1::int8[], $2::int8[], $3::int8[], $4::text[], $5::int4[])
        WITH ORDINALITY r(v,l,o,s,t,n)
    ), k AS MATERIALIZED (SELECT DISTINCT t,l,o,s,kv FROM r),
    p AS MATERIALIZED (
      SELECT k.*, x.id FROM k CROSS JOIN LATERAL (
        (SELECT a.id FROM articles a WHERE k.t = 0 ORDER BY a.id DESC LIMIT k.l OFFSET k.o)
        UNION ALL
        (SELECT at.article_id FROM article_tags at WHERE k.t = 1 AND at.tag_id =
          (SELECT id FROM tags WHERE name = k.s) ORDER BY at.article_id DESC LIMIT k.l OFFSET k.o)
        UNION ALL
        (SELECT a.id FROM articles a WHERE k.t = 2 AND a.author_id =
          (SELECT id FROM users WHERE username = k.s) ORDER BY a.id DESC LIMIT k.l OFFSET k.o)
        UNION ALL
        (SELECT f.article_id FROM favorites f WHERE k.t = 3 AND f.user_id =
          (SELECT id FROM users WHERE username = k.s) ORDER BY f.article_id DESC LIMIT k.l OFFSET k.o)
        UNION ALL
        (SELECT x.id FROM follows fo CROSS JOIN LATERAL
          (SELECT a.id FROM articles a WHERE a.author_id = fo.followee_id ORDER BY a.id DESC LIMIT k.l+k.o) x
          WHERE k.t = 4 AND fo.follower_id = k.kv ORDER BY x.id DESC LIMIT k.l OFFSET k.o)
        UNION ALL
        SELECT a.id FROM articles a WHERE k.t = 5 AND a.slug = k.s
      ) x
    ), ck AS MATERIALIZED (SELECT DISTINCT t,s,kv FROM r),
    counts AS MATERIALIZED (
      SELECT ck.*, CASE t
        WHEN 0 THEN (SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) z)
        WHEN 1 THEN (SELECT count(*) FROM (SELECT 1 FROM article_tags WHERE tag_id =
          (SELECT id FROM tags WHERE name = ck.s) LIMIT 1000) z)
        WHEN 2 THEN (SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id =
          (SELECT id FROM users WHERE username = ck.s) LIMIT 1000) z)
        WHEN 3 THEN (SELECT count(*) FROM (SELECT 1 FROM favorites WHERE user_id =
          (SELECT id FROM users WHERE username = ck.s) LIMIT 1000) z)
        WHEN 4 THEN (SELECT count(*) FROM (SELECT 1 FROM articles WHERE author_id IN
          (SELECT followee_id FROM follows WHERE follower_id = ck.kv) LIMIT 1000) z)
        ELSE 0 END AS total FROM ck
    )
    SELECT r.n, p.id, counts.total
    FROM r FULL JOIN counts ON counts.t = r.t AND counts.s = r.s AND counts.kv = r.kv
    LEFT JOIN p ON p.t = r.t AND p.l = r.l AND p.o = r.o AND p.s = r.s AND p.kv = r.kv
    ORDER BY r.n, p.id DESC
    SQL

  # Phase B returns each article once. The application fans rows out to requests;
  # PostgreSQL never serializes the same article once per overlapping page.
  # Tag names come from one join over the batch's article_tags rows; `t.id + 0` keeps the
  # 200 tags in one hash instead of an index probe per tag row.
  ENRICH_SQL = <<-SQL
    WITH d AS MATERIALIZED (SELECT DISTINCT unnest($1::int8[]) AS id),
    tg AS MATERIALIZED (
      SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS names
      FROM article_tags at JOIN tags t ON t.id + 0 = at.tag_id
      WHERE at.article_id = ANY($1::int8[]) GROUP BY at.article_id
    )
    SELECT x.id, x.slug, x.title, x.description, x.body, x.created_at, x.updated_at,
      COALESCE(tg.names, '{}'::text[]), x.favs, false, x.username, x.bio, x.image, false, x.author_id
    FROM d CROSS JOIN LATERAL (
      SELECT a.id, a.slug, a.title, a.description,
        CASE WHEN a.id = ANY($2::int8[]) THEN a.body ELSE '' END AS body,
        a.created_at, a.updated_at,
        (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favs,
        u.username, u.bio, u.image, a.author_id
      FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = d.id OFFSET 0
    ) x LEFT JOIN tg ON tg.article_id = x.id
    ORDER BY x.id
    SQL
  # Viewer flags take (article, viewer) pairs: each viewer probes only the articles
  # on its own pages, in one index range scan (= ANY), not every viewer x article.
  FAVORITES_SQL = <<-SQL
    WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(a, v) GROUP BY x.v)
    SELECT p.v, f.article_id FROM p CROSS JOIN LATERAL
      (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.aa)) f
    SQL
  FOLLOWS_SQL = <<-SQL
    WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(a, v) GROUP BY x.v)
    SELECT p.v, fo.followee_id FROM p CROSS JOIN LATERAL
      (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id =
        ANY(ARRAY(SELECT a.author_id FROM articles a WHERE a.id = ANY(p.aa)))) fo
    SQL

  MIXED     = Rayo::PG::Statement.new(MIXED_SQL)
  ENRICH    = Rayo::PG::Statement.new(ENRICH_SQL)
  FAVORITES = Rayo::PG::Statement.new(FAVORITES_SQL)
  FOLLOWS   = Rayo::PG::Statement.new(FOLLOWS_SQL)
  COMMENTS  = Rayo::PG::Statement.new(<<-SQL)
    WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v,s,n)),
    c AS MATERIALIZED (
      SELECT k.s, a.id AS aid, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image
      FROM (SELECT DISTINCT s FROM r) k
      LEFT JOIN LATERAL (SELECT id FROM articles WHERE slug = k.s OFFSET 0) a ON true
      LEFT JOIN LATERAL (SELECT * FROM comments WHERE article_id = a.id
        ORDER BY created_at DESC, id DESC LIMIT 100) c ON true
      LEFT JOIN LATERAL (SELECT username,bio,image FROM users WHERE id = c.author_id OFFSET 0) u ON true
    ), p AS MATERIALIZED (
      SELECT r.v, array_agg(DISTINCT c.author_id) AS aa FROM r JOIN c ON c.s = r.s WHERE r.v > 0 GROUP BY r.v
    ), f AS MATERIALIZED (
      SELECT p.v, fo.followee_id FROM p CROSS JOIN LATERAL
        (SELECT followee_id FROM follows WHERE follower_id = p.v AND followee_id = ANY(p.aa)) fo
    )
    SELECT r.n, c.aid, c.id,c.body,c.created_at,c.updated_at,c.username,c.bio,c.image, f.v IS NOT NULL
    FROM r JOIN c ON c.s = r.s LEFT JOIN f ON f.v = r.v AND f.followee_id = c.author_id
    ORDER BY r.n, c.created_at DESC, c.id DESC
    SQL
  USERS    = Rayo::PG::Statement.new("SELECT r.n, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(v,n) JOIN users u ON u.id = r.v ORDER BY r.n")
  PROFILES = Rayo::PG::Statement.new("SELECT r.n, u.id, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v,s,n) JOIN users u ON u.username = r.s ORDER BY r.n")
  SETTINGS = Rayo::PG::Statement.new("SELECT set_config('jit', 'off', false), set_config('plan_cache_mode', 'force_generic_plan', false), set_config('max_parallel_workers_per_gather', '0', false), set_config('enable_seqscan', 'off', false)")
end
