use pg = "postgres"

type _Param is pg.FieldDataTypes

primitive _P
  fun none(): Array[_Param] val =>
    recover val Array[_Param] end
  fun one(a: _Param): Array[_Param] val =>
    recover val [as _Param: a] end
  fun two(a: _Param, b: _Param)
    : Array[_Param] val
  =>
    recover val [as _Param: a; b] end
  fun three(a: _Param, b: _Param,
    c: _Param): Array[_Param] val
  =>
    recover val [as _Param: a; b; c] end
  fun four(a: _Param, b: _Param,
    c: _Param, d: _Param)
    : Array[_Param] val
  =>
    recover val [as _Param: a; b; c; d] end
  fun six(a: _Param, b: _Param,
    c: _Param, d: _Param, e: _Param,
    f: _Param): Array[_Param] val
  =>
    recover val [as _Param: a; b; c; d; e; f] end

primitive _SQL
  fun article(full: Bool, source: String = "articles"): String =>
    "SELECT a.id, a.slug, a.title, a.description, "
      + (if full then "a.body, " else "" end)
      + """
        a.created_at, a.updated_at,
        ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
          FROM article_tags at WHERE at.article_id = a.id
          ORDER BY name) AS tag_list,
        (SELECT count(*) FROM favorites f WHERE f.article_id = a.id)
          AS favorites_count,
        EXISTS(SELECT 1 FROM favorites f
          WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
        u.username, u.bio, u.image,
        EXISTS(SELECT 1 FROM follows fo
          WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id)
          AS following
        """
      + " FROM " + source + " a JOIN users u ON u.id = a.author_id "

  fun article_page(filter: String = ""): String =>
    article(false, "(SELECT a.id, a.slug, a.title, a.description, " +
      "a.created_at, a.updated_at, a.author_id FROM articles a " +
      filter + order_page() + ")") + " ORDER BY a.id DESC"

  fun article_list(page: String, count': String): String =>
    "WITH page AS (" + page + "), total AS (" + count' + ") " +
      "SELECT json_build_object('articles', COALESCE((SELECT " +
      "json_agg(json_build_object(" +
      "'slug', p.slug, 'title', p.title, " +
      "'description', p.description, " +
      "'createdAt', to_char(p.created_at AT TIME ZONE 'UTC', " +
      "'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'), " +
      "'updatedAt', to_char(p.updated_at AT TIME ZONE 'UTC', " +
      "'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'), " +
      "'tagList', p.tag_list, 'favoritesCount', p.favorites_count, " +
      "'favorited', p.favorited, 'author', json_build_object(" +
      "'username', p.username, 'bio', p.bio, 'image', p.image, " +
      "'following', p.following)) ORDER BY p.id DESC) FROM page p), " +
      "'[]'::json), 'articlesCount', (SELECT total FROM total))::text"

  fun valid_json(param: String): String =>
    "(CASE WHEN pg_input_is_valid(" + param +
      ", 'jsonb') THEN " + param + " ELSE NULL END)::jsonb"

  fun order_page(): String => " ORDER BY a.id DESC LIMIT $2 OFFSET $3"

  fun insert_article(): String =>
    "WITH input AS (SELECT " + valid_json("$2") + " AS root), " +
    """
    fields AS (SELECT root->'article' AS article FROM input),
    checked AS (SELECT article,
      (jsonb_typeof(article) = 'object'
        AND jsonb_typeof(article->'title') = 'string'
        AND article->>'title' <> ''
        AND jsonb_typeof(article->'description') = 'string'
        AND article->>'description' <> ''
        AND jsonb_typeof(article->'body') = 'string'
        AND article->>'body' <> ''
        AND (article->'tagList' IS NULL
          OR article->'tagList' = 'null'::jsonb
          OR (jsonb_typeof(article->'tagList') = 'array'
            AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(
              CASE WHEN jsonb_typeof(article->'tagList') = 'array'
                THEN article->'tagList' ELSE '[]'::jsonb END) tag
              WHERE jsonb_typeof(tag) <> 'string' OR tag #>> '{}' = ''))))
        IS TRUE AS valid FROM fields),
    a AS (
      INSERT INTO articles (id, slug, author_id, title, description, body)
      SELECT n.id,
        trim(both '-' from lower(regexp_replace(c.article->>'title',
          '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
        $1::bigint, c.article->>'title', c.article->>'description',
        c.article->>'body'
      FROM checked c CROSS JOIN LATERAL
        (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
      WHERE c.valid
      RETURNING id
    ), names AS (SELECT DISTINCT tag #>> '{}' AS name FROM checked c,
      jsonb_array_elements(CASE WHEN jsonb_typeof(c.article->'tagList')
        = 'array' THEN c.article->'tagList' ELSE '[]'::jsonb END) tag
      WHERE c.valid),
    t AS (
      INSERT INTO tags (name) SELECT name FROM names ORDER BY name
      ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id
    ), links AS (
      INSERT INTO article_tags (article_id, tag_id)
      SELECT a.id, t.id FROM a CROSS JOIN t RETURNING article_id
    )
    SELECT id FROM a
    """

  fun article_update_input(): String =>
    "WITH input AS (SELECT " + valid_json("$2") + " AS root), " +
      "fields AS (SELECT root->'article' AS article FROM input) " +
      "SELECT (jsonb_typeof(article) = 'object' " +
      "AND (article->'title' IS NULL OR article->'title' = 'null'::jsonb " +
      "OR (jsonb_typeof(article->'title') = 'string' " +
      "AND article->>'title' <> '')) " +
      "AND (article->'description' IS NULL " +
      "OR article->'description' = 'null'::jsonb " +
      "OR (jsonb_typeof(article->'description') = 'string' " +
      "AND article->>'description' <> '')) " +
      "AND (article->'body' IS NULL OR article->'body' = 'null'::jsonb " +
      "OR (jsonb_typeof(article->'body') = 'string' " +
      "AND article->>'body' <> ''))) IS TRUE, a.id, a.author_id, " +
      "article->>'title', article->>'description', article->>'body' " +
      "FROM fields LEFT JOIN articles a ON a.slug = $1"

  fun comment_input(): String =>
    "WITH input AS (SELECT " + valid_json("$2") + " AS root), " +
      "fields AS (SELECT root->'comment' AS comment FROM input) " +
      "SELECT (jsonb_typeof(comment) = 'object' " +
      "AND jsonb_typeof(comment->'body') = 'string' " +
      "AND comment->>'body' <> '') IS TRUE, a.id, comment->>'body' " +
      "FROM fields LEFT JOIN articles a ON a.slug = $1"

  fun update_article(): String =>
    """
    UPDATE articles SET title = COALESCE($2, title),
      description = COALESCE($3, description), body = COALESCE($4, body),
      slug = CASE WHEN $2::text IS NULL THEN slug ELSE
        trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))
          || '-' || id END, updated_at = now()
    WHERE id = $1
    """

  fun comments(): String =>
    """
    SELECT c.id, c.body, c.created_at, c.updated_at,
      u.username, u.bio, u.image,
      EXISTS(SELECT 1 FROM follows fo
        WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id)
    FROM articles a
    LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at,
      c.author_id FROM comments c WHERE c.article_id = a.id
      ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
    LEFT JOIN users u ON u.id = c.author_id
    WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC
    """

  fun insert_comment(): String =>
    """
    WITH c AS (INSERT INTO comments (article_id, author_id, body)
      VALUES ($1, $2, $3)
      RETURNING id, body, created_at, updated_at, author_id)
    SELECT c.id, c.body, c.created_at, c.updated_at,
      u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id
    """
