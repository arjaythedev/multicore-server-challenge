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

  SLUGIFY = "trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g')))"
  USER    = "id, username, email, bio, image"
  # currval is volatile: as a scalar subquery it's computed once and the lookup uses the key
  NEW_ID  = "(SELECT currval(pg_get_serial_sequence('articles', 'id')))"
  BY_SLUG = "(SELECT id FROM articles WHERE slug = $2)"

  QUERIES = [
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
  ]
  STATEMENTS          = QUERIES.map { |sql| Rayo::PG::Statement.new(sql) }
  TAGS                = STATEMENTS[0]
  USER_BY_ID          = STATEMENTS[1]
  LOGIN               = STATEMENTS[2]
  REGISTER            = STATEMENTS[3]
  UPDATE_USER         = STATEMENTS[4]
  PROFILE             = STATEMENTS[5]
  FOLLOW              = STATEMENTS[6]
  UNFOLLOW            = STATEMENTS[7]
  LIST_ALL            = STATEMENTS[8]
  LIST_TAG            = STATEMENTS[9]
  LIST_AUTHOR         = STATEMENTS[10]
  LIST_FAVORITED      = STATEMENTS[11]
  COUNT_ALL           = STATEMENTS[12]
  COUNT_TAG           = STATEMENTS[13]
  COUNT_AUTHOR        = STATEMENTS[14]
  COUNT_FAVORITED     = STATEMENTS[15]
  FEED                = STATEMENTS[16]
  COUNT_FEED          = STATEMENTS[17]
  ARTICLE_BY_SLUG     = STATEMENTS[18]
  ARTICLE_BY_ID       = STATEMENTS[19]
  ARTICLE_NEW         = STATEMENTS[20]
  INSERT_ARTICLE      = STATEMENTS[21]
  INSERT_TAGS         = STATEMENTS[22]
  INSERT_ARTICLE_TAGS = STATEMENTS[23]
  UPDATE_ARTICLE      = STATEMENTS[24]
  DELETE_ARTICLE      = STATEMENTS[25]
  FAVORITE            = STATEMENTS[26]
  UNFAVORITE          = STATEMENTS[27]
  ARTICLE_ID          = STATEMENTS[28]
  COMMENTS            = STATEMENTS[29]
  ADD_COMMENT         = STATEMENTS[30]
  DELETE_COMMENT      = STATEMENTS[31]
  LISTS               = {LIST_ALL, LIST_TAG, LIST_AUTHOR, LIST_FAVORITED}
  COUNTS              = {COUNT_ALL, COUNT_TAG, COUNT_AUTHOR, COUNT_FAVORITED}
end
