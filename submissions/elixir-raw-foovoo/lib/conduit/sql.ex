defmodule Conduit.Sql do
  @moduledoc false
  # Same results as SPEC.md's reference SQL, in fewer statements: a list page and its capped count are one
  # statement, slug lookups fold into the statement that needs them, and writes return the response row themselves.
  # `$1` is the viewer wherever a statement has one. Explicit casts stand in for the parameter types a driver that
  # declares them would send.

  @slugify "trim(both '-' from lower(regexp_replace($2::text, '[^A-Za-z0-9]+', '-', 'g')))"

  @tag_list "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)"
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

  # The LEFT JOIN LATERAL keeps the count row when the page is empty (then every page column is NULL).
  list_page = fn count, page_where, page_tail, cols ->
    "WITH c AS (SELECT count(*) AS n FROM (#{count}) s) " <>
      "SELECT c.n, p.* FROM c LEFT JOIN LATERAL (SELECT #{cols} FROM articles a JOIN users u ON u.id = a.author_id " <>
      "#{page_where} #{page_tail}) p ON true ORDER BY p.id DESC"
  end

  @list_all list_page.(
              "SELECT 1 FROM articles a LIMIT 1000",
              "WHERE a.id IN (SELECT a2.id FROM articles a2 ORDER BY a2.id DESC LIMIT $2 OFFSET $3)",
              "ORDER BY a.id DESC",
              @list_cols
            )

  @list_tag list_page.(
              "SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000",
              "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)",
              "ORDER BY a.id DESC",
              @list_cols
            )

  @list_author list_page.(
                 "SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000",
                 "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)",
                 "ORDER BY a.id DESC LIMIT $2 OFFSET $3",
                 @list_cols
               )

  @list_favorited list_page.(
                    "SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) LIMIT 1000",
                    "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)",
                    "ORDER BY a.id DESC",
                    @list_cols
                  )

  # $4 = limit + offset, saturated by the caller so a huge offset can't overflow bigint.
  @feed_page_ids "SELECT x.id FROM follows fo CROSS JOIN LATERAL " <>
                   "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT $4) x " <>
                   "WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3"

  # OFFSET 0 keeps generic-plan row estimates from turning page-scoped tag probes into a whole-table scan.
  @feed "WITH c AS (SELECT count(*) AS n FROM (SELECT 1 FROM articles a WHERE a.author_id IN " <>
          "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s), " <>
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
              "ARRAY(SELECT tg.name FROM article_tags at JOIN tags tg ON tg.id = at.tag_id WHERE at.article_id = a.id ORDER BY tg.name), "
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

  # With tags: a transaction of two statements. Tags are inserted sorted so concurrent creates lock new tag keys in the
  # same order (no deadlock); the second statement links them and reads the article back.
  @article_create_tagged "WITH a AS (#{@insert_article} RETURNING id), " <>
                           "t AS (INSERT INTO tags (name) SELECT x.n FROM (SELECT DISTINCT n FROM unnest($5::text[]) AS n ORDER BY n) x " <>
                           "ON CONFLICT (name) DO NOTHING) SELECT id FROM a"

  @article_link_tags "WITH ins AS (INSERT INTO article_tags (article_id, tag_id) " <>
                       "SELECT $2::bigint, t.id FROM tags t WHERE t.name = ANY($3::text[]) RETURNING tag_id) " <>
                       "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " <>
                       "ARRAY(SELECT t.name FROM ins JOIN tags t ON t.id = ins.tag_id ORDER BY t.name), " <>
                       @new_row_tail <> "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = $2"

  @user_insert "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"
  @user_by_email "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
  @user_by_id "SELECT id, username, email, bio, image FROM users WHERE id = $1"
  @user_update "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " <>
                 "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " <>
                 "WHERE id = $1 RETURNING id, username, email, bio, image"

  def get(:list_all), do: {"s0", @list_all}
  def get(:list_tag), do: {"s1", @list_tag}
  def get(:list_author), do: {"s2", @list_author}
  def get(:list_favorited), do: {"s3", @list_favorited}
  def get(:feed), do: {"s4", @feed}
  def get(:article_by_slug), do: {"s5", @article_by_slug}
  def get(:comments), do: {"s6", @comments}
  def get(:tags), do: {"s7", "SELECT ARRAY(SELECT name FROM tags ORDER BY name)"}
  def get(:profile), do: {"s8", @profile}
  def get(:follow), do: {"s9", @follow}
  def get(:unfollow), do: {"s10", @unfollow}
  def get(:favorite), do: {"s11", @favorite}
  def get(:unfavorite), do: {"s12", @unfavorite}
  def get(:comment_create), do: {"s13", @comment_create}
  def get(:comment_delete), do: {"s14", @comment_delete}
  def get(:comment_probe), do: {"s15", @comment_probe}
  def get(:article_delete), do: {"s16", @article_delete}
  def get(:article_probe), do: {"s17", @article_probe}
  def get(:article_update), do: {"s18", @article_update}
  def get(:article_create_plain), do: {"s19", @article_create_plain}
  def get(:article_create_tagged), do: {"s20", @article_create_tagged}
  def get(:article_link_tags), do: {"s21", @article_link_tags}
  def get(:user_insert), do: {"s22", @user_insert}
  def get(:user_by_email), do: {"s23", @user_by_email}
  def get(:user_by_id), do: {"s24", @user_by_id}
  def get(:user_update), do: {"s25", @user_update}
end
