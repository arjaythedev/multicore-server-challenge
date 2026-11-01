package dev.mccue.vertx.realworld;

/// All the SQL. Wherever an article or profile is rendered, $1 is the viewer (0 when anonymous).
///
/// Article columns, in order: id, slug, title, description, [body], created_at, updated_at, tag_list,
/// favorites_count, favorited, username, bio, image, following (see Api.writeArticle).
///
/// What keeps Postgres's work down:
/// - List pages are cut to their ids first; tags, counts and flags are computed for the page's rows only, so
///   OFFSET rows cost an index step each.
/// - A list's page and its capped count are one statement. "At least 1000?" is answered by whether a 1000th row
///   exists rather than by counting.
/// - Tag names are looked up by primary key per tag; favorited/following are single-row probes.
/// - In the feed, following is true by definition. For comments, the viewer's followees are read once.
/// - Writes are one statement each wherever the response allows it.
final class Sql {
    private Sql() {}

    // ---------- reads ----------

    static final String TAGS = """
            SELECT name FROM tags ORDER BY name
            """;

    // $1 viewer, $2 slug
    static final String ARTICLE_BY_SLUG = """
            SELECT articles.id, articles.slug, articles.title, articles.description, articles.body,
                   articles.created_at, articles.updated_at,
                   ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                           FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id) AS favorites_count,
                   (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = articles.id) IS NOT NULL AS favorited,
                   users.username, users.bio, users.image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = articles.author_id) IS NOT NULL AS following
              FROM articles
              JOIN users ON users.id = articles.author_id
             WHERE articles.slug = $2
            """;

    // $1 viewer, $2 article id
    static final String ARTICLE_BY_ID = """
            SELECT articles.id, articles.slug, articles.title, articles.description, articles.body,
                   articles.created_at, articles.updated_at,
                   ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                           FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id) AS favorites_count,
                   (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = articles.id) IS NOT NULL AS favorited,
                   users.username, users.bio, users.image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = articles.author_id) IS NOT NULL AS following
              FROM articles
              JOIN users ON users.id = articles.author_id
             WHERE articles.id = $2
            """;

    // Lists: (count, article columns...) per row, and one row with NULL article columns for an empty page.
    // OFFSET 0 keeps the count evaluated once, not once per article row.

    // $1 viewer, $2 limit, $3 offset
    static final String LIST_ALL = """
            SELECT capped.n, page.*
              FROM (SELECT CASE WHEN EXISTS (SELECT 1 FROM articles ORDER BY id OFFSET 999)
                                THEN 1000
                                ELSE (SELECT count(*) FROM articles) END AS n
                    OFFSET 0) capped
              LEFT JOIN LATERAL (
                SELECT ids.id, ids.slug, ids.title, ids.description, ids.created_at, ids.updated_at,
                       ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                               FROM article_tags WHERE article_tags.article_id = ids.id ORDER BY 1) AS tag_list,
                       (SELECT count(*) FROM favorites WHERE favorites.article_id = ids.id) AS favorites_count,
                       (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = ids.id) IS NOT NULL AS favorited,
                       users.username, users.bio, users.image,
                       (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = ids.author_id) IS NOT NULL AS following
                  FROM (SELECT id, slug, title, description, created_at, updated_at, author_id
                          FROM articles ORDER BY id DESC LIMIT $2 OFFSET $3) ids
                  JOIN users ON users.id = ids.author_id
                 ORDER BY ids.id DESC
              ) page ON true
            """;

    // $1 viewer, $2 limit, $3 offset, $4 author username
    static final String LIST_BY_AUTHOR = """
            SELECT capped.n, page.*
              FROM (SELECT count(*) AS n
                      FROM (SELECT 1 FROM articles
                             WHERE author_id = (SELECT id FROM users WHERE username = $4) LIMIT 1000) matches
                    OFFSET 0) capped
              LEFT JOIN LATERAL (
                SELECT ids.id, ids.slug, ids.title, ids.description, ids.created_at, ids.updated_at,
                       ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                               FROM article_tags WHERE article_tags.article_id = ids.id ORDER BY 1) AS tag_list,
                       (SELECT count(*) FROM favorites WHERE favorites.article_id = ids.id) AS favorites_count,
                       (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = ids.id) IS NOT NULL AS favorited,
                       users.username, users.bio, users.image,
                       (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = ids.author_id) IS NOT NULL AS following
                  FROM (SELECT id, slug, title, description, created_at, updated_at, author_id
                          FROM articles
                         WHERE author_id = (SELECT id FROM users WHERE username = $4)
                         ORDER BY id DESC LIMIT $2 OFFSET $3) ids
                  JOIN users ON users.id = ids.author_id
                 ORDER BY ids.id DESC
              ) page ON true
            """;

    // $1 viewer, $2 limit, $3 offset, $4 tag name
    static final String LIST_BY_TAG = """
            SELECT capped.n, page.*
              FROM (SELECT count(*) AS n
                      FROM (SELECT 1 FROM article_tags
                             WHERE tag_id = (SELECT id FROM tags WHERE name = $4) LIMIT 1000) matches
                    OFFSET 0) capped
              LEFT JOIN LATERAL (
                SELECT articles.id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at,
                       ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                               FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                       (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id) AS favorites_count,
                       (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = articles.id) IS NOT NULL AS favorited,
                       users.username, users.bio, users.image,
                       (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = articles.author_id) IS NOT NULL AS following
                  FROM (SELECT article_id AS id FROM article_tags
                         WHERE tag_id = (SELECT id FROM tags WHERE name = $4)
                         ORDER BY article_id DESC LIMIT $2 OFFSET $3) ids
                  JOIN articles ON articles.id = ids.id
                  JOIN users ON users.id = articles.author_id
                 ORDER BY ids.id DESC
              ) page ON true
            """;

    // $1 viewer, $2 limit, $3 offset, $4 username of the favoriter
    static final String LIST_FAVORITED = """
            SELECT capped.n, page.*
              FROM (SELECT count(*) AS n
                      FROM (SELECT 1 FROM favorites
                             WHERE user_id = (SELECT id FROM users WHERE username = $4) LIMIT 1000) matches
                    OFFSET 0) capped
              LEFT JOIN LATERAL (
                SELECT articles.id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at,
                       ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                               FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                       (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id) AS favorites_count,
                       (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = articles.id) IS NOT NULL AS favorited,
                       users.username, users.bio, users.image,
                       (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = articles.author_id) IS NOT NULL AS following
                  FROM (SELECT article_id AS id FROM favorites
                         WHERE user_id = (SELECT id FROM users WHERE username = $4)
                         ORDER BY article_id DESC LIMIT $2 OFFSET $3) ids
                  JOIN articles ON articles.id = ids.id
                  JOIN users ON users.id = articles.author_id
                 ORDER BY ids.id DESC
              ) page ON true
            """;

    // $1 viewer, $2 limit, $3 offset. Each followed author contributes at most limit + offset of their newest
    // articles (bigint, so a huge offset can't overflow). Every author in the feed is followed by the viewer.
    static final String FEED = """
            SELECT capped.n, page.*
              FROM (SELECT count(*) AS n
                      FROM (SELECT 1 FROM articles
                             WHERE author_id = ANY (ARRAY(SELECT followee_id FROM follows WHERE follower_id = $1))
                             LIMIT 1000) matches
                    OFFSET 0) capped
              LEFT JOIN LATERAL (
                SELECT articles.id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at,
                       ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                               FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                       (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id) AS favorites_count,
                       (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = articles.id) IS NOT NULL AS favorited,
                       users.username, users.bio, users.image,
                       true AS following
                  FROM (SELECT recent.id
                          FROM follows
                          CROSS JOIN LATERAL (SELECT id FROM articles WHERE articles.author_id = follows.followee_id
                                               ORDER BY id DESC LIMIT ($2::bigint + $3::bigint)) recent
                         WHERE follows.follower_id = $1
                         ORDER BY recent.id DESC LIMIT $2 OFFSET $3) ids
                  JOIN articles ON articles.id = ids.id
                  JOIN users ON users.id = articles.author_id
                 ORDER BY ids.id DESC
              ) page ON true
            """;

    // $1 viewer, $2 slug. One row with NULL comment columns when the article has no comments; no row when there's
    // no such article. Columns: article id, comment id, body, created_at, updated_at, username, bio, image, following.
    static final String COMMENTS = """
            SELECT articles.id, recent.id, recent.body, recent.created_at, recent.updated_at,
                   users.username, users.bio, users.image,
                   recent.author_id = ANY (followees.ids) AS following
              FROM articles
              CROSS JOIN LATERAL (SELECT ARRAY(SELECT followee_id FROM follows WHERE follower_id = $1) AS ids) followees
              LEFT JOIN LATERAL (SELECT id, body, created_at, updated_at, author_id FROM comments
                                  WHERE comments.article_id = articles.id
                                  ORDER BY created_at DESC, id DESC LIMIT 100) recent ON true
              LEFT JOIN users ON users.id = recent.author_id
             WHERE articles.slug = $2
             ORDER BY recent.created_at DESC, recent.id DESC
            """;

    // $1 viewer, $2 username
    static final String PROFILE = """
            SELECT username, bio, image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = users.id) IS NOT NULL AS following
              FROM users WHERE username = $2
            """;

    // $1 user id
    static final String USER_BY_ID = """
            SELECT id, username, email, bio, image FROM users WHERE id = $1
            """;

    // $1 email
    static final String USER_BY_EMAIL = """
            SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1
            """;

    // $1 slug
    static final String ARTICLE_EXISTS = """
            SELECT 1 FROM articles WHERE slug = $1
            """;

    // $1 comment id, $2 slug
    static final String COMMENT_EXISTS = """
            SELECT 1 FROM comments JOIN articles ON articles.id = comments.article_id
             WHERE comments.id = $1 AND articles.slug = $2
            """;

    // ---------- read lanes (see Lanes) ----------
    //
    // Phase A: one statement per kind of read in the batch, over arrays of the batch's distinct keys. Each output row
    // starts with its key's 1-based ordinal k. Article rows are (k, id, author_id, slug, title, description,
    // created_at, updated_at[, body]). The list statements return their capped counts too: rows with k <= 0, the
    // count key -k (0 for the global list's single count) and the count in column 1.

    static final String LANE_TAGS = """
            SELECT ARRAY(SELECT name FROM tags ORDER BY name)
            """;

    // $1 user ids. Columns: k, id, username, email, bio, image.
    static final String LANE_USERS_BY_ID = """
            SELECT requests.k, users.id, users.username, users.email, users.bio, users.image
              FROM unnest($1::int8[]) WITH ORDINALITY AS requests(id, k)
              JOIN users ON users.id = requests.id
            """;

    // $1 emails. Columns: k, id, username, email, bio, image, password_hash.
    static final String LANE_USERS_BY_EMAIL = """
            SELECT requests.k, users.id, users.username, users.email, users.bio, users.image, users.password_hash
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(email, k)
              JOIN users ON users.email = requests.email
            """;

    // $1 usernames. Columns: k, id, username, bio, image.
    static final String LANE_PROFILES = """
            SELECT requests.k, users.id, users.username, users.bio, users.image
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(username, k)
              JOIN users ON users.username = requests.username
            """;

    // $1 slugs. Article rows with body.
    static final String LANE_ARTICLES = """
            SELECT requests.k, articles.id, articles.author_id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at, articles.body
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(slug, k)
              JOIN articles ON articles.slug = requests.slug
            """;

    // $1 slugs. Columns: k, article id, comment id, body, created_at, updated_at, author_id, username, bio, image.
    // One row with NULL comment columns for an article without comments; no row for no such article.
    static final String LANE_COMMENTS = """
            SELECT requests.k, articles.id, recent.id, recent.body, recent.created_at, recent.updated_at, recent.author_id,
                   users.username, users.bio, users.image
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(slug, k)
              JOIN articles ON articles.slug = requests.slug
              LEFT JOIN LATERAL (SELECT comments.id, comments.body, comments.created_at, comments.updated_at, comments.author_id
                                   FROM comments
                                  WHERE comments.article_id = articles.id
                                  ORDER BY comments.created_at DESC, comments.id DESC LIMIT 100) recent ON true
              LEFT JOIN users ON users.id = recent.author_id
            """;

    // $1 limits, $2 offsets (one per distinct page). The count reads the oldest end of the primary key, whose pages
    // are all-visible, so it stays an index-only scan while new articles keep the newest pages dirty.
    static final String LANE_GLOBAL = """
            SELECT 0::int8, (SELECT count(*) FROM (SELECT 1 FROM articles ORDER BY id LIMIT 1000) matches), NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest($1::int4[], $2::int8[]) WITH ORDINALITY AS requests(lim, off, k)
              CROSS JOIN LATERAL (SELECT id, author_id, slug, title, description, created_at, updated_at
                                    FROM articles ORDER BY id DESC LIMIT requests.lim OFFSET requests.off) page
            """;

    // $1 tag names (counts), $2 tag names, $3 limits, $4 offsets (pages)
    static final String LANE_BY_TAG = """
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM article_tags WHERE article_tags.tag_id = tags.id LIMIT 1000) matches), NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(tag, k)
              LEFT JOIN tags ON tags.name = requests.tag
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest($2::text[], $3::int4[], $4::int8[]) WITH ORDINALITY AS requests(tag, lim, off, k)
              JOIN tags ON tags.name = requests.tag
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at
                                    FROM article_tags
                                    JOIN articles ON articles.id = article_tags.article_id
                                   WHERE article_tags.tag_id = tags.id
                                   ORDER BY article_tags.article_id DESC LIMIT requests.lim OFFSET requests.off) page
            """;

    // $1 author usernames (counts), $2 author usernames, $3 limits, $4 offsets (pages)
    static final String LANE_BY_AUTHOR = """
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM articles WHERE articles.author_id = users.id LIMIT 1000) matches), NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(username, k)
              LEFT JOIN users ON users.username = requests.username
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest($2::text[], $3::int4[], $4::int8[]) WITH ORDINALITY AS requests(username, lim, off, k)
              JOIN users ON users.username = requests.username
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at
                                    FROM articles
                                   WHERE articles.author_id = users.id
                                   ORDER BY articles.id DESC LIMIT requests.lim OFFSET requests.off) page
            """;

    // $1 favoriters' usernames (counts), $2 favoriters' usernames, $3 limits, $4 offsets (pages)
    static final String LANE_FAVORITED = """
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM favorites WHERE favorites.user_id = users.id LIMIT 1000) matches), NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest($1::text[]) WITH ORDINALITY AS requests(username, k)
              LEFT JOIN users ON users.username = requests.username
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest($2::text[], $3::int4[], $4::int8[]) WITH ORDINALITY AS requests(username, lim, off, k)
              JOIN users ON users.username = requests.username
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at
                                    FROM favorites
                                    JOIN articles ON articles.id = favorites.article_id
                                   WHERE favorites.user_id = users.id
                                   ORDER BY favorites.article_id DESC LIMIT requests.lim OFFSET requests.off) page
            """;

    // $1 viewers (counts), $2 viewers, $3 limits, $4 offsets (pages). A page reads at most limit + offset of each
    // followee's newest article ids.
    static final String LANE_FEED = """
            SELECT -requests.k, (SELECT count(*) FROM (SELECT 1 FROM articles WHERE articles.author_id = ANY (ARRAY(SELECT follows.followee_id FROM follows WHERE follows.follower_id = requests.v)) LIMIT 1000) matches), NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz
              FROM unnest($1::int8[]) WITH ORDINALITY AS requests(v, k)
            UNION ALL
            SELECT requests.k, page.id, page.author_id, page.slug, page.title, page.description, page.created_at, page.updated_at
              FROM unnest($2::int8[], $3::int4[], $4::int8[]) WITH ORDINALITY AS requests(v, lim, off, k)
              CROSS JOIN LATERAL (SELECT articles.id, articles.author_id, articles.slug, articles.title, articles.description, articles.created_at, articles.updated_at
                                    FROM (SELECT recent.id
                                            FROM follows
                                            CROSS JOIN LATERAL (SELECT articles.id FROM articles
                                                                 WHERE articles.author_id = follows.followee_id
                                                                 ORDER BY articles.id DESC
                                                                 LIMIT requests.lim + requests.off) recent
                                           WHERE follows.follower_id = requests.v
                                           ORDER BY recent.id DESC LIMIT requests.lim OFFSET requests.off) ids
                                    JOIN articles ON articles.id = ids.id
                                  OFFSET 0) page
            """;

    // Phase B, over everything phase A found.

    // $1 article ids, $2 their authors (distinct articles). Columns: id, tag ids, favorites count, username, bio, image.
    static final String LANE_ARTICLE_EXTRAS = """
            SELECT requests.id,
                   ARRAY(SELECT article_tags.tag_id FROM article_tags WHERE article_tags.article_id = requests.id),
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = requests.id),
                   users.username, users.bio, users.image
              FROM unnest($1::int8[], $2::int8[]) AS requests(id, author_id)
              CROSS JOIN LATERAL (SELECT username, bio, image FROM users WHERE users.id = requests.author_id) users
            """;

    // $1 article ids. The names of every tag they carry, in the database's name order (tag lists are sorted by name).
    static final String LANE_TAG_NAMES = """
            SELECT tags.id, tags.name
              FROM tags
             WHERE tags.id IN (SELECT article_tags.tag_id FROM article_tags WHERE article_tags.article_id = ANY ($1::int8[]))
             ORDER BY tags.name
            """;

    // $1, $2 (viewer, article) pairs asked about; $3, $4 (viewer, user) pairs. Rows: (0, viewer, article) for each
    // favorite, (1, viewer, user) for each follow. Each viewer's candidates are one primary key scan (= ANY).
    static final String LANE_FLAGS = """
            WITH favorite_asks AS (
              SELECT asks.viewer, array_agg(asks.article_id) AS article_ids
                FROM unnest($1::int8[], $2::int8[]) AS asks(viewer, article_id)
               GROUP BY asks.viewer
            ),
            follow_asks AS (
              SELECT asks.viewer, array_agg(asks.user_id) AS user_ids
                FROM unnest($3::int8[], $4::int8[]) AS asks(viewer, user_id)
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
            """;

    // ---------- writes ----------

    // $1 username, $2 email, $3 password hash
    static final String USER_INSERT = """
            INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
            RETURNING id, username, email, bio, image
            """;

    // $1 user id, $2 email, $3 username, $4 password hash, $5 bio, $6 image (NULL: unchanged)
    static final String USER_UPDATE = """
            UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
             WHERE id = $1
            RETURNING id, username, email, bio, image
            """;

    // $1 follower, $2 username. No row: no such user.
    static final String FOLLOW = """
            WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2),
                 inserted AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, target.id FROM target
                              ON CONFLICT DO NOTHING)
            SELECT username, bio, image FROM target
            """;

    // $1 follower, $2 username. No row: no such user.
    static final String UNFOLLOW = """
            WITH target AS (SELECT id, username, bio, image FROM users WHERE username = $2),
                 deleted AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM target))
            SELECT username, bio, image FROM target
            """;

    // $1 tag names. Only tags that don't exist yet (no sequence burn), in name order (no deadlock between
    // concurrent creates). Runs before ARTICLE_INSERT, so the tags exist when the article links them.
    static final String TAGS_INSERT = """
            INSERT INTO tags (name)
            SELECT name FROM (SELECT DISTINCT unnest($1::text[]) AS name) wanted
             WHERE NOT EXISTS (SELECT 1 FROM tags WHERE tags.name = wanted.name)
             ORDER BY name
            ON CONFLICT (name) DO NOTHING
            """;

    // $1 author, $2 title, $3 description, $4 body, $5 tag names. The article and its tag links in one statement
    // (Postgres runs each statement atomically), returned as article columns. Nothing has favorited a new
    // article, and its tags are exactly the ones asked for.
    static final String ARTICLE_INSERT = """
            WITH created AS (
                INSERT INTO articles (id, slug, author_id, title, description, body)
                SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
                       $1, $2, $3, $4
                  FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
                RETURNING id, slug, title, description, body, created_at, updated_at, author_id
            ), linked AS (
                INSERT INTO article_tags (article_id, tag_id)
                SELECT created.id, tags.id FROM created, tags WHERE tags.name = ANY ($5::text[])
            )
            SELECT created.id, created.slug, created.title, created.description, created.body,
                   created.created_at, created.updated_at,
                   ARRAY(SELECT DISTINCT unnest($5::text[]) ORDER BY 1) AS tag_list,
                   0::bigint AS favorites_count,
                   false AS favorited,
                   users.username, users.bio, users.image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = $1) IS NOT NULL AS following
              FROM created
              JOIN users ON users.id = created.author_id
            """;

    // $1 viewer (must be the author), $2 slug, $3 title, $4 description, $5 body (NULL: unchanged).
    // No row: no such article, or not the author's.
    static final String ARTICLE_UPDATE = """
            WITH updated AS (
                UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
                       slug = CASE WHEN $3::text IS NULL THEN slug
                                   ELSE trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
                       updated_at = now()
                 WHERE slug = $2 AND author_id = $1
                RETURNING id, slug, title, description, body, created_at, updated_at, author_id
            )
            SELECT updated.id, updated.slug, updated.title, updated.description, updated.body,
                   updated.created_at, updated.updated_at,
                   ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                           FROM article_tags WHERE article_tags.article_id = updated.id ORDER BY 1) AS tag_list,
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = updated.id) AS favorites_count,
                   (SELECT true FROM favorites WHERE favorites.user_id = $1 AND favorites.article_id = updated.id) IS NOT NULL AS favorited,
                   users.username, users.bio, users.image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = updated.author_id) IS NOT NULL AS following
              FROM updated
              JOIN users ON users.id = updated.author_id
            """;

    // $1 slug, $2 viewer (must be the author). No row: no such article, or not the author's.
    static final String ARTICLE_DELETE = """
            DELETE FROM articles WHERE slug = $1 AND author_id = $2 RETURNING id
            """;

    // $1 viewer, $2 slug. The statement's snapshot doesn't see its own insert, so the count adds the row it
    // inserted (none if the favorite already existed, and then it's already counted). No row: no such article.
    static final String FAVORITE = """
            WITH target AS (SELECT id FROM articles WHERE slug = $2),
                 inserted AS (INSERT INTO favorites (user_id, article_id) SELECT $1, target.id FROM target
                              ON CONFLICT DO NOTHING RETURNING 1)
            SELECT articles.id, articles.slug, articles.title, articles.description, articles.body,
                   articles.created_at, articles.updated_at,
                   ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                           FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id)
                     + (SELECT count(*) FROM inserted) AS favorites_count,
                   true AS favorited,
                   users.username, users.bio, users.image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = articles.author_id) IS NOT NULL AS following
              FROM articles
              JOIN users ON users.id = articles.author_id
             WHERE articles.id = (SELECT id FROM target)
            """;

    // $1 viewer, $2 slug. The count subtracts the row it deleted (the snapshot still sees it).
    // No row: no such article.
    static final String UNFAVORITE = """
            WITH target AS (SELECT id FROM articles WHERE slug = $2),
                 deleted AS (DELETE FROM favorites WHERE user_id = $1 AND article_id IN (SELECT id FROM target) RETURNING 1)
            SELECT articles.id, articles.slug, articles.title, articles.description, articles.body,
                   articles.created_at, articles.updated_at,
                   ARRAY(SELECT (SELECT tags.name FROM tags WHERE tags.id = article_tags.tag_id)
                           FROM article_tags WHERE article_tags.article_id = articles.id ORDER BY 1) AS tag_list,
                   (SELECT count(*) FROM favorites WHERE favorites.article_id = articles.id)
                     - (SELECT count(*) FROM deleted) AS favorites_count,
                   false AS favorited,
                   users.username, users.bio, users.image,
                   (SELECT true FROM follows WHERE follows.follower_id = $1 AND follows.followee_id = articles.author_id) IS NOT NULL AS following
              FROM articles
              JOIN users ON users.id = articles.author_id
             WHERE articles.id = (SELECT id FROM target)
            """;

    // $1 viewer, $2 slug, $3 body. No row: no such article.
    static final String COMMENT_INSERT = """
            WITH inserted AS (
                INSERT INTO comments (article_id, author_id, body)
                SELECT id, $1, $3 FROM articles WHERE slug = $2
                RETURNING id, body, created_at, updated_at, author_id
            )
            SELECT inserted.id, inserted.body, inserted.created_at, inserted.updated_at,
                   users.username, users.bio, users.image
              FROM inserted
              JOIN users ON users.id = inserted.author_id
            """;

    // $1 comment id, $2 slug, $3 viewer (must be the author). No row: no such comment, or not the viewer's.
    static final String COMMENT_DELETE = """
            DELETE FROM comments
             USING articles
             WHERE comments.id = $1 AND articles.id = comments.article_id AND articles.slug = $2 AND comments.author_id = $3
            RETURNING comments.id
            """;
}
