package dev.moose.conduit.read;

import dev.moose.conduit.database.NumberedSql;

public class ReadSql {

    private ReadSql() {
    }

    public static final NumberedSql TAGS = NumberedSql.of("""
            SELECT ARRAY(SELECT name FROM tags ORDER BY name)
            """);

    public static final NumberedSql USERS_BY_ID = NumberedSql.of("""
            SELECT requests.k, users.id, users.username, users.email, users.bio, users.image
              FROM unnest(?::int8[]) WITH ORDINALITY AS requests(id, k)
              JOIN users ON users.id = requests.id
            """);

    public static final NumberedSql USERS_BY_EMAIL = NumberedSql.of("""
            SELECT requests.k, users.id, users.username, users.email, users.bio, users.image, users.password_hash
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(email, k)
              JOIN users ON users.email = requests.email
            """);

    public static final NumberedSql PROFILES = NumberedSql.of("""
            SELECT requests.k, users.id, users.username, users.bio, users.image
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(username, k)
              JOIN users ON users.username = requests.username
            """);

    public static final NumberedSql ARTICLES_BY_SLUG = NumberedSql.of("""
            SELECT requests.k, articles.id, articles.author_id, articles.slug, articles.title, articles.description,
                   articles.created_at, articles.updated_at, articles.body
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(slug, k)
              JOIN articles ON articles.slug = requests.slug
            """);

    public static final NumberedSql COMMENTS = NumberedSql.of("""
            SELECT requests.k, articles.id, recent.id, recent.body, recent.created_at, recent.updated_at, recent.author_id,
                   users.username, users.bio, users.image
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(slug, k)
              JOIN articles ON articles.slug = requests.slug
              LEFT JOIN LATERAL (SELECT comments.id, comments.body, comments.created_at, comments.updated_at, comments.author_id
                                   FROM comments
                                  WHERE comments.article_id = articles.id
                                  ORDER BY comments.created_at DESC, comments.id DESC LIMIT 100) recent ON true
              LEFT JOIN users ON users.id = recent.author_id
            """);

    public static final NumberedSql GLOBAL = NumberedSql.of("""
            SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) matches),
                   NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest(?::int4[], ?::int8[]) WITH ORDINALITY AS requests(lim, off, k)
              CROSS JOIN LATERAL (SELECT id, author_id, slug, title, description, created_at, updated_at
                                    FROM articles ORDER BY id DESC LIMIT requests.lim OFFSET requests.off) page
            """);

    public static final NumberedSql BY_TAG = NumberedSql.of("""
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM article_tags WHERE article_tags.tag_id = tags.id LIMIT 1000) matches),
                   NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(tag, k)
              LEFT JOIN tags ON tags.name = requests.tag
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest(?::text[], ?::int4[], ?::int8[]) WITH ORDINALITY AS requests(tag, lim, off, k)
              JOIN tags ON tags.name = requests.tag
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description,
                                         articles.created_at, articles.updated_at
                                    FROM article_tags
                                    JOIN articles ON articles.id = article_tags.article_id
                                   WHERE article_tags.tag_id = tags.id
                                   ORDER BY article_tags.article_id DESC LIMIT requests.lim OFFSET requests.off) page
            """);

    public static final NumberedSql BY_AUTHOR = NumberedSql.of("""
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM articles WHERE articles.author_id = users.id LIMIT 1000) matches),
                   NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(username, k)
              LEFT JOIN users ON users.username = requests.username
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest(?::text[], ?::int4[], ?::int8[]) WITH ORDINALITY AS requests(username, lim, off, k)
              JOIN users ON users.username = requests.username
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description,
                                         articles.created_at, articles.updated_at
                                    FROM articles
                                   WHERE articles.author_id = users.id
                                   ORDER BY articles.id DESC LIMIT requests.lim OFFSET requests.off) page
            """);

    public static final NumberedSql FAVORITED_BY = NumberedSql.of("""
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM favorites WHERE favorites.user_id = users.id LIMIT 1000) matches),
                   NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest(?::text[]) WITH ORDINALITY AS requests(username, k)
              LEFT JOIN users ON users.username = requests.username
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest(?::text[], ?::int4[], ?::int8[]) WITH ORDINALITY AS requests(username, lim, off, k)
              JOIN users ON users.username = requests.username
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description,
                                         articles.created_at, articles.updated_at
                                    FROM favorites
                                    JOIN articles ON articles.id = favorites.article_id
                                   WHERE favorites.user_id = users.id
                                   ORDER BY favorites.article_id DESC LIMIT requests.lim OFFSET requests.off) page
            """);

    public static final NumberedSql FEED = NumberedSql.of("""
            SELECT -requests.k,
                   (SELECT count(*) FROM (SELECT 1 FROM follows
                                           CROSS JOIN LATERAL (SELECT 1 FROM articles WHERE articles.author_id = follows.followee_id LIMIT 1000) authored
                                          WHERE follows.follower_id = requests.viewer LIMIT 1000) matches),
                   NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest(?::int8[]) WITH ORDINALITY AS requests(viewer, k)
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest(?::int8[], ?::int4[], ?::int8[]) WITH ORDINALITY AS requests(viewer, lim, off, k)
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description,
                                         articles.created_at, articles.updated_at
                                    FROM (SELECT recent.id
                                            FROM follows
                                            CROSS JOIN LATERAL (SELECT articles.id FROM articles
                                                                 WHERE articles.author_id = follows.followee_id
                                                                 ORDER BY articles.id DESC
                                                                 LIMIT requests.lim + requests.off) recent
                                           WHERE follows.follower_id = requests.viewer
                                           ORDER BY recent.id DESC LIMIT requests.lim OFFSET requests.off) ids
                                    JOIN articles ON articles.id = ids.id
                                  OFFSET 0) page
            """);

    public static final NumberedSql ARTICLE_EXTRAS = NumberedSql.of("""
            SELECT requests.id,
                   ARRAY(SELECT article_tags.tag_id FROM article_tags WHERE article_tags.article_id = requests.id),
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = requests.id),
                   authors.username, authors.bio, authors.image
              FROM unnest(?::int8[], ?::int8[]) AS requests(id, author_id)
              CROSS JOIN LATERAL (SELECT username, bio, image FROM users WHERE users.id = requests.author_id) authors
             WHERE EXISTS (SELECT 1 FROM articles WHERE articles.id = requests.id)
            """);

    public static final NumberedSql TAG_NAMES = NumberedSql.of("""
            SELECT tags.id, tags.name
              FROM tags
             WHERE tags.id IN (SELECT article_tags.tag_id FROM article_tags WHERE article_tags.article_id = ANY (?::int8[]))
             ORDER BY tags.name
            """);

    public static final NumberedSql FLAGS = NumberedSql.of("""
            WITH favorite_asks AS (
              SELECT asks.viewer, array_agg(asks.article_id) AS article_ids
                FROM unnest(?::int8[], ?::int8[]) AS asks(viewer, article_id)
               GROUP BY asks.viewer
            ),
            follow_asks AS (
              SELECT asks.viewer, array_agg(asks.user_id) AS user_ids
                FROM unnest(?::int8[], ?::int8[]) AS asks(viewer, user_id)
               GROUP BY asks.viewer
            )
            SELECT 0, favorite_asks.viewer, matched.article_id
              FROM favorite_asks
              CROSS JOIN LATERAL (SELECT favorites.article_id FROM favorites
                                   WHERE favorites.user_id = favorite_asks.viewer
                                     AND favorites.article_id = ANY (favorite_asks.article_ids)) matched
            UNION ALL
            SELECT 1, follow_asks.viewer, matched.followee_id
              FROM follow_asks
              CROSS JOIN LATERAL (SELECT follows.followee_id FROM follows
                                   WHERE follows.follower_id = follow_asks.viewer
                                     AND follows.followee_id = ANY (follow_asks.user_ids)) matched
            """);

}
