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

    # Favorites. The count subquery runs on the statement's snapshot, which doesn't see the CTE's own
    # insert or delete, so the change is added (or subtracted) from the CTE's RETURNING.
    favorite: "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), " \
              "i AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM a0 ON CONFLICT DO NOTHING RETURNING 1) " \
              "SELECT '{\"article\":' || #{article(body: true, favorited: "true",
                                                   favorites_count: "((SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM i))")}::text || '}' " \
              "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM a0)",
    unfavorite: "WITH a0 AS (SELECT id FROM articles WHERE slug = $2), " \
                "d AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM a0) RETURNING 1) " \
                "SELECT '{\"article\":' || #{article(body: true, favorited: "false",
                                                     favorites_count: "((SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM d))")}::text || '}' " \
                "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM a0)",

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

  # Per connection: no JIT (a list's generic plan estimated enough rows to trigger it, and compiling took
  # far longer than running), and generic plans from the first execution (no replanning per call).
  SETUP = ["SET jit = off", "SET plan_cache_mode = force_generic_plan", "SET TIME ZONE 'UTC'"].freeze
end
