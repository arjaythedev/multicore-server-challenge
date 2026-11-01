package conduit.api;

import conduit.pg.Stmt;

import static conduit.pg.Stmt.INT8;
import static conduit.pg.Stmt.TEXT;
import static conduit.pg.Stmt.TEXT_ARRAY;

/**
 * Every SQL statement, prepared on each connection at startup. These follow the reference SQL in SPEC.md; where
 * they differ, the responses come out the same:
 * <ul>
 *   <li>Lookups that only gate a write ("SELECT id FROM articles WHERE slug = $1") are folded into the write or
 *       sent in the same pipelined batch, so a request costs one round trip.</li>
 *   <li>The article selects leave out a.id, which no response shows.</li>
 *   <li>The feed's per-followee limit is computed in bigint, so a huge offset can't overflow int4.</li>
 * </ul>
 * Article columns, in order: slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count,
 * favorited, username, bio, image, following. Viewer is always $1.
 */
final class Sql {
    private Sql() {
    }

    private static final String ARTICLE_COLS = """
            SELECT a.slug, a.title, a.description, %s a.created_at, a.updated_at,
                   ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                          WHERE at.article_id = a.id ORDER BY t.name) AS tag_list,
                   (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
                   EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited,
                   u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following
              FROM articles a
              JOIN users u ON u.id = a.author_id
            """;
    private static final String LIST_SELECT = ARTICLE_COLS.formatted("");
    private static final String FULL_SELECT = ARTICLE_COLS.formatted("a.body,");
    private static final String ORDER_PAGE = " ORDER BY a.id DESC LIMIT $2 OFFSET $3";
    private static final String SLUGIFY = "trim(both '-' from lower(regexp_replace(%s, '[^A-Za-z0-9]+', '-', 'g')))";

    // ----- tags -----
    static final Stmt TAGS = Stmt.of("SELECT name FROM tags ORDER BY name");

    // ----- users -----
    static final Stmt USER_INSERT = Stmt.of("""
            INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3)
            RETURNING id, username, email, bio, image""", TEXT, TEXT, TEXT);
    static final Stmt USER_BY_EMAIL = Stmt.of(
            "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", TEXT);
    static final Stmt USER_BY_ID = Stmt.of("SELECT username, email, bio, image FROM users WHERE id = $1", INT8);
    static final Stmt USER_UPDATE = Stmt.of("""
            UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
             WHERE id = $1
            RETURNING username, email, bio, image""", INT8, TEXT, TEXT, TEXT, TEXT, TEXT);

    // ----- profiles -----
    static final Stmt PROFILE = Stmt.of("""
            SELECT u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
              FROM users u WHERE u.username = $2""", INT8, TEXT);
    static final Stmt PROFILE_PLAIN = Stmt.of("SELECT username, bio, image FROM users WHERE username = $1", TEXT);
    static final Stmt FOLLOW = Stmt.of("""
            INSERT INTO follows (follower_id, followee_id)
            SELECT $1, u.id FROM users u WHERE u.username = $2
            ON CONFLICT DO NOTHING""", INT8, TEXT);
    static final Stmt UNFOLLOW = Stmt.of("""
            DELETE FROM follows f USING users u
             WHERE f.follower_id = $1 AND f.followee_id = u.id AND u.username = $2""", INT8, TEXT);

    // ----- article reads -----
    static final Stmt ARTICLE_BY_SLUG = Stmt.of(FULL_SELECT + " WHERE a.slug = $2", INT8, TEXT);
    static final Stmt ARTICLE_BY_ID = Stmt.of(FULL_SELECT + " WHERE a.id = $2", INT8, INT8);
    /** The article this session just inserted (currval is per session, and the insert ran in this same batch). */
    static final Stmt ARTICLE_JUST_INSERTED = Stmt.of(
            FULL_SELECT + " WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))", INT8);

    static final Stmt LIST_ALL = Stmt.of(LIST_SELECT + ORDER_PAGE, INT8, INT8, INT8);
    static final Stmt LIST_TAG = Stmt.of(LIST_SELECT + """
             WHERE a.id IN (SELECT at.article_id FROM article_tags at
                             WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)
                             ORDER BY at.article_id DESC LIMIT $2 OFFSET $3)
             ORDER BY a.id DESC""", INT8, INT8, INT8, TEXT);
    static final Stmt LIST_AUTHOR = Stmt.of(LIST_SELECT
            + " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4)" + ORDER_PAGE,
            INT8, INT8, INT8, TEXT);
    static final Stmt LIST_FAVORITED = Stmt.of(LIST_SELECT + """
             WHERE a.id IN (SELECT f.article_id FROM favorites f
                             WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)
                             ORDER BY f.article_id DESC LIMIT $2 OFFSET $3)
             ORDER BY a.id DESC""", INT8, INT8, INT8, TEXT);
    static final Stmt FEED = Stmt.of(LIST_SELECT + """
             WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL
                              (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                                ORDER BY a2.id DESC LIMIT ($2 + $3)) x
                             WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3)
             ORDER BY a.id DESC""", INT8, INT8, INT8);

    static final Stmt COUNT_ALL = Stmt.of("SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s");
    static final Stmt COUNT_TAG = Stmt.of("""
            SELECT count(*) FROM (SELECT 1 FROM article_tags at
                                   WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s""", TEXT);
    static final Stmt COUNT_AUTHOR = Stmt.of("""
            SELECT count(*) FROM (SELECT 1 FROM articles a
                                   WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s""", TEXT);
    static final Stmt COUNT_FAVORITED = Stmt.of("""
            SELECT count(*) FROM (SELECT 1 FROM favorites f
                                   WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s""", TEXT);
    static final Stmt COUNT_FEED = Stmt.of("""
            SELECT count(*) FROM (SELECT 1 FROM articles a
                                   WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)
                                   LIMIT 1000) s""", INT8);

    // ----- article writes -----
    static final Stmt ARTICLE_INSERT = Stmt.of("""
            INSERT INTO articles (id, slug, author_id, title, description, body)
            SELECT n.id, %s || '-' || n.id, $1, $2, $3, $4
              FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n""".formatted(SLUGIFY.formatted("$2")),
            INT8, TEXT, TEXT, TEXT);
    static final Stmt TAGS_UPSERT = Stmt.of(
            "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING", TEXT_ARRAY);
    static final Stmt ARTICLE_TAGS_INSERT = Stmt.of("""
            INSERT INTO article_tags (article_id, tag_id)
            SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])""",
            TEXT_ARRAY);
    static final Stmt ARTICLE_OWNER = Stmt.of("SELECT id, author_id FROM articles WHERE slug = $1", TEXT);
    static final Stmt ARTICLE_UPDATE = Stmt.of("""
            UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body),
                   slug = CASE WHEN $2::text IS NULL THEN slug ELSE %s || '-' || id END,
                   updated_at = now()
             WHERE id = $1""".formatted(SLUGIFY.formatted("$2")), INT8, TEXT, TEXT, TEXT);
    static final Stmt ARTICLE_DELETE = Stmt.of("DELETE FROM articles WHERE slug = $1 AND author_id = $2", TEXT, INT8);

    // ----- favorites -----
    static final Stmt FAVORITE = Stmt.of("""
            INSERT INTO favorites (user_id, article_id)
            SELECT $1, a.id FROM articles a WHERE a.slug = $2
            ON CONFLICT DO NOTHING""", INT8, TEXT);
    static final Stmt UNFAVORITE = Stmt.of("""
            DELETE FROM favorites f USING articles a
             WHERE f.user_id = $1 AND f.article_id = a.id AND a.slug = $2""", INT8, TEXT);

    // ----- comments -----
    static final Stmt ARTICLE_EXISTS = Stmt.of("SELECT id FROM articles WHERE slug = $1", TEXT);
    static final Stmt COMMENTS = Stmt.of("""
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
                   EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following
              FROM comments c JOIN users u ON u.id = c.author_id
             WHERE c.article_id = (SELECT id FROM articles WHERE slug = $2)
             ORDER BY c.created_at DESC, c.id DESC
             LIMIT 100""", INT8, TEXT);
    static final Stmt COMMENT_INSERT = Stmt.of("""
            WITH a AS (SELECT id FROM articles WHERE slug = $1),
                 c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM a
                       RETURNING id, body, created_at, updated_at, author_id)
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
              FROM c JOIN users u ON u.id = c.author_id""", TEXT, INT8, TEXT);
    static final Stmt COMMENT_OWNER = Stmt.of("""
            SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
             WHERE c.id = $1 AND a.slug = $2""", INT8, TEXT);
    static final Stmt COMMENT_DELETE = Stmt.of("""
            DELETE FROM comments c USING articles a
             WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3""", INT8, TEXT, INT8);

    /** Forces this class to load, which declares every statement. Call before opening connections. */
    static void init() {
    }
}
