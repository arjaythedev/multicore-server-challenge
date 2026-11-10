//! SQL query statements and fragment definitions for the Conduit API.

pub const SQL_TAGS: &str = "SELECT name FROM tags ORDER BY name;";

pub const SQL_REGISTER_USER: &str = "\
INSERT INTO users (username, email, password_hash) \
VALUES ($1, $2, $3) \
RETURNING id, username, email, bio, image;";

pub const SQL_LOGIN_USER: &str = "\
SELECT id, username, email, bio, image, password_hash \
FROM users WHERE email = $1;";

pub const SQL_GET_CURRENT_USER: &str = "\
SELECT id, username, email, bio, image FROM users WHERE id = $1;";

pub const SQL_UPDATE_USER: &str = "\
UPDATE users SET \
  email = COALESCE($2, email), \
  username = COALESCE($3, username), \
  password_hash = COALESCE($4, password_hash), \
  bio = COALESCE($5, bio), \
  image = COALESCE($6, image) \
WHERE id = $1 \
RETURNING id, username, email, bio, image;";

pub const SQL_GET_PROFILE: &str = "\
SELECT u.id, u.username, u.bio, u.image, \
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following \
FROM users u WHERE u.username = $2;";

pub const SQL_FIND_USER_BY_NAME: &str = "\
SELECT id, username, bio, image FROM users WHERE username = $1;";

pub const SQL_FOLLOW_USER: &str = "\
INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;";

pub const SQL_UNFOLLOW_USER: &str = "\
DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2;";

pub const ARTICLE_LIST_SELECT: &str = "\
SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, \
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id \
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
       u.username, u.bio, u.image, \
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following \
FROM articles a \
JOIN users u ON u.id = a.author_id";

pub const ARTICLE_FULL_SELECT: &str = "\
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, \
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id \
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
       u.username, u.bio, u.image, \
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following \
FROM articles a \
JOIN users u ON u.id = a.author_id";

pub const SQL_GET_ARTICLE_BY_SLUG: &str = "\
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, \
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id \
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
       u.username, u.bio, u.image, \
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following \
FROM articles a \
JOIN users u ON u.id = a.author_id \
WHERE a.slug = $2;";

pub const SQL_GET_ARTICLE_BY_ID: &str = "\
SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, \
       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id \
              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, \
       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, \
       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, \
       u.username, u.bio, u.image, \
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following \
FROM articles a \
JOIN users u ON u.id = a.author_id \
WHERE a.id = $2;";

pub const SQL_CREATE_ARTICLE: &str = "\
INSERT INTO articles (id, slug, author_id, title, description, body) \
SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 \
  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n \
RETURNING id;";

pub const SQL_FIND_ARTICLE_AUTHOR: &str = "\
SELECT id, author_id FROM articles WHERE slug = $1;";

pub const SQL_FIND_ARTICLE_ID: &str = "\
SELECT id FROM articles WHERE slug = $1;";

pub const SQL_UPDATE_ARTICLE: &str = "\
UPDATE articles SET \
  title = COALESCE($2, title), \
  description = COALESCE($3, description), \
  body = COALESCE($4, body), \
  slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, \
  updated_at = now() \
WHERE id = $1;";

pub const SQL_DELETE_ARTICLE: &str = "DELETE FROM articles WHERE id = $1;";

pub const SQL_FAVORITE_ARTICLE: &str = "\
INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;";

pub const SQL_UNFAVORITE_ARTICLE: &str = "\
DELETE FROM favorites WHERE user_id = $1 AND article_id = $2;";

pub const SQL_GET_COMMENTS: &str = "\
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, \
       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following \
  FROM comments c JOIN users u ON u.id = c.author_id \
 WHERE c.article_id = $2 \
 ORDER BY c.created_at DESC, c.id DESC \
 LIMIT 100;";

pub const SQL_CREATE_COMMENT: &str = "\
WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) \
           RETURNING id, body, created_at, updated_at, author_id) \
SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image \
  FROM c JOIN users u ON u.id = c.author_id;";

pub const SQL_FIND_COMMENT_AUTHOR: &str = "\
SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id \
 WHERE c.id = $1 AND a.slug = $2;";

pub const SQL_DELETE_COMMENT: &str = "DELETE FROM comments WHERE id = $1;";
