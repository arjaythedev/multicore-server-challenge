# frozen_string_literal: true

# Every statement, prepared once per connection. Reads return the response document as one text column,
# built by Postgres (json_build_object, json_agg), so Ruby never decodes rows or encodes JSON on reads.
# Writes are folded into the read that answers them with data-modifying CTEs: one statement, one round
# trip per request. Results match SPEC.md's reference SQL; the comments say where the shape differs.
module SQL
  TS = "YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"" # to_char's MS truncates to milliseconds, as the spec wants

  def self.ts(column) = "to_char(#{column} AT TIME ZONE 'UTC', '#{TS}')"

  # $1 = viewer. The article as an object; `a` and `u` (its author) in scope.
  def self.article(body:, favorited: nil, favorites_count: nil)
    favorited ||= "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)"
    favorites_count ||= "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
    <<~SQL.tr("\n", " ")
      json_build_object('slug', a.slug, 'title', a.title, 'description', a.description,
        #{"'body', a.body," if body}
        'tagList', ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                           FROM article_tags at WHERE at.article_id = a.id ORDER BY 1),
        'createdAt', #{ts("a.created_at")}, 'updatedAt', #{ts("a.updated_at")},
        'favorited', #{favorited}, 'favoritesCount', #{favorites_count},
        'author', json_build_object('username', u.username, 'bio', u.bio, 'image', u.image,
          'following', EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)))
    SQL
  end

  LIST_ITEM = article(body: false)
  FULL = article(body: true)

  # {"articles": [...], "articlesCount": n} from a page subquery `page` (ids, newest first) and a count.
  def self.list(page, count)
    <<~SQL.tr("\n", " ")
      SELECT '{"articles":' || COALESCE((SELECT json_agg(x.j ORDER BY x.id DESC) FROM
               (SELECT a.id, #{LIST_ITEM} AS j FROM articles a JOIN users u ON u.id = a.author_id
                 WHERE a.id IN (#{page})) x)::text, '[]')
          || ',"articlesCount":' || (#{count}) || '}'
    SQL
  end

  # $2 = limit, $3 = offset (bigint), $4 = filter value.
  LIST_ALL = list("SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT $2 OFFSET $3",
                  "SELECT count(*) FROM (SELECT 1 FROM articles LIMIT 1000) s")
  LIST_TAG = list("SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " \
                  "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3",
                  "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = " \
                  "(SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s")
  LIST_AUTHOR = list("SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) " \
                     "ORDER BY a2.id DESC LIMIT $2 OFFSET $3",
                     "SELECT count(*) FROM (SELECT 1 FROM articles a2 WHERE a2.author_id = " \
                     "(SELECT au.id FROM users au WHERE au.username = $4) LIMIT 1000) s")
  LIST_FAVORITED = list("SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " \
                        "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3",
                        "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = " \
                        "(SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000) s")
  FEED = list("SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " \
              "ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3",
              "SELECT count(*) FROM (SELECT 1 FROM articles a2 WHERE a2.author_id IN " \
              "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s")

  SLUGIFY = "trim(both '-' from lower(regexp_replace($T, '[^A-Za-z0-9]+', '-', 'g')))"

  def self.slugify(expr) = SLUGIFY.sub("$T", expr)

  PROFILE = "json_build_object('username', u.username, 'bio', u.bio, 'image', u.image, 'following', %s)"

  STATEMENTS = {
    tags: "SELECT '{\"tags\":' || COALESCE(json_agg(name ORDER BY name)::text, '[]') || '}' FROM tags",

    # Users. $1 = token for the documents that carry the presented token.
    register: "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
    login: "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1",
    user: "SELECT json_build_object('user', json_build_object('email', email, 'token', $2::text, 'username', username, " \
          "'bio', bio, 'image', image))::text FROM users WHERE id = $1",
    update_user: "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " \
                 "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " \
                 "WHERE id = $1 RETURNING json_build_object('user', json_build_object('email', email, 'token', $7::text, " \
                 "'username', username, 'bio', bio, 'image', image))::text",

    # Profiles. $1 = viewer, $2 = username.
    profile: "SELECT json_build_object('profile', #{format(PROFILE, "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 " \
                                                                      "AND fo.followee_id = u.id)")})::text FROM users u WHERE u.username = $2",
    follow: "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), " \
            "i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING) " \
            "SELECT json_build_object('profile', #{format(PROFILE, "true")})::text FROM u",
    unfollow: "WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2), " \
              "d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u)) " \
              "SELECT json_build_object('profile', #{format(PROFILE, "false")})::text FROM u",

    # Articles. $1 = viewer.
    list_all: LIST_ALL,
    list_tag: LIST_TAG,
    list_author: LIST_AUTHOR,
    list_favorited: LIST_FAVORITED,
    feed: FEED,
    article: "SELECT '{\"article\":' || #{FULL}::text || '}' FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
    # Creating runs the spec's transaction as a group: BEGIN, these three, COMMIT, then the select.
    # $1 = author, $2 = title, $3 = description, $4 = body.
    create_article: "INSERT INTO articles (id, slug, author_id, title, description, body) " \
                    "SELECT n.id, #{slugify("$2")} || '-' || n.id, $1, $2, $3, $4 " \
                    "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id",
    create_tags: "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
    tag_article: "INSERT INTO article_tags (article_id, tag_id) " \
                 "SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])",
    created_article: "SELECT '{\"article\":' || #{FULL}::text || '}' FROM articles a JOIN users u ON u.id = a.author_id " \
                     "WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))", # once, as an InitPlan: a bare volatile currval() in WHERE can't use the primary key and scanned every article
    begin: "BEGIN",
    commit: "COMMIT",
    # $1 = viewer, $2 = slug, $3 title, $4 description, $5 body. Returns author_id and, if the viewer is the
    # author, the updated document.
    update_article: "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2), " \
                    "a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), " \
                    "body = COALESCE($5, body), slug = CASE WHEN $3::text IS NULL THEN slug ELSE #{slugify("$3")} || '-' || id END, " \
                    "updated_at = now() WHERE id = (SELECT id FROM a0 WHERE author_id = $1) RETURNING *) " \
                    "SELECT a0.author_id, (SELECT '{\"article\":' || #{FULL}::text || '}' FROM a JOIN users u ON u.id = a.author_id) FROM a0",
    delete_article: "WITH a0 AS (SELECT id, author_id FROM articles WHERE slug = $2), " \
                    "d AS (DELETE FROM articles WHERE id = (SELECT id FROM a0 WHERE author_id = $1)) SELECT author_id FROM a0",

    # Favorites: the write returns only the article's id; the article is then read through the planner
    # (b_articles_id), after the commit, like any other read. Building it here cost twice that.
    favorite: "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), " \
              "i AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM a0 ON CONFLICT DO NOTHING) " \
              "SELECT id FROM a0",
    unfavorite: "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), " \
                "d AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM a0)) " \
                "SELECT id FROM a0",

    # Comments. $1 = viewer, $2 = slug.
    comments: "WITH a0 AS (SELECT id FROM articles WHERE slug = $2) " \
              "SELECT '{\"comments\":' || COALESCE((SELECT json_agg(x.j ORDER BY x.created_at DESC, x.id DESC) FROM " \
              "(SELECT c.id, c.created_at, json_build_object('id', c.id, 'createdAt', #{ts("c.created_at")}, " \
              "'updatedAt', #{ts("c.updated_at")}, 'body', c.body, 'author', #{format(PROFILE, "EXISTS (SELECT 1 FROM follows fo " \
              "WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)")}) AS j " \
              "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a0.id " \
              "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x)::text, '[]') || '}' FROM a0",
    # $1 = author, $2 = slug, $3 = body.
    create_comment: "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), " \
                    "c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $1, $3 FROM a0 " \
                    "RETURNING id, body, created_at, updated_at, author_id) " \
                    "SELECT json_build_object('comment', json_build_object('id', c.id, 'createdAt', #{ts("c.created_at")}, " \
                    "'updatedAt', #{ts("c.updated_at")}, 'body', c.body, 'author', #{format(PROFILE, "false")}))::text " \
                    "FROM c JOIN users u ON u.id = c.author_id",
    # $1 = viewer, $2 = slug, $3 = comment id. Returns the comment's author_id; deletes it if that's the viewer.
    delete_comment: "WITH c0 AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " \
                    "WHERE c.id = $3 AND a.slug = $2), " \
                    "d AS (DELETE FROM comments WHERE id = (SELECT id FROM c0 WHERE author_id = $1)) SELECT author_id FROM c0"
  }.transform_values(&:freeze).freeze

  # --- batched reads (planner.rb) ---------------------------------------------------------------
  # Each statement takes arrays of one batch's *distinct* keys and tags every row with the key's ordinal k,
  # so one execution answers every request of that kind in the batch. Phase A finds what each request is
  # about; phase B enriches the union of the articles phase A returned, once per article. The layout follows
  # node-uwebsockets-zahidcakici (which credits PR #47, rust-epoll-WorriedArrow); the statements here are
  # this entry's own. Results match SPEC.md's reference SQL; where a statement can't order rows within a
  # key, planner.rb restores the order.

  # The count, capped at 1,000, in one pass. (An EXISTS (... OFFSET 999) probe first read every row twice
  # whenever there were fewer than 1,000, which is the usual case for feeds, authors and favorites.)
  def self.capped(rows) = "(SELECT count(*) FROM (#{rows} LIMIT 1000) s)"

  # Article columns after k: id, author_id, slug, title, description, created_at, updated_at
  COLS = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at"
  PAD = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz"

  BATCH = {
    b_tags: "SELECT array_to_json(ARRAY(SELECT name FROM tags ORDER BY name))::text",
    # k, id, username, email, bio, image
    b_users: "SELECT r.k, u.id, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) " \
             "JOIN users u ON u.id = r.id",
    # k, id, username, bio, image
    b_profiles: "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(username, k) " \
                "JOIN users u ON u.username = r.username",
    # k, COLS, body
    b_articles: "SELECT r.k, #{COLS}, a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug",
    b_articles_id: "SELECT r.k, #{COLS}, a.body FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN articles a ON a.id = r.id",
    # k, article id, comment id, body, created_at, updated_at, author_id, username, bio, image (an article
    # without comments gives one row with a NULL comment id: it exists)
    # n numbers each article's comments newest first, so the order survives the join.
    b_comments: "SELECT r.k, a.id, c.id, c.body, c.created_at, c.updated_at, c.author_id, u.username, u.bio, u.image, c.n " \
                "FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug " \
                "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id, " \
                "row_number() OVER (ORDER BY c.created_at DESC, c.id DESC) AS n FROM comments c " \
                "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true " \
                "LEFT JOIN users u ON u.id = c.author_id",
    # Lists: count rows have k <= 0 (-k is the count key, the count in column 1); page rows have k > 0.
    b_global: "SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) s), #{PAD} " \
              "UNION ALL SELECT r.k, #{COLS} FROM unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k) " \
              "CROSS JOIN LATERAL (SELECT * FROM articles a ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
    b_tag: "SELECT -r.k, #{capped("SELECT 1 FROM article_tags at WHERE at.tag_id = t.id")}, #{PAD} " \
           "FROM unnest($1::text[]) WITH ORDINALITY r(tag, k) LEFT JOIN tags t ON t.name = r.tag " \
           "UNION ALL SELECT r.k, #{COLS} FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(tag, lim, off, k) " \
           "JOIN tags t ON t.name = r.tag CROSS JOIN LATERAL (SELECT at.article_id FROM article_tags at WHERE at.tag_id = t.id " \
           "ORDER BY at.article_id DESC LIMIT r.lim OFFSET r.off) p JOIN articles a ON a.id = p.article_id",
    b_author: "SELECT -r.k, #{capped("SELECT 1 FROM articles a WHERE a.author_id = u.id")}, #{PAD} " \
              "FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username " \
              "UNION ALL SELECT r.k, #{COLS} FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) " \
              "JOIN users u ON u.username = r.username CROSS JOIN LATERAL (SELECT * FROM articles a WHERE a.author_id = u.id " \
              "ORDER BY a.id DESC LIMIT r.lim OFFSET r.off) a",
    b_favorited: "SELECT -r.k, #{capped("SELECT 1 FROM favorites f WHERE f.user_id = u.id")}, #{PAD} " \
                 "FROM unnest($1::text[]) WITH ORDINALITY r(username, k) LEFT JOIN users u ON u.username = r.username " \
                 "UNION ALL SELECT r.k, #{COLS} FROM unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(username, lim, off, k) " \
                 "JOIN users u ON u.username = r.username CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = u.id " \
                 "ORDER BY f.article_id DESC LIMIT r.lim OFFSET r.off) p JOIN articles a ON a.id = p.article_id",
    # Feeds: capped counts per distinct viewer (k <= 0), pages per (viewer, limit, offset) (k > 0). A page reads
    # at most limit + offset of each followee's newest ids from articles_author_idx.
    b_feed: "SELECT -r.k, #{capped("SELECT 1 FROM articles a WHERE a.author_id = ANY(ARRAY(SELECT fo.followee_id FROM follows fo " \
                                     "WHERE fo.follower_id = r.v))")}, #{PAD} " \
            "FROM unnest($1::int8[]) WITH ORDINALITY r(v, k) " \
            "UNION ALL SELECT r.k, #{COLS} FROM unnest($2::int8[], $3::int8[], $4::int8[]) WITH ORDINALITY r(v, lim, off, k) " \
            "CROSS JOIN LATERAL (SELECT y.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 " \
            "WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT r.lim + r.off) y " \
            "WHERE fo.follower_id = r.v ORDER BY y.id DESC LIMIT r.lim OFFSET r.off) x JOIN articles a ON a.id = x.id",
    # Shared feeds (planner.rb): the follows of every feed viewer in the batch, and each *distinct* followee
    # read once: its article count (capped at 1,000) and its newest ids, down to the deepest page ($2 =
    # limit + offset) any of its followers asked for. Pages are merged in Ruby; two viewers sharing a
    # followee share its scan.
    b_feed_follows: "SELECT follower_id, followee_id FROM follows WHERE follower_id = ANY($1::int8[])",
    b_feed_scan: "SELECT fo.id, (SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = fo.id LIMIT 1000) s), " \
                 "ARRAY(SELECT a.id FROM articles a WHERE a.author_id = fo.id ORDER BY a.id DESC LIMIT $2::int8) " \
                 "FROM (SELECT DISTINCT followee_id AS id FROM follows WHERE follower_id = ANY($1::int8[])) fo",
    # Phase B for articles phase A only knew by id (shared feeds): 0, COLS, tag ids, favorites count, author.
    b_enrich_rows: "SELECT 0::int8, #{COLS}, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = a.id), " \
                   "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id), u.username, u.bio, u.image " \
                   "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = ANY($1::int8[])",
    # Phase B. One row per distinct article: id, tag ids, favorites count, author username, bio, image.
    b_enrich: "SELECT r.id, ARRAY(SELECT at.tag_id FROM article_tags at WHERE at.article_id = r.id), " \
              "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image " \
              "FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author",
    # Names of every tag those articles carry, in the database's name order (tagList is sorted by name).
    b_tag_names: "SELECT t.id, t.name FROM tags t WHERE t.id IN " \
                 "(SELECT at.tag_id FROM article_tags at WHERE at.article_id = ANY($1::int8[])) ORDER BY t.name",
    # Viewer flags: (0, viewer, article) for each favorited pair asked about, (1, viewer, followee) for each
    # followed pair; each viewer's candidates are one primary-key range scan (= ANY).
    b_flags: "WITH p AS (SELECT x.v, array_agg(x.a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY x.v), " \
             "q AS (SELECT x.v, array_agg(x.u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY x.v) " \
             "SELECT 0::int8, p.v, f.article_id FROM p CROSS JOIN LATERAL " \
             "(SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY(p.aa)) f " \
             "UNION ALL SELECT 1::int8, q.v, fo.followee_id FROM q CROSS JOIN LATERAL " \
             "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY(q.uu)) fo"
  }.transform_values(&:freeze).freeze

  # Per connection: no JIT (a list's generic plan estimated enough rows to trigger it, and compiling took
  # far longer than running), and generic plans from the first execution (no replanning per call).
  SETUP = ["SET jit = off", "SET plan_cache_mode = force_generic_plan", "SET TIME ZONE 'UTC'",
           "SET max_parallel_workers_per_gather = 0"].freeze

  ALL = STATEMENTS.merge(BATCH).freeze
end
