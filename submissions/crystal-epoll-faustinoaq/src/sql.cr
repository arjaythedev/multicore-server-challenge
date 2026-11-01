# Every statement the server runs, prepared once per Postgres connection (named by index).
# Reads are SPEC.md's reference SQL. Where an endpoint runs several dependent statements,
# they are either sent together before one Sync (one implicit transaction, one round trip:
# each statement sees the ones before it) or folded into one statement with CTEs that
# gives the same rows.
module Sql
  # Tag names are looked up one by one by primary key: a join lets the planner hash all of
  # tags for every article.
  ARTICLE_COLS = <<-SQL
    a.created_at, a.updated_at,
           ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                  FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
           (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
           EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
           u.username, u.bio, u.image,
           EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
      FROM articles a
      JOIN users u ON u.id = a.author_id
    SQL
  LIST = "SELECT a.id, a.slug, a.title, a.description, " + ARTICLE_COLS
  FULL = "SELECT a.id, a.slug, a.title, a.description, a.body, " + ARTICLE_COLS
  PAGE = " ORDER BY a.id DESC LIMIT $2 OFFSET $3"

  SLUGIFY  = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))"
  USER     = "id, username, email, bio, image"
  # currval is volatile: as a scalar subquery it's computed once and the lookup uses the key
  NEW_ID   = "(SELECT currval(pg_get_serial_sequence('articles', 'id')))"
  BY_SLUG  = "(SELECT id FROM articles WHERE slug = $2)"


  # ---- batched reads ----
  # The reads that queued up while a connection was busy go out together: one statement
  # per kind of read, its parameters arrays with one element per request (unnest ... WITH
  # ORDINALITY numbers them), and every row comes back tagged with its request's ordinal n,
  # ordered by it. Identical keys in a batch (the same page, slug, tag) are looked up once
  # and every article on any page is enriched once; only the per-viewer flags (favorited,
  # following) are per request. All of it is read while the requests wait: nothing is kept.
  ENRICH = <<-SQL
    a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id,
           ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                  FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tl,
           (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS fc,
           u.username, u.bio, u.image
    SQL
  ENRICH_L = ENRICH.sub("a.body, ", "")
  FLAGS = "EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = r.v AND f.article_id = e.id), " \
          "e.username, e.bio, e.image, " \
          "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = e.author_id)"
  LIST_OUT = "r.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tl, e.fc, " + FLAGS
  FULL_OUT = "r.n, e.id, e.slug, e.title, e.description, e.body, e.created_at, e.updated_at, e.tl, e.fc, " + FLAGS

  # r: the requests; k: their distinct page keys; p: each key's page of ids; e: every
  # article on any page, enriched once. OFFSET 0 keeps a lateral lookup a lookup: pulled
  # up into a join, the planner (guessing at the CTEs' sizes) would hash whole tables.
  def self.pages(args : String, cols : String, keys : String, page : String, on : String) : String
    "WITH r AS (SELECT * FROM unnest(#{args}) WITH ORDINALITY r(#{cols}, n)), " \
    "k AS MATERIALIZED (SELECT DISTINCT #{keys} FROM r), " \
    "p AS MATERIALIZED (SELECT k.*, x.id FROM k CROSS JOIN LATERAL (#{page}) x), " \
    "e AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT id FROM p) d CROSS JOIN LATERAL " \
    "(SELECT #{ENRICH_L} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = d.id OFFSET 0) x) " \
    "SELECT #{LIST_OUT} FROM r JOIN p ON #{on} JOIN e ON e.id = p.id ORDER BY r.n, e.id DESC"
  end

  # One capped count per distinct key; `q` counts for k.s (or k.v).
  def self.counts(type : String, key : String, q : String) : String
    "WITH r AS (SELECT * FROM unnest($1::#{type}[]) WITH ORDINALITY r(#{key}, n)), " \
    "k AS MATERIALIZED (SELECT DISTINCT #{key} FROM r), " \
    "c AS MATERIALIZED (SELECT k.#{key}, (SELECT count(*) FROM (#{q} LIMIT 1000) z) AS c FROM k) " \
    "SELECT r.n, c.c FROM r JOIN c ON c.#{key} = r.#{key} ORDER BY r.n"
  end

  LARGS = "$1::int8[], $2::int8[], $3::int8[], $4::text[]"
  LON   = "p.l = r.l AND p.o = r.o AND p.s = r.s"
  TAG_ID    = "(SELECT t.id FROM tags t WHERE t.name = k.s)"
  USER_NAME = "(SELECT uu.id FROM users uu WHERE uu.username = k.s)"

  # A round shares enrichment across global/tag/author/favorite pages, feeds and
  # article lookups. Page and count keys are independently deduplicated. Viewer
  # flags scan each viewer's relevant primary-key ranges once for the union.
  # Counts contain exactly the request keys: FULL JOIN preserves the left-join
  # semantics while preventing a nested scan under generic-plan estimates.
  MIXED = <<-SQL
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
  SHARED_ENRICH = <<-SQL
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
  SHARED_FAVORITES = <<-SQL
    WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(a, v) GROUP BY x.v)
    SELECT p.v, f.article_id FROM p CROSS JOIN LATERAL
      (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.aa)) f
    SQL
  SHARED_FOLLOWS = <<-SQL
    WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(a, v) GROUP BY x.v)
    SELECT p.v, fo.followee_id FROM p CROSS JOIN LATERAL
      (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = p.v AND fo.followee_id =
        ANY(ARRAY(SELECT a.author_id FROM articles a WHERE a.id = ANY(p.aa)))) fo
    SQL

  ALL = [
    # 0 TAGS
    "SELECT name FROM tags ORDER BY name",
    # 1 USER_BY_ID ($1 id)
    "SELECT #{USER} FROM users WHERE id = $1",
    # 2 LOGIN ($1 email)
    "SELECT #{USER}, password_hash FROM users WHERE email = $1",
    # 3 REGISTER
    "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING #{USER}",
    # 4 UPDATE_USER
    "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " \
    "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " \
    "WHERE id = $1 RETURNING #{USER}",
    # 5 PROFILE ($1 viewer, $2 username)
    "SELECT u.id, u.username, u.bio, u.image, " \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following " \
    "FROM users u WHERE u.username = $2",
    # 6 FOLLOW ($1 viewer, $2 username): the profile lookup and the insert in one statement
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), " \
    "f AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING) " \
    "SELECT username, bio, image FROM u",
    # 7 UNFOLLOW
    "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), " \
    "f AS (DELETE FROM follows fo USING u WHERE fo.follower_id = $1 AND fo.followee_id = u.id) " \
    "SELECT username, bio, image FROM u",
    # 8..11 list pages: all, tag, author, favorited ($1 viewer, $2 limit, $3 offset, $4 value)
    LIST + PAGE,
    LIST + " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
    LIST + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)" + PAGE,
    LIST + " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
    # 12..15 the capped counts
    "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s",
    "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s",
    "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s",
    "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s",
    # 16 FEED ($1 viewer, $2 limit, $3 offset), 17 its count
    LIST + " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL " \
           "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x " \
           "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC",
    "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s",
    # 18 ARTICLE_BY_SLUG ($1 viewer, $2 slug), 19 ARTICLE_BY_ID ($1 viewer, $2 id)
    FULL + " WHERE a.slug = $2",
    FULL + " WHERE a.id = $2",
    # 20 ARTICLE_NEW ($1 viewer): the article this transaction just inserted
    FULL + " WHERE a.id = " + NEW_ID,
    # 21 INSERT_ARTICLE ($1 author, $2 title, $3 description, $4 body)
    "INSERT INTO articles (id, slug, author_id, title, description, body) " \
    "SELECT n.id, #{SLUGIFY} || '-' || n.id, $1, $2, $3, $4 " \
    "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
    # 22 INSERT_TAGS ($1 text[]), 23 INSERT_ARTICLE_TAGS ($1 text[])
    "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
    "INSERT INTO article_tags (article_id, tag_id) SELECT #{NEW_ID}, t.id FROM tags t WHERE t.name = ANY($1::text[])",
    # 24 UPDATE_ARTICLE ($1 slug, $2 title, $3 description, $4 body, $5 viewer): the
    # owner lookup, and the update only if the viewer is the author
    "WITH x AS (SELECT id, author_id FROM articles WHERE slug = $1), " \
    "u AS (UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), " \
    "body = COALESCE($4, body), slug = CASE WHEN $2::text IS NULL THEN slug ELSE #{SLUGIFY} || '-' || id END, " \
    "updated_at = now() WHERE id = (SELECT id FROM x WHERE author_id = $5)) " \
    "SELECT id, author_id FROM x",
    # 25 DELETE_ARTICLE ($1 slug, $2 viewer)
    "WITH x AS (SELECT id, author_id FROM articles WHERE slug = $1), " \
    "d AS (DELETE FROM articles WHERE id = (SELECT id FROM x WHERE author_id = $2)) " \
    "SELECT author_id FROM x",
    # 26 FAVORITE ($1 viewer, $2 slug), 27 UNFAVORITE
    "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING",
    "DELETE FROM favorites f USING articles a WHERE a.slug = $2 AND f.article_id = a.id AND f.user_id = $1",
    # 28 ARTICLE_ID ($1 slug)
    "SELECT id FROM articles WHERE slug = $1",
    # 29 COMMENTS ($1 viewer, $2 slug)
    "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following " \
    "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = #{BY_SLUG} " \
    "ORDER BY c.created_at DESC, c.id DESC LIMIT 100",
    # 30 ADD_COMMENT ($1 slug, $2 author, $3 body)
    "WITH a AS (SELECT id FROM articles WHERE slug = $1), " \
    "c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a " \
    "RETURNING id, body, created_at, updated_at, author_id) " \
    "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
    # 31 DELETE_COMMENT ($1 comment id, $2 slug, $3 viewer)
    "WITH x AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2), " \
    "d AS (DELETE FROM comments WHERE id = (SELECT id FROM x WHERE author_id = $3)) " \
    "SELECT author_id FROM x",
    # 32 B_USER ($1 ids)
    "SELECT r.n, #{USER} FROM unnest($1::int8[]) WITH ORDINALITY r(v, n) JOIN users u ON u.id = r.v ORDER BY r.n",
    # 33 B_PROFILE ($1 viewers, $2 usernames)
    "SELECT r.n, u.id, u.username, u.bio, u.image, " \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) " \
    "FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v, s, n) JOIN users u ON u.username = r.s ORDER BY r.n",
    # 34..37 B_LIST by filter ($1 viewers, $2 limits, $3 offsets, $4 filter values)
    pages("$1::int8[], $2::int8[], $3::int8[]", "v, l, o", "l, o",
      "SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT k.l OFFSET k.o", "p.l = r.l AND p.o = r.o"),
    pages(LARGS, "v, l, o, s", "l, o, s",
      "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = #{TAG_ID} ORDER BY at.article_id DESC LIMIT k.l OFFSET k.o", LON),
    pages(LARGS, "v, l, o, s", "l, o, s",
      "SELECT a.id FROM articles a WHERE a.author_id = #{USER_NAME} ORDER BY a.id DESC LIMIT k.l OFFSET k.o", LON),
    pages(LARGS, "v, l, o, s", "l, o, s",
      "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = #{USER_NAME} ORDER BY f.article_id DESC LIMIT k.l OFFSET k.o", LON),
    # 38..41 their counts ($1 request count for the global list, else $1 filter values)
    "SELECT n, x.c FROM generate_series(1, $1::int) n, " \
    "(SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) z) x(c) ORDER BY n",
    counts("text", "s", "SELECT 1 FROM article_tags at WHERE at.tag_id = #{TAG_ID}"),
    counts("text", "s", "SELECT 1 FROM articles a WHERE a.author_id = #{USER_NAME}"),
    counts("text", "s", "SELECT 1 FROM favorites f WHERE f.user_id = #{USER_NAME}"),
    # 42 B_FEED ($1 viewers, $2 limits, $3 offsets), 43 its count ($1 viewers)
    pages("$1::int8[], $2::int8[], $3::int8[]", "v, l, o", "v, l, o",
      "SELECT x.id FROM follows fo CROSS JOIN LATERAL " \
      "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT k.l + k.o) x " \
      "WHERE fo.follower_id = k.v ORDER BY x.id DESC LIMIT k.l OFFSET k.o", "p.v = r.v AND p.l = r.l AND p.o = r.o"),
    counts("int8", "v", "SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = k.v)"),
    # 44 B_ARTICLE ($1 viewers, $2 slugs)
    "WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v, s, n)), " \
    "e AS MATERIALIZED (SELECT x.* FROM (SELECT DISTINCT s FROM r) k CROSS JOIN LATERAL " \
    "(SELECT #{ENRICH} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = k.s OFFSET 0) x) " \
    "SELECT #{FULL_OUT} FROM r JOIN e ON e.slug = r.s ORDER BY r.n",
    # 45 B_ARTICLE_ID ($1 slugs), 46 B_COMMENTS ($1 viewers, $2 slugs; following flags in one
    # follows range scan per viewer)
    "SELECT r.n, a.id FROM unnest($1::text[]) WITH ORDINALITY r(s, n) JOIN articles a ON a.slug = r.s ORDER BY r.n",
    "WITH r AS (SELECT * FROM unnest($1::int8[], $2::text[]) WITH ORDINALITY r(v, s, n)), " \
    "c AS MATERIALIZED (SELECT k.s, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image " \
    "FROM (SELECT DISTINCT s FROM r) k CROSS JOIN LATERAL (SELECT a.id FROM articles a WHERE a.slug = k.s OFFSET 0) a " \
    "CROSS JOIN LATERAL (SELECT * FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c " \
    "CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image FROM users u WHERE u.id = c.author_id OFFSET 0) u), " \
    "p AS MATERIALIZED (SELECT r.v, array_agg(DISTINCT c.author_id) AS aa FROM r JOIN c ON c.s = r.s " \
    "WHERE r.v > 0 GROUP BY r.v), " \
    "f AS MATERIALIZED (SELECT p.v, fo.followee_id FROM p CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo " \
    "WHERE fo.follower_id = p.v AND fo.followee_id = ANY(p.aa)) fo) " \
    "SELECT r.n, c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, f.v IS NOT NULL " \
    "FROM r JOIN c ON c.s = r.s LEFT JOIN f ON f.v = r.v AND f.followee_id = c.author_id " \
    "ORDER BY r.n, c.created_at DESC, c.id DESC",
    MIXED, SHARED_ENRICH, SHARED_FAVORITES, SHARED_FOLLOWS,
  ]

  TAGS            =  0
  USER_BY_ID      =  1
  LOGIN           =  2
  REGISTER        =  3
  UPDATE_USER     =  4
  PROFILE         =  5
  FOLLOW          =  6
  UNFOLLOW        =  7
  LIST_ALL        =  8 # + filter (0 none, 1 tag, 2 author, 3 favorited)
  COUNT_ALL       = 12 # + filter
  FEED            = 16
  FEED_COUNT      = 17
  ARTICLE_BY_SLUG = 18
  ARTICLE_BY_ID   = 19
  ARTICLE_NEW     = 20
  INSERT_ARTICLE  = 21
  INSERT_TAGS     = 22
  INSERT_ART_TAGS = 23
  UPDATE_ARTICLE  = 24
  DELETE_ARTICLE  = 25
  FAVORITE        = 26
  UNFAVORITE      = 27
  ARTICLE_ID      = 28
  COMMENTS        = 29
  ADD_COMMENT     = 30
  DELETE_COMMENT  = 31
  B_USER          = 32
  B_PROFILE       = 33
  B_LIST          = 34 # + filter
  B_COUNT         = 38 # + filter
  B_FEED          = 42
  B_FEED_COUNT    = 43
  B_ARTICLE       = 44
  B_ARTICLE_ID    = 45
  B_COMMENTS      = 46
  B_MIXED         = 47
  SHARED_ARTICLES = 48
  SHARED_FAV      = 49
  SHARED_FOLLOW   = 50
end
