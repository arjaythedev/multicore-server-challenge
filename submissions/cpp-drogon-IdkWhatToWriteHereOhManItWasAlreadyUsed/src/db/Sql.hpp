#pragma once

namespace multicore::sql
{
    // shared fragments 
    inline constexpr auto kArticleListSelect =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        "              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "       u.username, u.bio, u.image, "
        "       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "  FROM articles a "
        "  JOIN users u ON u.id = a.author_id ";

    inline constexpr auto kArticleFullSelect =
        "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "       ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        "              WHERE at.article_id = a.id ORDER BY t.name) AS tag_list, "
        "       (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, "
        "       EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited, "
        "       u.username, u.bio, u.image, "
        "       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following "
        "  FROM articles a "
        "  JOIN users u ON u.id = a.author_id ";

    // lookup helpers
    inline constexpr auto kArticleIdBySlug =
        "SELECT id, author_id FROM articles WHERE slug = $1";

    inline constexpr auto kArticleIdOnlyBySlug =
        "SELECT id FROM articles WHERE slug = $1";

    inline constexpr auto kUserIdByUsername =
        "SELECT id FROM users WHERE username = $1";

    // users
    inline constexpr auto kInsertUser =
        "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) "
        "RETURNING id, username, email, bio, image";

    inline constexpr auto kSelectUserByEmail =
        "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";

    inline constexpr auto kSelectUserById =
        "SELECT id, username, email, bio, image FROM users WHERE id = $1";

    inline constexpr auto kUpdateUser =
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), "
        "password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image) "
        "WHERE id = $1 RETURNING id, username, email, bio, image";

    // profiles
    inline constexpr auto kSelectProfile =
        "SELECT u.id, u.username, u.bio, u.image, "
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following "
        "FROM users u WHERE u.username = $2";

    inline constexpr auto kInsertFollow =
        "INSERT INTO follows (follower_id, followee_id) VALUES ($1, $2) ON CONFLICT DO NOTHING";

    inline constexpr auto kDeleteFollow =
        "DELETE FROM follows WHERE follower_id = $1 AND followee_id = $2";

    // articles
    inline constexpr auto kInsertArticle =
        "INSERT INTO articles (id, slug, author_id, title, description, body) "
        "SELECT n.id, $2 || '-' || n.id, $1, $3, $4, $5 "
        "  FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id) n "
        "RETURNING id";

    inline constexpr auto kInsertTags =
        "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) "
        "ON CONFLICT (name) DO NOTHING";

    inline constexpr auto kLinkArticleTags =
        "INSERT INTO article_tags (article_id, tag_id) "
        "SELECT $1, t.id FROM tags t WHERE t.name = ANY($2::text[])";

    inline constexpr auto kUpdateArticle =
        "UPDATE articles SET title = COALESCE($2, title), "
        "description = COALESCE($3, description), body = COALESCE($4, body), "
        "slug = CASE WHEN $5::text IS NULL THEN slug ELSE $5::text || '-' || id END, "
        "updated_at = now() WHERE id = $1";

    inline constexpr auto kDeleteArticle =
        "DELETE FROM articles WHERE id = $1";

    // favorites
    inline constexpr auto kInsertFavorite =
        "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING";

    inline constexpr auto kDeleteFavorite =
        "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2";

    // comments
    inline constexpr auto kSelectComments =
        "SELECT c.id, c.body, c.created_at, c.updated_at, "
        "       u.username, u.bio, u.image, "
        "       EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following "
        "  FROM comments c JOIN users u ON u.id = c.author_id "
        " WHERE c.article_id = $2 "
        " ORDER BY c.created_at DESC, c.id DESC LIMIT 100";

    inline constexpr auto kInsertComment =
        "WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES ($1, $2, $3) "
        "           RETURNING id, body, created_at, updated_at, author_id) "
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, "
        "       false AS following "
        "  FROM c JOIN users u ON u.id = c.author_id";

    inline constexpr auto kSelectCommentOwner =
        "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id "
        " WHERE c.id = $1 AND a.slug = $2";

    inline constexpr auto kDeleteComment =
        "DELETE FROM comments WHERE id = $1";

    // tags
    inline constexpr auto kSelectTags =
        //"SELECT name FROM tags ORDER BY name";
            "SELECT name FROM tags";



    //combined
    inline constexpr auto kUpdateArticleWithOwner =
        "UPDATE articles "
        "SET title       = COALESCE($2, title), "
        "    description = COALESCE($3, description), "
        "    body        = COALESCE($4, body), "
        "    slug        = CASE WHEN $5::boolean THEN $6::text || '-' || id ELSE slug END, "
        "    updated_at  = now() "
        "WHERE slug = $1 "
        "RETURNING author_id, id AS updated_id";


    inline constexpr auto kDeleteArticleWithOwner =
        "DELETE FROM articles "
        "WHERE slug = $1 "
        "RETURNING author_id, id AS deleted_id";

    inline constexpr auto kInsertFavoriteBySlug =
        "WITH target AS ("
        "  SELECT id FROM articles WHERE slug = $2"
        "), ins AS ("
        "  INSERT INTO favorites (user_id, article_id) "
        "  SELECT $1, id FROM target "
        "  ON CONFLICT DO NOTHING "
        "  RETURNING 1"
        ") "
        "SELECT id AS article_id FROM target";

    inline constexpr auto kDeleteFavoriteBySlug =
        "WITH target AS ("
        "  SELECT id FROM articles WHERE slug = $2"
        "), del AS ("
        "  DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM target) "
        "  RETURNING 1"
        ") "
        "SELECT id AS article_id FROM target";

    inline constexpr auto kInsertCommentBySlug =
        "WITH target AS ("
        "  SELECT id FROM articles WHERE slug = $2"
        "), nc AS ("
        "  INSERT INTO comments (article_id, author_id, body) "
        "  SELECT id, $1, $3 FROM target "
        "  RETURNING id, body, created_at, updated_at, author_id"
        ") "
        "SELECT nc.id, nc.body, nc.created_at, nc.updated_at, u.username, u.bio, u.image, "
        "       false AS following "
        "  FROM nc JOIN users u ON u.id = nc.author_id";

    inline constexpr auto kDeleteCommentWithOwner =
        "DELETE FROM comments c "
        "USING articles a "
        "WHERE c.id = $2 "
        "  AND a.id = c.article_id "
        "  AND a.slug = $1 "
        "RETURNING c.author_id, c.id AS deleted_id";

    inline constexpr auto kInsertFollowByUsername =
        "WITH target AS ("
        "  SELECT id FROM users WHERE username = $2"
        "), ins AS ("
        "  INSERT INTO follows (follower_id, followee_id) "
        "  SELECT $1, id FROM target "
        "  ON CONFLICT DO NOTHING "
        "  RETURNING 1"
        ") "
        "SELECT id AS followee_id FROM target";

    inline constexpr auto kDeleteFollowByUsername =
        "WITH target AS ("
        "  SELECT id FROM users WHERE username = $2"
        "), del AS ("
        "  DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM target) "
        "  RETURNING 1"
        ") "
        "SELECT id AS followee_id FROM target";

    inline constexpr auto kCreateArticleWithTags =
        "WITH new_article AS ("
        "  INSERT INTO articles (id, slug, author_id, title, description, body) "
        "  SELECT n.id, $2 || '-' || n.id, $1, $3, $4, $5 "
        "    FROM (SELECT nextval(pg_get_serial_sequence('articles','id')) AS id) n "
        "  RETURNING id"
        "), upserted_tags AS ("
        "  INSERT INTO tags (name) "
        "  SELECT DISTINCT unnest($6::text[]) "
        "  ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name "
        "  RETURNING id"
        "), linked AS ("
        "  INSERT INTO article_tags (article_id, tag_id) "
        "  SELECT na.id, ut.id "
        "    FROM new_article na CROSS JOIN upserted_tags ut "
        "  RETURNING 1"
        ") "
        "SELECT id FROM new_article";


    inline constexpr auto kArticlePageFeed =
    "WHERE a.id IN ("
    "  SELECT x.id FROM follows fo CROSS JOIN LATERAL "
    "    (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id "
    "      ORDER BY a2.id DESC LIMIT ($2::int + $3::int)) x "
    "   WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3"
    ") ORDER BY a.id DESC";

    inline constexpr auto kArticleCountFeed =
        "SELECT count(*) FROM (SELECT 1 FROM articles a "
        " WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) "
        " LIMIT 1000) s";

    // base selects without correlated subqueries

    inline constexpr auto kArticleBaseListSelect =
        "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, "
        "       a.author_id, "
        "       u.username, u.bio, u.image "
        "  FROM articles a "
        "  JOIN users u ON u.id = a.author_id ";

    inline constexpr auto kArticleBaseFullSelect =
        "SELECT a.id, a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, "
        "       a.author_id, "
        "       u.username, u.bio, u.image "
        "  FROM articles a "
        "  JOIN users u ON u.id = a.author_id ";

    // batch lookups for a page of articles
    inline constexpr auto kTagsForArticles =
        "SELECT at.article_id, t.name "
        "  FROM article_tags at JOIN tags t ON t.id = at.tag_id "
        " WHERE at.article_id = ANY($1::bigint[]) "
        ;
        //" ORDER BY at.article_id, t.name";

    inline constexpr auto kFavoriteCountsForArticles =
        "SELECT article_id, count(*) AS cnt "
        "  FROM favorites WHERE article_id = ANY($1::bigint[]) "
        " GROUP BY article_id";

    inline constexpr auto kFavoritedForViewer =
        "SELECT article_id FROM favorites "
        " WHERE user_id = $1 AND article_id = ANY($2::bigint[])";

    inline constexpr auto kFollowingForViewer =
        "SELECT followee_id FROM follows "
        " WHERE follower_id = $1 AND followee_id = ANY($2::bigint[])";
}