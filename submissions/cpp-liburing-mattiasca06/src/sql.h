// Statements, prepared once per connection. SQL follows the reference SQL in SPEC.md.
#pragma once

#define ARTICLE_LIST_SELECT                                                                                           \
    "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "                                       \
    "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id "            \
    "ORDER BY t.name) AS tag_list, "                                                                                  \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "                               \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "                  \
    "u.username, u.bio, u.image, "                                                                                    \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "      \
    "FROM articles a JOIN users u ON u.id = a.author_id "

#define ARTICLE_FULL_SELECT                                                                                           \
    "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "                               \
    "ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id WHERE at.article_id = a.id "            \
    "ORDER BY t.name) AS tag_list, "                                                                                  \
    "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "                               \
    "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "                  \
    "u.username, u.bio, u.image, "                                                                                    \
    "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "      \
    "FROM articles a JOIN users u ON u.id = a.author_id "

#define SLUGIFY(x) "trim(both '-' from lower(regexp_replace(" x ", '[^A-Za-z0-9]+', '-', 'g')))"

struct Stmt {
    const char *name, *sql;
};

inline constexpr Stmt kStatements[] = {
    {"tags", "SELECT name FROM tags ORDER BY name"},
    {"user_register",
     "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image"},
    {"user_login", "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1"},
    {"user_by_id", "SELECT id, username, email, bio, image FROM users WHERE id = $1"},
    {"user_update",
     "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
     "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
     "WHERE id = $1 RETURNING id, username, email, bio, image"},
    {"profile",
     "SELECT u.id, u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following "
     "FROM users u WHERE u.username = $2"},
    {"user_by_name", "SELECT id, username, bio, image FROM users WHERE username = $1"},
    {"follow_add", "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"},
    {"follow_del", "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2"},

    {"list_all", ARTICLE_LIST_SELECT "ORDER BY a.id DESC LIMIT $2 OFFSET $3"},
    {"count_all", "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s"},
    {"list_tag",
     ARTICLE_LIST_SELECT
     "WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = "
     "(SELECT t.id FROM tags t WHERE t.name = $4) ORDER BY at.article_id DESC LIMIT $2 OFFSET $3) ORDER BY a.id DESC"},
    {"count_tag",
     "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = "
     "(SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s"},
    {"list_author",
     ARTICLE_LIST_SELECT "WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) "
                         "ORDER BY a.id DESC LIMIT $2 OFFSET $3"},
    {"count_author",
     "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = "
     "(SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s"},
    {"list_fav",
     ARTICLE_LIST_SELECT
     "WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = "
     "(SELECT fu.id FROM users fu WHERE fu.username = $4) ORDER BY f.article_id DESC LIMIT $2 OFFSET $3) "
     "ORDER BY a.id DESC"},
    {"count_fav",
     "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = "
     "(SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s"},
    {"feed",
     ARTICLE_LIST_SELECT
     "WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL "
     "(SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC "
     "LIMIT ($2::int + $3::int)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3) "
     "ORDER BY a.id DESC"},
    {"count_feed",
     "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN "
     "(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s"},

    {"article_by_slug", ARTICLE_FULL_SELECT "WHERE a.slug = $2"},
    {"article_by_id", ARTICLE_FULL_SELECT "WHERE a.id = $2"},
    {"article_nextval", "SELECT nextval(pg_get_serial_sequence('articles', 'id'))"},
    {"article_insert",
     "INSERT INTO articles (id, slug, author_id, title, description, body) "
     "VALUES ($1::bigint, " SLUGIFY("$2::text") " || '-' || $1::bigint, $3::bigint, $2::text, $4::text, $5::text)"},
    {"tags_insert", "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING"},
    {"article_tags_insert",
     "INSERT INTO article_tags (article_id, tag_id) SELECT $1::bigint, t.id FROM tags t WHERE t.name = ANY($2::text[])"},
    {"article_owner", "SELECT id, author_id FROM articles WHERE slug = $1"},
    {"article_update",
     "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), "
     "body = COALESCE($4, body), slug = CASE WHEN $2::text IS NULL THEN slug ELSE " SLUGIFY("$2::text") " || '-' || id END, "
     "updated_at = now() WHERE id = $1"},
    {"article_delete", "DELETE FROM articles WHERE id = $1"},
    {"article_id", "SELECT id FROM articles WHERE slug = $1"},
    {"fav_add", "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"},
    {"fav_del", "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2"},

    {"comments_list",
     "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
     "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
     "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = $2 "
     "ORDER BY c.created_at DESC, c.id DESC LIMIT 100"},
    {"comment_insert",
     "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) "
     "RETURNING id, body, created_at, updated_at, author_id) "
     "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id"},
    {"comment_owner",
     "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2"},
    {"comment_delete", "DELETE FROM comments WHERE id = $1"},
};
