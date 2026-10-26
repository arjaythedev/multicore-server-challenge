module Conduit
  module SQL
    module_function

    # MS truncates rather than rounds, as the spec wants.
    def timestamp(column) = %(to_char(#{column} AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'))

    def slugify(text) = "trim(both '-' from lower(regexp_replace(#{text}, '[^A-Za-z0-9]+', '-', 'g')))"

    # Looking each name up by primary key, because for a join Postgres picks a hash join over all 200 tags.
    def tag_list(article) = <<~SQL
      ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at
             WHERE at.article_id = #{article}.id ORDER BY 1)
    SQL

    def following(viewer, author_id) =
      "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = #{viewer} AND fo.followee_id = #{author_id})"

    def profile(user, following:) =
      "json_build_object('username', #{user}.username, 'bio', #{user}.bio, 'image', #{user}.image, 'following', #{following})"

    def article(viewer:, body:,
                favorited: "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = #{viewer})",
                favorites_count: "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)")
      <<~SQL
        json_build_object(
          'slug', a.slug, 'title', a.title, 'description', a.description, #{"'body', a.body," if body}
          'tagList', #{tag_list("a")},
          'createdAt', #{timestamp("a.created_at")}, 'updatedAt', #{timestamp("a.updated_at")},
          'favorited', #{favorited}, 'favoritesCount', #{favorites_count},
          'author', #{profile("u", following: following("#{viewer}", "a.author_id"))})
      SQL
    end

    LIST_COLUMNS = "a.id, a.slug, a.title, a.description, a.author_id, a.created_at, a.updated_at"

    # Parameters going into json_build_object are cast, since it takes `any` and Postgres can't infer their type.
    def listing(page, count) = <<~SQL
      SELECT json_build_object(
        'articles', COALESCE((SELECT json_agg(#{article(viewer: "$1::bigint", body: false)} ORDER BY a.id DESC)
                                FROM (#{page}) a JOIN users u ON u.id = a.author_id), '[]'),
        'articlesCount', (SELECT count(*) FROM (#{count}) s))::text
    SQL

    USER_COLUMNS = "id, username, email, bio, image"

    STATEMENTS = {
      tags: <<~SQL,
        SELECT json_build_object('tags', COALESCE(json_agg(name ORDER BY name), '[]'))::text FROM tags
      SQL

      # Ruby builds the user responses, since they include a token.
      register: "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING #{USER_COLUMNS}",
      login: "SELECT #{USER_COLUMNS}, password_hash FROM users WHERE email = $1",
      current_user: "SELECT #{USER_COLUMNS} FROM users WHERE id = $1",
      update_user: <<~SQL,
        UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                         password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
         WHERE id = $1
        RETURNING #{USER_COLUMNS}
      SQL

      profile: <<~SQL,
        SELECT json_build_object('profile', #{profile("u", following: following("$1::bigint", "u.id"))})::text
          FROM users u WHERE u.username = $2
      SQL
      follow: <<~SQL,
        WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
             f AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM u ON CONFLICT DO NOTHING)
        SELECT json_build_object('profile', #{profile("u", following: "true")})::text FROM u
      SQL
      unfollow: <<~SQL,
        WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
             f AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM u))
        SELECT json_build_object('profile', #{profile("u", following: "false")})::text FROM u
      SQL

      list_all: listing(
        "SELECT #{LIST_COLUMNS} FROM articles a ORDER BY a.id DESC LIMIT $2 OFFSET $3",
        "SELECT 1 FROM articles a LIMIT 1000"
      ),
      list_tag: listing(
        <<~PAGE,
          SELECT #{LIST_COLUMNS} FROM articles a
           WHERE a.id IN (SELECT at.article_id FROM article_tags at
                           WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4::text)
                           ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)
        PAGE
        "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4::text) LIMIT 1000"
      ),
      list_author: listing(
        <<~PAGE,
          SELECT #{LIST_COLUMNS} FROM articles a
           WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4::text)
           ORDER BY a.id DESC LIMIT $2 OFFSET $3
        PAGE
        "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4::text) LIMIT 1000"
      ),
      list_favorited: listing(
        <<~PAGE,
          SELECT #{LIST_COLUMNS} FROM articles a
           WHERE a.id IN (SELECT f.article_id FROM favorites f
                           WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4::text)
                           ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)
        PAGE
        "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4::text) LIMIT 1000"
      ),
      feed: listing(
        <<~PAGE,
          SELECT #{LIST_COLUMNS} FROM articles a
           WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
                            (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                              ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x
                           WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)
        PAGE
        <<~COUNT
          SELECT 1 FROM articles a
           WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000
        COUNT
      ),

      article: <<~SQL,
        SELECT json_build_object('article', #{article(viewer: "$1::bigint", body: true)})::text
          FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2
      SQL
      article_by_id: <<~SQL,
        SELECT json_build_object('article', #{article(viewer: "$1::bigint", body: true)})::text
          FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2
      SQL
      insert_article: <<~SQL,
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, #{slugify("$2")} || '-' || n.id, $1, $2, $3, $4
          FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
        RETURNING id
      SQL
      insert_tags: "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING",
      tag_article: "INSERT INTO article_tags (article_id, tag_id) SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])",
      update_article: <<~SQL,
        WITH target AS (SELECT id, author_id FROM articles WHERE slug = $2),
             a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description),
                                       body = COALESCE($5, body),
                                       slug = CASE WHEN $3::text IS NULL THEN slug ELSE #{slugify("$3")} || '-' || id END,
                                       updated_at = now()
                    WHERE id = (SELECT id FROM target WHERE author_id = $1)
                   RETURNING *)
        SELECT (SELECT json_build_object('article', #{article(viewer: "$1::bigint", body: true)})::text
                  FROM a JOIN users u ON u.id = a.author_id)
          FROM target
      SQL
      delete_article: <<~SQL,
        WITH target AS (SELECT id, author_id FROM articles WHERE slug = $2),
             d AS (DELETE FROM articles WHERE id = (SELECT id FROM target WHERE author_id = $1))
        SELECT author_id = $1 FROM target
      SQL

      # The statement's own snapshot can't see the favorite it adds or removes, so the count adjusts for it.
      favorite: <<~SQL,
        WITH target AS (SELECT id FROM articles WHERE slug = $2),
             f AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING
                   RETURNING 1)
        SELECT json_build_object('article', #{article(viewer: "$1::bigint", body: true, favorited: "true",
          favorites_count: "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) + (SELECT count(*) FROM f)")})::text
          FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM target)
      SQL
      unfavorite: <<~SQL,
        WITH target AS (SELECT id FROM articles WHERE slug = $2),
             f AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM target) RETURNING 1)
        SELECT json_build_object('article', #{article(viewer: "$1::bigint", body: true, favorited: "false",
          favorites_count: "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) - (SELECT count(*) FROM f)")})::text
          FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM target)
      SQL

      comments: <<~SQL,
        SELECT json_build_object('comments', COALESCE((
          SELECT json_agg(json_build_object(
                   'id', c.id, 'createdAt', #{timestamp("c.created_at")}, 'updatedAt', #{timestamp("c.updated_at")},
                   'body', c.body, 'author', #{profile("u", following: following("$1::bigint", "c.author_id"))})
                 ORDER BY c.created_at DESC, c.id DESC)
            FROM (SELECT * FROM comments c WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c
            JOIN users u ON u.id = c.author_id), '[]'))::text
          FROM articles a WHERE a.slug = $2
      SQL
      add_comment: <<~SQL,
        WITH target AS (SELECT id FROM articles WHERE slug = $2),
             c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $1, $3 FROM target
                   RETURNING id, body, created_at, updated_at, author_id)
        SELECT json_build_object('comment', json_build_object(
                 'id', c.id, 'createdAt', #{timestamp("c.created_at")}, 'updatedAt', #{timestamp("c.updated_at")},
                 'body', c.body, 'author', #{profile("u", following: "false")}))::text
          FROM c JOIN users u ON u.id = c.author_id
      SQL
      delete_comment: <<~SQL,
        WITH target AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
                         WHERE c.id = $3 AND a.slug = $2),
             d AS (DELETE FROM comments WHERE id = (SELECT id FROM target WHERE author_id = $1))
        SELECT author_id = $1 FROM target
      SQL
    }.transform_values(&:freeze).freeze

    READS = %i[
      tags login current_user profile list_all list_tag list_author list_favorited feed article article_by_id comments
    ].freeze

    MERGEABLE_PARAM_TYPES = {
      tags: [],
      profile: %w[bigint text],
      list_all: %w[bigint bigint bigint],
      list_tag: %w[bigint bigint bigint text],
      list_author: %w[bigint bigint bigint text],
      list_favorited: %w[bigint bigint bigint text],
      feed: %w[bigint bigint bigint],
      article: %w[bigint text],
      comments: %w[bigint text],
    }.freeze

    def merged(sql, param_types)
      return sql if param_types.empty?

      columns = param_types.each_index.map { "p#{it + 1}" }
      arrays = param_types.each_with_index.map { |type, index| "$#{index + 1}::#{type}[]" }
      # Each mergeable statement returns at most one row, so it works as a scalar subquery, and anything in it
      # that doesn't depend on the request (like the count of all articles) runs once for the whole batch.
      <<~SQL
        SELECT (#{sql.strip.gsub(/\$(\d+)/, 'req.p\1')})
          FROM unnest(#{arrays.join(", ")}) WITH ORDINALITY AS req(#{columns.join(", ")}, ord)
         ORDER BY req.ord
      SQL
    end

    MERGED = MERGEABLE_PARAM_TYPES.to_h { |name, types| [name, merged(STATEMENTS.fetch(name), types).freeze] }.freeze
  end
end
