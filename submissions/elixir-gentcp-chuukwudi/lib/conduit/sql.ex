defmodule Conduit.SQL do
  @moduledoc """
  All SQL. The reference statements in SPEC.md define the answers; these are rewritten to cost Postgres less.

  Reads are batched (Conduit.PG.Batch): the per-request query is the inner side of a LATERAL join over the
  unnested parameters of every queued request of that kind, r(i = request index, v = viewer, l = limit,
  o = offset, k = key), and each row comes back tagged with r.i. The query still runs once per request, in that
  statement's snapshot, while the request is being served: subqueries that use no request parameter are tied to
  the request row (`r.i >= 0`) so Postgres evaluates them per request, Memoize is off for the session, and nothing
  one request reads is handed to another. A batch only shares per-statement costs (protocol round trip, executor
  start-up, snapshot, transaction).

  Writes are single statements (one implicit transaction each), except favorite/unfavorite, which pipeline the
  write and the read-back into one Sync (one transaction).
  """

  # ---------- shared fragments ----------

  # Tag names are fetched by primary key per article_tags row; when the database collates in byte order the app
  # sorts the (1-4) names itself, which saves Postgres a sort node per article.
  defp tags(a, app_sorts) do
    order = if app_sorts, do: "", else: " ORDER BY 1"

    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at " <>
      "WHERE at.article_id = #{a}.id#{order})"
  end

  defp following(v, a),
    do: "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = #{v} AND fo.followee_id = #{a}.author_id)"

  # created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following
  defp tail(v, a, follow_expr, app_sorts) do
    "#{a}.created_at, #{a}.updated_at, #{tags(a, app_sorts)}, " <>
      "(SELECT count(*) FROM favorites f WHERE f.article_id = #{a}.id), " <>
      "EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = #{v} AND f.article_id = #{a}.id), " <>
      "u.username, u.bio, u.image, " <> follow_expr
  end

  # Full article columns: slug, title, description, body, + tail
  defp full_cols(v, a, s), do: "#{a}.slug, #{a}.title, #{a}.description, #{a}.body, " <> tail(v, a, following(v, a), s)

  # list columns over a page `a` of (id, slug, title, description, created_at, updated_at, author_id)
  defp list_cols(v, a, follow, s), do: "#{a}.slug, #{a}.title, #{a}.description, " <> tail(v, a, follow, s)

  @page_cols "b.id, b.slug, b.title, b.description, b.created_at, b.updated_at, b.author_id"

  defp unnest(:i), do: "unnest($1::int4[]) AS r(i)"
  defp unnest(:iv), do: "unnest($1::int4[], $2::int8[]) AS r(i, v)"
  defp unnest(:ik), do: "unnest($1::int4[], $2::text[]) AS r(i, k)"
  defp unnest(:ivk), do: "unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)"
  defp unnest(:ivlo), do: "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o)"
  defp unnest(:ivlok), do: "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)"

  def oids(:i), do: [1007]
  def oids(:iv), do: [1007, 1016]
  def oids(:ik), do: [1007, 1009]
  def oids(:ivk), do: [1007, 1016, 1009]
  def oids(:ivlo), do: [1007, 1016, 1007, 1016]
  def oids(:ivlok), do: [1007, 1016, 1007, 1016, 1009]

  defp lateral(layout, inner), do: "SELECT r.i, x.* FROM #{unnest(layout)} CROSS JOIN LATERAL (#{inner}) x"

  # A list kind: the capped count (c.n, evaluated once per request: OFFSET 0 stops it being pulled up into the
  # per-article rows), then the page, LEFT JOINed so that an empty page still returns one row carrying the count.
  # `key_id` resolves the filter key once per request; the count and the page both use c.id.
  defp list(layout, key_id, count, page) do
    "SELECT r.i, c.n, x.* FROM #{unnest(layout)} " <>
      "CROSS JOIN LATERAL (SELECT w.id, #{count} AS n FROM (SELECT #{key_id} AS id OFFSET 0) w OFFSET 0) c " <>
      "LEFT JOIN LATERAL (#{page}) x ON true"
  end

  # ---------- batched reads: {kind, layout, sql} ----------

  def read_kinds(s) do
    [
      # every tag, newest index order (the unique index on name returns them sorted)
      {:tags, :i, "SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM #{unnest(:i)}"},
      {:user, :iv, lateral(:iv, "SELECT u.username, u.email, u.bio, u.image FROM users u WHERE u.id = r.v")},
      {:login, :ik,
       lateral(
         :ik,
         "SELECT u.id, u.username, u.email, u.bio, u.image, u.password_hash FROM users u WHERE u.email = r.k"
       )},
      {:profile, :ivk,
       lateral(
         :ivk,
         "SELECT u.username, u.bio, u.image, " <>
           "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) " <>
           "FROM users u WHERE u.username = r.k"
       )},
      {:article, :ivk,
       lateral(
         :ivk,
         "SELECT #{full_cols("r.v", "a", s)} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.k"
       )},
      # The article (no row = 404), then its newest 100 comments; one row of NULL comment columns when it has none.
      # The viewer's followees are read once per request (~20 index entries) instead of one probe per comment.
      {:comments, :ivk,
       lateral(
         :ivk,
         "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " <>
           "COALESCE(c.author_id = ANY (f.ids), false) " <>
           "FROM articles a " <>
           "CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS ids) f " <>
           "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c " <>
           "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true " <>
           "LEFT JOIN users u ON u.id = c.author_id " <>
           "WHERE a.slug = r.k ORDER BY c.created_at DESC, c.id DESC"
       )},
      # Global list. "At least 1000?" = does a 1000th row exist, walking the primary key from the oldest end (frozen,
      # all-visible pages: an index-only scan with no heap fetches). `+ 0 * r.i` ties it to the request (evaluated
      # per request) without the per-row filter node `WHERE r.i >= 0` would add. The page is cut before anything is
      # joined.
      {:list_all, :ivlo,
       "SELECT r.i, c.n, x.* FROM #{unnest(:ivlo)} " <>
         "CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles c ORDER BY c.id OFFSET 999 + 0 * r.i) " <>
         "THEN 1000::int8 ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END AS n OFFSET 0) c " <>
         "LEFT JOIN LATERAL (SELECT #{list_cols("r.v", "a", following("r.v", "a"), s)} FROM " <>
         "(SELECT #{@page_cols} FROM (SELECT #{@page_cols} FROM articles b ORDER BY b.id DESC LIMIT 100 OFFSET r.o) b " <>
         "ORDER BY b.id DESC LIMIT r.l) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) x ON true"},
      {:list_tag, :ivlok,
       list(
         :ivlok,
         "(SELECT t.id FROM tags t WHERE t.name = r.k)",
         "CASE WHEN EXISTS (SELECT 1 FROM article_tags c WHERE c.tag_id = w.id OFFSET 999) THEN 1000::int8 " <>
           "ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = w.id LIMIT 1000) s) END",
         "SELECT #{list_cols("r.v", "a", following("r.v", "a"), s)} FROM " <>
           "(SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = c.id " <>
           "ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o) p " <>
           "JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
       )},
      {:list_author, :ivlok,
       list(
         :ivlok,
         "(SELECT au.id FROM users au WHERE au.username = r.k)",
         "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = w.id LIMIT 1000) s)",
         "SELECT #{list_cols("r.v", "a", following("r.v", "a"), s)} FROM " <>
           "(SELECT #{@page_cols} FROM articles b WHERE b.author_id = c.id ORDER BY b.id DESC LIMIT r.l OFFSET r.o) a " <>
           "JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
       )},
      {:list_favorited, :ivlok,
       list(
         :ivlok,
         "(SELECT fu.id FROM users fu WHERE fu.username = r.k)",
         "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = w.id LIMIT 1000) s)",
         "SELECT #{list_cols("r.v", "a", following("r.v", "a"), s)} FROM " <>
           "(SELECT f.article_id AS id FROM favorites f WHERE f.user_id = c.id " <>
           "ORDER BY f.article_id DESC LIMIT r.l OFFSET r.o) p " <>
           "JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC"
       )},
      # Feed. Every row's author is reached through the viewer's follows row in this statement's snapshot, so
      # `following` is true by construction. The count walks articles_author_idx in index order for the followees.
      {:list_feed, :ivlo,
       "SELECT r.i, c.n, x.* FROM #{unnest(:ivlo)} " <>
         "CROSS JOIN LATERAL (SELECT count(*) AS n FROM (SELECT 1 FROM articles c WHERE c.author_id = ANY " <>
         "(ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) " <>
         "ORDER BY c.author_id, c.id DESC LIMIT 1000) s OFFSET 0) c " <>
         "LEFT JOIN LATERAL (SELECT #{list_cols("r.v", "a", "true", s)} FROM " <>
         "(SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " <>
         "ORDER BY a2.id DESC LIMIT r.l + LEAST(r.o, 1000000)) x WHERE fo.follower_id = r.v " <>
         "ORDER BY x.id DESC LIMIT r.l OFFSET r.o) p " <>
         "JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) x ON true"}
    ]
  end

  # ---------- writes: {name, sql, param oids} ----------

  @i8 20
  @t 25
  @ta 1009

  def write_stmts(s) do
    [
      {:user_insert,
       "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image",
       [@t, @t, @t]},
      {:user_update,
       "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), " <>
         "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) " <>
         "WHERE id = $1 RETURNING id, username, email, bio, image", [@i8, @t, @t, @t, @t, @t]},
      {:follow,
       "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), " <>
         "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) " <>
         "SELECT username, bio, image FROM t", [@i8, @t]},
      {:unfollow,
       "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), " <>
         "w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) " <>
         "SELECT username, bio, image FROM t", [@i8, @t]},
      # The article, its tags and links in one statement. Existing tags are only read (no update, no lock, no sequence
      # burn); missing ones are inserted in name order (no deadlock between concurrent creates), and DO UPDATE returns
      # the id of one a concurrent create committed after our snapshot. $2 is the slugified title + "-".
      {:article_create,
       "WITH n AS (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id), " <>
         "a AS (INSERT INTO articles (id, slug, author_id, title, description, body) " <>
         "SELECT n.id, $2 || n.id, $1, $3, $4, $5 FROM n " <>
         "RETURNING id, slug, title, description, body, created_at, updated_at, author_id), " <>
         "existing AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY($6::text[])), " <>
         "t AS (INSERT INTO tags (name) SELECT name FROM (SELECT DISTINCT unnest($6::text[]) AS name) names " <>
         "WHERE NOT EXISTS (SELECT 1 FROM existing e WHERE e.name = names.name) ORDER BY name " <>
         "ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name), " <>
         "all_tags AS (SELECT id, name FROM existing UNION ALL SELECT id, name FROM t), " <>
         "x AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, all_tags.id FROM a, all_tags) " <>
         "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " <>
         "ARRAY(SELECT name FROM all_tags ORDER BY name), 0::int8, false, u.username, u.bio, u.image, " <>
         "#{following("$1", "a")} FROM a JOIN users u ON u.id = a.author_id", [@i8, @t, @t, @t, @t, @ta]},
      # author_id of the slug's article (no row = 404), then the updated article when the viewer is its author.
      # $6 is the new slug prefix (slugified title + "-"), NULL when the title is unchanged.
      {:article_update,
       "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), " <>
         "w AS (UPDATE articles a SET title = COALESCE($3, a.title), description = COALESCE($4, a.description), " <>
         "body = COALESCE($5, a.body), slug = CASE WHEN $6::text IS NULL THEN a.slug ELSE $6 || a.id END, " <>
         "updated_at = now() FROM t WHERE a.id = t.id AND t.author_id = $1 " <>
         "RETURNING a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, a.author_id) " <>
         "SELECT t.author_id, #{full_cols("$1", "a", s)} FROM t LEFT JOIN w a ON true LEFT JOIN users u ON u.id = a.author_id",
       [@i8, @t, @t, @t, @t, @t]},
      {:article_delete,
       "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $1), " <>
         "w AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $2)) SELECT author_id FROM t",
       [@t, @i8]},
      {:fav_insert,
       "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING",
       [@i8, @t]},
      {:fav_delete,
       "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)",
       [@i8, @t]},
      {:article_by_slug,
       "SELECT #{full_cols("$1", "a", s)} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2",
       [@i8, @t]},
      {:comment_create,
       "WITH t AS (SELECT id FROM articles WHERE slug = $1), " <>
         "c AS (INSERT INTO comments (article_id, author_id, body) SELECT id, $2, $3 FROM t " <>
         "RETURNING id, body, created_at, updated_at, author_id) " <>
         "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
       [@t, @i8, @t]},
      {:comment_delete,
       "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " <>
         "WHERE c.id = $1 AND a.slug = $2), " <>
         "w AS (DELETE FROM comments WHERE id = (SELECT id FROM t WHERE author_id = $3)) SELECT author_id FROM t",
       [@i8, @t, @i8]}
    ]
  end

  def collation, do: "SELECT datcollate, datlocprovider::text FROM pg_database WHERE datname = current_database()"
end
