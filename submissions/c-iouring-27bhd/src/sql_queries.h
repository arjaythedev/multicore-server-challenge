#ifndef SQL_QUERIES_H
#define SQL_QUERIES_H

#define TAGS_SUBQUERY \
    "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id ORDER BY t.name)"

#define ARTICLE_COMMON_FIELDS \
    "a.created_at, a.updated_at, " TAGS_SUBQUERY " AS tag_list, " \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, " \
    "u.username, u.bio, u.image, " \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following " \
    "FROM articles a JOIN users u ON u.id = a.author_id"

#define ARTICLE_LIST_SELECT "SELECT a.id, a.slug, a.title, a.description, " ARTICLE_COMMON_FIELDS
#define ARTICLE_FULL_SELECT "SELECT a.id, a.slug, a.title, a.description, a.body, " ARTICLE_COMMON_FIELDS

// Lists
#define SQL_LIST_ALL ARTICLE_LIST_SELECT " ORDER BY a.id DESC LIMIT $2 OFFSET $3"
#define SQL_COUNT_ALL "SELECT count(*) FROM (SELECT 1 FROM articles a ORDER BY a.id DESC LIMIT 1000) s"


#define SQL_LIST_BY_TAG ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
#define SQL_COUNT_BY_TAG "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"

#define SQL_LIST_BY_AUTHOR ARTICLE_LIST_SELECT " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3"
#define SQL_COUNT_BY_AUTHOR "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"

#define SQL_LIST_BY_FAVORITE ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
#define SQL_COUNT_BY_FAVORITE "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"

#define SQL_LIST_FEED ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"
#define SQL_COUNT_FEED "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"
// Literal fast-paths (offset=0, limit=10, 5, 20)
#define SQL_LIST_ALL_10_0 ARTICLE_LIST_SELECT " ORDER BY a.id DESC LIMIT 10 OFFSET 0"
#define SQL_LIST_ALL_5_0  ARTICLE_LIST_SELECT " ORDER BY a.id DESC LIMIT 5 OFFSET 0"
#define SQL_LIST_ALL_20_0 ARTICLE_LIST_SELECT " ORDER BY a.id DESC LIMIT 20 OFFSET 0"

#define SQL_LIST_TAG_10_0 ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2) ORDER BY at.article_id DESC LIMIT 10 OFFSET 0) ORDER BY a.id DESC"
#define SQL_LIST_TAG_5_0  ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2) ORDER BY at.article_id DESC LIMIT 5 OFFSET 0) ORDER BY a.id DESC"
#define SQL_LIST_TAG_20_0 ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $2) ORDER BY at.article_id DESC LIMIT 20 OFFSET 0) ORDER BY a.id DESC"

#define SQL_LIST_AUTH_10_0 ARTICLE_LIST_SELECT " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $2) ORDER BY a.id DESC LIMIT 10 OFFSET 0"
#define SQL_LIST_AUTH_5_0  ARTICLE_LIST_SELECT " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $2) ORDER BY a.id DESC LIMIT 5 OFFSET 0"
#define SQL_LIST_AUTH_20_0 ARTICLE_LIST_SELECT " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $2) ORDER BY a.id DESC LIMIT 20 OFFSET 0"

#define SQL_LIST_FAV_10_0 ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $2) ORDER BY f.article_id DESC LIMIT 10 OFFSET 0) ORDER BY a.id DESC"
#define SQL_LIST_FAV_5_0  ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $2) ORDER BY f.article_id DESC LIMIT 5 OFFSET 0) ORDER BY a.id DESC"
#define SQL_LIST_FAV_20_0 ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $2) ORDER BY f.article_id DESC LIMIT 20 OFFSET 0) ORDER BY a.id DESC"

#define SQL_LIST_FEED_10_0 ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT 10) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT 10 OFFSET 0) ORDER BY a.id DESC"
#define SQL_LIST_FEED_5_0  ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT 5) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT 5 OFFSET 0) ORDER BY a.id DESC"
#define SQL_LIST_FEED_20_0 ARTICLE_LIST_SELECT " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT 20) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT 20 OFFSET 0) ORDER BY a.id DESC"


#define SQL_ARTICLE_BY_SLUG ARTICLE_FULL_SELECT " WHERE a.slug = $2"
#define SQL_ARTICLE_BY_CURRVAL ARTICLE_FULL_SELECT " WHERE a.id = currval(pg_get_serial_sequence('articles', 'id'))"
#define SQL_INSERT_ARTICLE_TAGS_CURRVAL "INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])"

#define SQL_LIST_COMMENTS_BY_SLUG "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following FROM comments c JOIN articles a ON a.id = c.article_id JOIN users u ON u.id = c.author_id WHERE a.slug = $2 ORDER BY c.created_at DESC, c.id DESC LIMIT 100"

#define SQL_UPDATE_ARTICLE_FUSED \
    "WITH target AS (SELECT id, author_id FROM articles WHERE slug = $1), " \
    "upd AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), " \
    "slug = CASE WHEN $3::text IS NULL THEN slug ELSE $6 || '-' || id END, updated_at = now() " \
    "WHERE id = (SELECT id FROM target WHERE author_id = $2) RETURNING id, slug, title, description, body, author_id, created_at, updated_at) " \
    "SELECT t.author_id, u.slug, u.title, u.description, u.body, u.created_at, u.updated_at, " \
    "ARRAY(SELECT t2.name FROM article_tags at JOIN tags t2 ON t2.id = at.tag_id WHERE at.article_id = u.id ORDER BY t2.name) AS tag_list, " \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = u.id) AS favorites_count, " \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = u.id AND f.user_id = $2) AS favorited, " \
    "usr.username, usr.bio, usr.image, " \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = u.author_id) AS following " \
    "FROM target t LEFT JOIN upd u ON u.id = t.id LEFT JOIN users usr ON usr.id = u.author_id"

#define SQL_DELETE_ARTICLE_CTE "WITH target AS (SELECT id, author_id FROM articles WHERE slug = $1), del AS (DELETE FROM articles WHERE id = (SELECT id FROM target WHERE author_id = $2) RETURNING id) SELECT t.author_id, (SELECT id FROM del) IS NOT NULL AS was_deleted FROM target t"
#define SQL_DELETE_COMMENT_CTE "WITH target AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2), del AS (DELETE FROM comments WHERE id = (SELECT id FROM target WHERE author_id = $3) RETURNING id) SELECT t.author_id, (SELECT id FROM del) IS NOT NULL AS was_deleted FROM target t"

#define SQL_INSERT_COMMENT_BY_SLUG "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM articles a WHERE a.slug = $1 RETURNING id, body, created_at, updated_at, author_id) SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $2 AND fo.followee_id = c.author_id) AS following FROM c JOIN users u ON u.id = c.author_id"

#define SQL_FAVORITE_INSERT_BY_SLUG "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING"
#define SQL_FAVORITE_DELETE_BY_SLUG "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)"

#define SQL_FOLLOW_BY_USERNAME "WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2), act AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING RETURNING 1) SELECT t.username, t.bio, t.image FROM target t"
#define SQL_UNFOLLOW_BY_USERNAME "WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2), act AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM target) RETURNING 1) SELECT t.username, t.bio, t.image FROM target t"


#define SQL_INSERT_ARTICLE "INSERT INTO articles (id, slug, author_id, title, description, body) SELECT n.id, $5 || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id"
#define SQL_INSERT_TAGS \
    "INSERT INTO tags (name) " \
    "SELECT u.name FROM unnest($1::text[]) AS u(name) " \
    "WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = u.name) " \
    "ORDER BY u.name ON CONFLICT (name) DO NOTHING"
#define SQL_SELECT_ARTICLE_ID "SELECT id FROM articles WHERE slug = $1"

#define SQL_REGISTER_USER "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING RETURNING id, username, email, bio, image"
#define SQL_LOGIN_USER "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"
#define SQL_GET_USER "SELECT id, username, email, bio, image FROM users WHERE id = $1"
#define SQL_UPDATE_USER "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING id, username, email, bio, image"
#define SQL_GET_PROFILE "SELECT u.id, u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following FROM users u WHERE u.username = $2"
#define SQL_LIST_TAGS "SELECT name FROM tags ORDER BY name"

#endif // SQL_QUERIES_H
