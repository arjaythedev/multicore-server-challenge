defmodule Conduit.Sql do
  @moduledoc false
  # Same results as SPEC.md's reference SQL, in fewer statements: a list page and its capped count are one
  # statement, slug lookups fold into the statement that needs them, and writes return the response row themselves.
  # `$1` is the viewer wherever a statement has one. Explicit casts stand in for the parameter types a driver that
  # declares them would send.

  @slugify "trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g')))"

  # Each tag name by primary key: a join lets the planner hash all 200 tags for every article row.
  @tag_list "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name FROM article_tags at " <>
              "WHERE at.article_id = a.id ORDER BY 1)"
  @tail_head "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " <>
               "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, " <>
               "u.username, u.bio, u.image, "
  @tail @tail_head <>
          "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following"

  # Column order is what Conduit.Handler's article writers read.
  @list_cols "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, #{@tag_list} AS tag_list, #{@tail}"
  @full_cols "a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, #{@tag_list} AS tag_list, #{@tail}"
  # A feed row's author was reached through the viewer's follows row in this same statement snapshot.
  @feed_cols "a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, COALESCE(pt.names, '{}'::text[]) AS tag_list, " <>
               "#{@tail_head}true AS following"

  # The LEFT JOIN LATERAL keeps the count row when the page is empty (then every page column is NULL). `count` is
  # a scalar expression: the list's count capped at 1000.
  list_page = fn count, page_where, page_tail, cols ->
    "WITH c AS (SELECT #{count} AS n) " <>
      "SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT #{cols} FROM articles a JOIN users u ON u.id = a.author_id " <>
      "#{page_where} #{page_tail}) p ON true ORDER BY p.id DESC"
  end

  # Capped counts: "is there a 1000th row?" walks the same index entries as counting them but skips aggregating
  # them; only lists that usually have 1000+ rows ask it first (from rust-tokio-Scooter1337 / csharp-sockets-jh-d).
  capped = fn rows -> "(SELECT count(*) FROM (#{rows} LIMIT 1000) s)" end

  at_least_1000 = fn rows ->
    "CASE WHEN EXISTS (#{rows} OFFSET 999) THEN 1000::bigint ELSE #{capped.(rows)} END"
  end

  # A page of ids (`ids` selects `id`, newest first), cut at a constant 100 (the API's maximum limit) before the
  # request's own limit: generic plans then expect at most 100 rows instead of a tenth of the table (after
  # rust-tokio-Scooter1337's "API-bounded pages").
  bounded = fn ids ->
    "SELECT b.id FROM (#{ids} LIMIT 100 OFFSET $3) b ORDER BY b.id DESC LIMIT $2"
  end

  @list_all list_page.(
              at_least_1000.("SELECT 1 FROM articles a ORDER BY a.id"),
              "WHERE a.id IN (#{bounded.("SELECT a2.id FROM articles a2 ORDER BY a2.id DESC")})",
              "ORDER BY a.id DESC",
              @list_cols
            )

  @list_tag list_page.(
              at_least_1000.(
                "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)"
              ),
              "WHERE a.id IN (#{bounded.("SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC")})",
              "ORDER BY a.id DESC",
              @list_cols
            )

  @list_author list_page.(
                 capped.(
                   "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)"
                 ),
                 # not bounded: as a direct index scan this page measured 7% cheaper than through IN (...)
                 "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)",
                 "ORDER BY a.id DESC LIMIT $2 OFFSET $3",
                 @list_cols
               )

  @list_favorited list_page.(
                    capped.(
                      "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)"
                    ),
                    "WHERE a.id IN (#{bounded.("SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC")})",
                    "ORDER BY a.id DESC",
                    @list_cols
                  )

  # $4 = limit + offset, saturated by the caller so a huge offset can't overflow bigint.
  @feed_page_ids "SELECT x.id FROM follows fo CROSS JOIN LATERAL " <>
                   "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x " <>
                   "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3"

  # OFFSET 0 keeps generic-plan row estimates from turning page-scoped tag probes into a whole-table scan.
  # The count takes the followees as an array: one index scan over articles_author_idx for all of them.
  @feed "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id = " <>
          "ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)) LIMIT 1000) s), " <>
          "page_ids AS MATERIALIZED (#{@feed_page_ids}), " <>
          "page_tags AS (SELECT at.article_id, array_agg(t.name ORDER BY t.name) AS names FROM page_ids " <>
          "CROSS JOIN LATERAL (SELECT article_id, tag_id FROM article_tags WHERE article_id = page_ids.id OFFSET 0) at " <>
          "JOIN tags t ON t.id = at.tag_id GROUP BY at.article_id) " <>
          "SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT #{@feed_cols} " <>
          "FROM articles a JOIN users u ON u.id = a.author_id LEFT JOIN page_tags pt ON pt.article_id = a.id " <>
          "WHERE a.id IN (SELECT id FROM page_ids) ORDER BY a.id DESC) p ON true ORDER BY p.id DESC"

  @article_by_slug "SELECT #{@full_cols} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2"

  # No row = unknown article; one row with NULL x.id = no comments.
  @comments "SELECT a.id, x.id, x.body, x.created_at, x.updated_at, x.username, x.bio, x.image, x.following " <>
              "FROM articles a LEFT JOIN LATERAL ( " <>
              "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " <>
              "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following " <>
              "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id " <>
              "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true " <>
              "WHERE a.slug = $2 ORDER BY x.created_at DESC, x.id DESC"

  @profile "SELECT u.id, u.username, u.bio, u.image, " <>
             "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following " <>
             "FROM users u WHERE u.username = $2"

  # Data-modifying CTEs run even when unreferenced.
  @follow "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2::text), " <>
            "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1::bigint, t.id FROM t ON CONFLICT DO NOTHING) " <>
            "SELECT t.username, t.bio, t.image FROM t"

  @unfollow "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2::text), " <>
              "w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = $1::bigint AND fo.followee_id = t.id) " <>
              "SELECT t.username, t.bio, t.image FROM t"

  # The count subquery runs on the statement's snapshot, which can't see the CTE's own write, so the written row
  # count is added back (or subtracted).
  @fav_tail "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
  @fav_head "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " <>
              "#{@tag_list}, "
  @fav_end "u.username, u.bio, u.image, " <>
             "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) " <>
             "FROM t JOIN articles a ON a.id = t.id JOIN users u ON u.id = a.author_id"

  @favorite "WITH t AS (SELECT id FROM articles WHERE slug = $2::text), " <>
              "w AS (INSERT INTO favorites (user_id, article_id) SELECT $1::bigint, t.id FROM t ON CONFLICT DO NOTHING RETURNING 1) " <>
              @fav_head <> "#{@fav_tail} + (SELECT count(*) FROM w), true, " <> @fav_end

  @unfavorite "WITH t AS (SELECT id FROM articles WHERE slug = $2::text), " <>
                "w AS (DELETE FROM favorites f USING t WHERE f.user_id = $1::bigint AND f.article_id = t.id RETURNING 1) " <>
                @fav_head <> "#{@fav_tail} - (SELECT count(*) FROM w), false, " <> @fav_end

  @comment_create "WITH c AS (INSERT INTO comments (article_id, author_id, body) " <>
                    "SELECT a.id, $1::bigint, $3::text FROM articles a WHERE a.slug = $2::text " <>
                    "RETURNING id, body, created_at, updated_at, author_id) " <>
                    "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image " <>
                    "FROM c JOIN users u ON u.id = c.author_id"

  # Deletes only the viewer's own comment; the probe tells 404 from 403 after a 0-row delete.
  @comment_delete "DELETE FROM comments c USING articles a " <>
                    "WHERE c.id = $2 AND a.id = c.article_id AND a.slug = $3 AND c.author_id = $1 RETURNING c.id"
  @comment_probe "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2"

  @article_delete "DELETE FROM articles WHERE slug = $2 AND author_id = $1 RETURNING id"
  @article_probe "SELECT author_id FROM articles WHERE slug = $1"

  # The CTE is named `a` so the full column list applies to the updated row.
  @article_update "WITH a AS (UPDATE articles SET title = COALESCE($3::text, title), description = COALESCE($4::text, description), " <>
                    "body = COALESCE($5::text, body), " <>
                    "slug = CASE WHEN $3::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($3::text, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, " <>
                    "updated_at = now() WHERE slug = $2 AND author_id = $1 " <>
                    "RETURNING id, slug, title, description, body, created_at, updated_at, author_id) " <>
                    "SELECT #{@full_cols} FROM a JOIN users u ON u.id = a.author_id"

  # Article creation. Without tags it is one statement: the new row is read back through the CTE's RETURNING.
  # A new article has no favorites, so those columns are literals.
  @insert_article "INSERT INTO articles (id, slug, author_id, title, description, body) " <>
                    "SELECT n.id, #{@slugify} || '-' || n.id, $1::bigint, $2::text, $3::text, $4::text " <>
                    "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n"

  @new_row_tail "0::bigint, false, u.username, u.bio, u.image, " <>
                  "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) "

  @article_create_plain "WITH a AS (#{@insert_article} RETURNING id, slug, title, description, body, created_at, updated_at, author_id) " <>
                          "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, ARRAY[]::text[], " <>
                          @new_row_tail <> "FROM a JOIN users u ON u.id = a.author_id"

  # With tags: two statements sent together as one implicit transaction (one round trip). The first inserts missing
  # tags, sorted, so concurrent creates lock new tag keys in the same order (no deadlock). The second takes a fresh
  # snapshot (READ COMMITTED), so it sees those tags, and those another create committed while the first waited on
  # them; it inserts the article, links the tags and reads the article back.
  @tags_upsert "INSERT INTO tags (name) SELECT x.n FROM (SELECT DISTINCT n FROM unnest($1::text[]) AS n ORDER BY n) x " <>
                 "ON CONFLICT (name) DO NOTHING"

  @article_create_tagged "WITH a AS (#{@insert_article} RETURNING id, slug, title, description, body, created_at, updated_at, author_id), " <>
                           "ins AS (INSERT INTO article_tags (article_id, tag_id) " <>
                           "SELECT a.id, t.id FROM a, tags t WHERE t.name = ANY($5::text[]) RETURNING tag_id) " <>
                           "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " <>
                           "ARRAY(SELECT t.name FROM ins JOIN tags t ON t.id = ins.tag_id ORDER BY t.name), " <>
                           @new_row_tail <> "FROM a JOIN users u ON u.id = a.author_id"

  @user_insert "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"
  @user_by_email "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
  @user_by_id "SELECT id, username, email, bio, image FROM users WHERE id = $1"
  @user_update "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " <>
                 "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " <>
                 "WHERE id = $1 RETURNING id, username, email, bio, image"

  @statements [
    list_all: @list_all,
    list_tag: @list_tag,
    list_author: @list_author,
    list_favorited: @list_favorited,
    feed: @feed,
    article_by_slug: @article_by_slug,
    comments: @comments,
    tags: "SELECT ARRAY(SELECT name FROM tags ORDER BY name)",
    profile: @profile,
    follow: @follow,
    unfollow: @unfollow,
    favorite: @favorite,
    unfavorite: @unfavorite,
    comment_create: @comment_create,
    comment_delete: @comment_delete,
    comment_probe: @comment_probe,
    article_delete: @article_delete,
    article_probe: @article_probe,
    article_update: @article_update,
    article_create_plain: @article_create_plain,
    tags_upsert: @tags_upsert,
    article_create_tagged: @article_create_tagged,
    user_insert: @user_insert,
    user_by_email: @user_by_email,
    user_by_id: @user_by_id,
    user_update: @user_update
  ]

  # Batched lists that enrich each distinct article once per execution (after rust-tokio-Scooter1337's shared
  # enrichment): every request's page of ids first, then the tags, favorite count and author of each distinct
  # article on those pages, then the viewer flags per request row, from one hashed read of all the batch's viewers'
  # favorites and follows. Same columns as the single statement, after `r.i`; one row with NULL article columns for
  # an empty page.
  shared_list = fn unnest, count, page ->
    # The enrichment is a LATERAL per distinct id, kept a subquery by OFFSET 0: as a join (which a plain LATERAL is
    # flattened into), a generic plan (no idea how many ids) computes it for the whole articles table and hash-joins
    # that to the page ids afterwards (measured: 2.5 s per execution).
    # OFFSET 0: pulled up, a per-request count (the tag list's) runs once per page row instead (after
    # csharp-sockets-jh-d; measured 30 runs instead of 3)
    "WITH r AS MATERIALIZED (SELECT * FROM #{unnest}), " <>
      "pages AS MATERIALIZED (SELECT r.i, r.v, c.n, p.id FROM r CROSS JOIN LATERAL (SELECT #{count} AS n OFFSET 0) c " <>
      "LEFT JOIN LATERAL (#{page}) p ON true), " <>
      "e AS (SELECT x.* FROM (SELECT DISTINCT id FROM pages WHERE id IS NOT NULL) d CROSS JOIN LATERAL (" <>
      "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id, " <>
      "#{@tag_list} AS tag_list, (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " <>
      "u.username, u.bio, u.image FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = d.id OFFSET 0) x) " <>
      "SELECT p.i, p.n, e.id, e.slug, e.title, e.description, e.created_at, e.updated_at, e.tag_list, " <>
      "e.favorites_count, " <>
      "(p.v, e.id) IN (SELECT f.user_id, f.article_id FROM favorites f WHERE f.user_id IN (SELECT v FROM r)), " <>
      "e.username, e.bio, e.image, " <>
      "(p.v, e.author_id) IN (SELECT fo.follower_id, fo.followee_id FROM follows fo WHERE fo.follower_id IN (SELECT v FROM r)) " <>
      "FROM pages p LEFT JOIN e ON e.id = p.id ORDER BY p.i, e.id DESC"
  end

  # Pages are cut at a constant 100 (the API's maximum limit) before the request's own limit, so a generic plan
  # expects at most 100 rows per request instead of a tenth of the table (which sized a 4 MB hash table for 30 rows);
  # after rust-tokio-Scooter1337's "API-bounded pages".
  @list_all_batch shared_list.(
                    "unnest($1::int8[], $2::int8[], $3::int8[]) WITH ORDINALITY AS r(v, l, o, i)",
                    at_least_1000.("SELECT 1 FROM articles a ORDER BY a.id"),
                    "SELECT b.id FROM (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT 100 OFFSET r.o) b " <>
                      "ORDER BY b.id DESC LIMIT r.l"
                  )

  @list_tag_batch shared_list.(
                    "unnest($1::int8[], $2::int8[], $3::int8[], $4::text[]) WITH ORDINALITY AS r(v, l, o, k, i)",
                    at_least_1000.(
                      "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k)"
                    ),
                    "SELECT b.id FROM (SELECT at.article_id AS id FROM article_tags at " <>
                      "WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = r.k) " <>
                      "ORDER BY at.article_id DESC LIMIT 100 OFFSET r.o) b ORDER BY b.id DESC LIMIT r.l"
                  )

  @doc """
  A hand-written batched variant to use instead of the generated one (Conduit.Pg.Conn), or nil. Its array parameters
  follow the single statement's parameters in order, and its rows are `r.i` then the single statement's columns.
  """
  def batched(:list_all), do: @list_all_batch
  def batched(:list_tag), do: @list_tag_batch
  def batched(_), do: nil

  @doc """
  The reads concurrent requests may share an execution of (see Conduit.Pg.Conn): every hot read. Postgres computes a
  subquery that doesn't depend on the request once per execution, as the #1 entry also does.
  """
  def batchable,
    do: [
      :list_all,
      :list_tag,
      :list_author,
      :list_favorited,
      :feed,
      :article_by_slug,
      :comments,
      :tags,
      :profile,
      :user_by_id
    ]

  @doc "Every statement as {id, prepared statement name, sql}: each connection prepares all of them at startup."
  def all, do: for({{id, sql}, i} <- Enum.with_index(@statements), do: {id, "s#{i}", sql})
end
