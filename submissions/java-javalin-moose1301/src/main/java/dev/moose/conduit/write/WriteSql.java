package dev.moose.conduit.write;

import dev.moose.conduit.database.NumberedSql;

public class WriteSql {

    private WriteSql() {
    }

    private static final String ARTICLE_COLUMNS = """
            articles.id, articles.slug, articles.title, articles.description, articles.body,
                   articles.created_at, articles.updated_at,
                   ARRAY(SELECT tags.name FROM article_tags JOIN tags ON tags.id = article_tags.tag_id
                          WHERE article_tags.article_id = articles.id ORDER BY tags.name) AS tag_list,
            """;

    public static final NumberedSql USER_INSERT = NumberedSql.of("""
            INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)
            RETURNING id, username, email, bio, image
            """);

    public static final NumberedSql USER_UPDATE = NumberedSql.of("""
            UPDATE users SET email = COALESCE(?, email), username = COALESCE(?, username),
                             password_hash = COALESCE(?, password_hash), bio = COALESCE(?, bio), image = COALESCE(?, image)
             WHERE id = ?
            RETURNING id, username, email, bio, image
            """);

    public static final NumberedSql FOLLOW = NumberedSql.of("""
            WITH target AS (SELECT id, username, bio, image FROM users WHERE username = ?),
                 inserted AS (INSERT INTO follows (follower_id, followee_id) SELECT ?, target.id FROM target
                              ON CONFLICT DO NOTHING)
            SELECT username, bio, image FROM target
            """);

    public static final NumberedSql UNFOLLOW = NumberedSql.of("""
            WITH target AS (SELECT id, username, bio, image FROM users WHERE username = ?),
                 deleted AS (DELETE FROM follows WHERE follower_id = ? AND followee_id IN (SELECT id FROM target))
            SELECT username, bio, image FROM target
            """);

    public static final NumberedSql TAGS_INSERT = NumberedSql.of("""
            INSERT INTO tags (name)
            SELECT name FROM (SELECT DISTINCT unnest(?::text[]) AS name) wanted
             WHERE NOT EXISTS (SELECT 1 FROM tags WHERE tags.name = wanted.name)
             ORDER BY name
            ON CONFLICT (name) DO NOTHING
            """);

    public static final NumberedSql ARTICLE_INSERT = NumberedSql.of("""
            WITH created AS (
                INSERT INTO articles (id, slug, author_id, title, description, body)
                SELECT n.id, trim(both '-' from lower(regexp_replace(?1, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
                       ?0, ?1, ?2, ?3
                  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
                RETURNING id, slug, title, description, body, created_at, updated_at, author_id
            ), linked AS (
                INSERT INTO article_tags (article_id, tag_id)
                SELECT created.id, tags.id FROM created, tags WHERE tags.name = ANY (?4::text[])
            )
            SELECT created.id, created.slug, created.title, created.description, created.body,
                   created.created_at, created.updated_at,
                   ARRAY(SELECT DISTINCT unnest(?4::text[]) ORDER BY 1) AS tag_list,
                   0::int8 AS favorites_count,
                   false AS favorited,
                   users.username, users.bio, users.image,
                   EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ?0 AND follows.followee_id = ?0) AS following
              FROM created
              JOIN users ON users.id = created.author_id
            """);

    public static final NumberedSql ARTICLE_UPDATE = NumberedSql.of("""
            WITH target AS (SELECT id, author_id FROM articles WHERE slug = ?1),
            updated AS (
                UPDATE articles SET title = COALESCE(?2, articles.title), description = COALESCE(?3, articles.description),
                       body = COALESCE(?4, articles.body),
                       slug = CASE WHEN ?2::text IS NULL THEN articles.slug
                                   ELSE trim(both '-' from lower(regexp_replace(?2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || articles.id END,
                       updated_at = now()
                  FROM target
                 WHERE articles.id = target.id AND target.author_id = ?0
                RETURNING articles.id, articles.slug, articles.title, articles.description, articles.body,
                          articles.created_at, articles.updated_at, articles.author_id
            )
            SELECT target.author_id, updated.id, updated.slug, updated.title, updated.description, updated.body,
                   updated.created_at, updated.updated_at,
                   ARRAY(SELECT tags.name FROM article_tags JOIN tags ON tags.id = article_tags.tag_id
                          WHERE article_tags.article_id = updated.id ORDER BY tags.name) AS tag_list,
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = updated.id) AS favorites_count,
                   EXISTS (SELECT 1 FROM favorites WHERE favorites.user_id = ?0 AND favorites.article_id = updated.id) AS favorited,
                   users.username, users.bio, users.image,
                   EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ?0 AND follows.followee_id = updated.author_id) AS following
              FROM target
              LEFT JOIN updated ON true
              LEFT JOIN users ON users.id = updated.author_id
            """);

    public static final NumberedSql ARTICLE_DELETE = NumberedSql.of("""
            WITH target AS (SELECT id, author_id FROM articles WHERE slug = ?1),
                 deleted AS (DELETE FROM articles USING target
                              WHERE articles.id = target.id AND target.author_id = ?0 RETURNING 1)
            SELECT target.author_id, (SELECT count(*) FROM deleted) FROM target
            """);

    public static final NumberedSql FAVORITE = NumberedSql.of("""
            WITH target AS (SELECT id FROM articles WHERE slug = ?1),
                 inserted AS (INSERT INTO favorites (user_id, article_id) SELECT ?0, target.id FROM target
                              ON CONFLICT DO NOTHING RETURNING 1)
            SELECT %s
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id)
                     + (SELECT count(*) FROM inserted) AS favorites_count,
                   true AS favorited,
                   users.username, users.bio, users.image,
                   EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ?0 AND follows.followee_id = articles.author_id) AS following
              FROM articles
              JOIN users ON users.id = articles.author_id
             WHERE articles.id = (SELECT id FROM target)
            """.formatted(ARTICLE_COLUMNS));

    public static final NumberedSql UNFAVORITE = NumberedSql.of("""
            WITH target AS (SELECT id FROM articles WHERE slug = ?1),
                 deleted AS (DELETE FROM favorites WHERE user_id = ?0 AND article_id IN (SELECT id FROM target) RETURNING 1)
            SELECT %s
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id)
                     - (SELECT count(*) FROM deleted) AS favorites_count,
                   false AS favorited,
                   users.username, users.bio, users.image,
                   EXISTS (SELECT 1 FROM follows WHERE follows.follower_id = ?0 AND follows.followee_id = articles.author_id) AS following
              FROM articles
              JOIN users ON users.id = articles.author_id
             WHERE articles.id = (SELECT id FROM target)
            """.formatted(ARTICLE_COLUMNS));

    public static final NumberedSql COMMENT_INSERT = NumberedSql.of("""
            WITH inserted AS (
                INSERT INTO comments (article_id, author_id, body)
                SELECT id, ?, ? FROM articles WHERE slug = ?
                RETURNING id, body, created_at, updated_at, author_id
            )
            SELECT inserted.id, inserted.body, inserted.created_at, inserted.updated_at,
                   users.username, users.bio, users.image
              FROM inserted
              JOIN users ON users.id = inserted.author_id
            """);

    public static final NumberedSql COMMENT_DELETE = NumberedSql.of("""
            WITH target AS (SELECT comments.id, comments.author_id FROM comments
                              JOIN articles ON articles.id = comments.article_id
                             WHERE comments.id = ?1 AND articles.slug = ?2),
                 deleted AS (DELETE FROM comments USING target
                              WHERE comments.id = target.id AND target.author_id = ?0 RETURNING 1)
            SELECT target.author_id FROM target
            """);

}
