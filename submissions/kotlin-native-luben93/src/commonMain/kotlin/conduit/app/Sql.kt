package conduit.app

import conduit.db.ReadKind
import conduit.db.WriteStmt
import conduit.pg.Oid

// The SQL catalog. Reads are batched (one execution serves every queued request of a kind, see ReadKind); the
// shapes are C# #2's (csharp-sockets-jh-d, research/sql-catalog.md), measured cheapest or tied on the full seed:
// - the page is cut in a subquery before anything is decorated (OFFSET rows cost one index step, no subqueries);
// - favorited/following are `(SELECT true ...) IS NOT NULL` PK probes: inside a batch, EXISTS became a hashed
//   subplan rebuilt per request from all of the viewer's rows;
// - tag names by tags_pkey per link (a join hashes all 200 tags per article in the generic plan);
// - lists return one row per request even for an empty page (the capped count); `OFFSET 0` keeps the count a
//   per-request subquery (pulled up, it runs once per article row);
// - a subquery that references no request column is tied to the request row with `r.i >= 0`, or it becomes an
//   InitPlan evaluated once per statement and shared by every request (rule 5).
// Writes are single statements (CTEs) with the author checks in SQL, so no write needs a separate SELECT.

private const val U =
    "unnest(\$1::int4[], \$2::int8[], \$3::int4[], \$4::int8[], \$5::text[]) AS r(i, v, l, o, k)"

private const val TAG_NAMES =
    "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at " +
        "WHERE at.article_id = a.id ORDER BY 1)"
private const val FAV_COUNT = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)"
private const val FAVORITED = "(SELECT true FROM favorites f WHERE f.user_id = r.v AND f.article_id = a.id) IS NOT NULL"
private const val FOLLOWING =
    "(SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = a.author_id) IS NOT NULL"

/** Article columns after the key columns: see [Cols]. */
private const val TAIL =
    "a.created_at, a.updated_at, $TAG_NAMES, $FAV_COUNT, $FAVORITED, u.username, u.bio, u.image"
private const val LIST_COLS = "a.slug, a.title, a.description, $TAIL"
private const val FULL_COLS = "a.slug, a.title, a.description, a.body, $TAIL"

/** A page of article ids (column `id`, newest first) -> list columns. */
private fun listOf(ids: String, following: String) =
    "SELECT $LIST_COLS, $following FROM ($ids) p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id " +
        "ORDER BY p.id DESC"

private fun list(count: String, page: String) =
    "SELECT r.i, c.n, x.* FROM $U CROSS JOIN LATERAL (SELECT $count AS n OFFSET 0) c LEFT JOIN LATERAL ($page) x ON true"

/**
 * Column layouts, all read with binary formats. Reads have `r.i` at column 0, lists the capped count (int8) at 1.
 * Article: slug, title, description, [body], created_at, updated_at, tag_list text[], favorites_count int8,
 * favorited bool, username, bio, image, following bool.
 */
internal object Cols {
    const val ARTICLE = 1      // ARTICLE_BY_SLUG / ARTICLE_BY_ID: full article from column 1
    const val LIST_COUNT = 1
    const val LIST = 2         // list article (no body) from column 2; NULL slug = empty page
    const val CREATED = 0      // ARTICLE_CREATE: full article from column 0
}

internal object Sql {
    /** Row: i, names text[] (sorted by name). */
    val TAGS = ReadKind(
        "tags",
        "SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) FROM $U",
    )

    /** k = slug. Row: i, full article. No row: 404. */
    val ARTICLE_BY_SLUG = ReadKind(
        "article",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT $FULL_COLS, $FOLLOWING " +
            "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = r.k) x",
    )

    /** o = article id (read-back after favorite/update: by id, so a concurrent rename can't 404). */
    val ARTICLE_BY_ID = ReadKind(
        "article_id",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT $FULL_COLS, $FOLLOWING " +
            "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = r.o) x",
    )

    /**
     * k = slug. Rows: i, comment id int8, created_at, updated_at, body, username, bio, image, following.
     * No row: no article (404). One row with NULL comment id: an article without comments. The viewer's followees are
     * read once per request instead of one follows probe per comment.
     */
    val COMMENTS = ReadKind(
        "comments",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (" +
            "SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, " +
            "c.author_id = ANY (f.ids) AS following FROM articles a " +
            "CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v) AS ids) f " +
            "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c " +
            "WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true " +
            "LEFT JOIN users u ON u.id = c.author_id WHERE a.slug = r.k ORDER BY c.created_at DESC, c.id DESC) x",
    )

    /** k = username. Row: i, username, bio, image, following. No row: 404. */
    val PROFILE = ReadKind(
        "profile",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT u.username, u.bio, u.image, " +
            "(SELECT true FROM follows fo WHERE fo.follower_id = r.v AND fo.followee_id = u.id) IS NOT NULL " +
            "FROM users u WHERE u.username = r.k) x",
    )

    /** v = user id. Row: i, email, username, bio, image. No row: 401. */
    val USER_BY_ID = ReadKind(
        "user",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT u.email, u.username, u.bio, u.image FROM users u " +
            "WHERE u.id = r.v) x",
    )

    /** k = email (login). Row: i, id, email, username, bio, image, password_hash. */
    val USER_BY_EMAIL = ReadKind(
        "user_email",
        "SELECT r.i, x.* FROM $U CROSS JOIN LATERAL (SELECT u.id, u.email, u.username, u.bio, u.image, " +
            "u.password_hash FROM users u WHERE u.email = r.k) x",
    )

    /**
     * Global list. Count: "a 1000th row exists" walks at most 1000 entries from the old, all-visible end of the PK,
     * the exact count only below that; both tied to the request row.
     */
    val LIST_ALL = ReadKind(
        "list",
        list(
            "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " +
                "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END",
            "SELECT $LIST_COLS, $FOLLOWING FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, " +
                "a.updated_at, a.author_id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a " +
                "JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
        ),
    )

    /**
     * LIST_ALL for offsets >= [DEEP_OFFSET]: the page's ids come from an index-only scan, so skipped rows cost no heap
     * fetch (conformance's offset=100000000 on the full seed: 26 ms instead of 3.6 s). Slower for small offsets
     * (one extra PK probe per row), which is all the workload sends.
     */
    val LIST_ALL_DEEP = ReadKind(
        "list_deep",
        list(
            "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " +
                "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END",
            listOf("SELECT a.id FROM articles a ORDER BY a.id DESC LIMIT r.l OFFSET r.o", FOLLOWING),
        ),
        maxInflight = 1,
    )
    const val DEEP_OFFSET = 500L

    /** k = author username. Authors have few articles, so the plain capped count is cheapest. */
    val LIST_AUTHOR = ReadKind(
        "list_author",
        list(
            "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = " +
                "(SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s)",
            "SELECT $LIST_COLS, $FOLLOWING FROM (SELECT a.id, a.slug, a.title, a.description, a.created_at, " +
                "a.updated_at, a.author_id FROM articles a WHERE a.author_id = " +
                "(SELECT au.id FROM users au WHERE au.username = r.k) ORDER BY a.id DESC LIMIT r.l OFFSET r.o) a " +
                "JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
        ),
    )

    /** k = tag. Every seed tag has >= 1000 articles, so "a 1000th link exists" usually answers the count. */
    val LIST_TAG = ReadKind(
        "list_tag",
        list(
            "CASE WHEN EXISTS (SELECT 1 FROM article_tags c WHERE c.tag_id = " +
                "(SELECT t.id FROM tags t WHERE t.name = r.k) OFFSET 999 LIMIT 1) THEN 1000::bigint " +
                "ELSE (SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = " +
                "(SELECT t.id FROM tags t WHERE t.name = r.k) LIMIT 1000) s) END",
            listOf(
                "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = " +
                    "(SELECT t.id FROM tags t WHERE t.name = r.k) ORDER BY at.article_id DESC LIMIT r.l OFFSET r.o",
                FOLLOWING,
            ),
        ),
    )

    /** k = username of the favoriting user. */
    val LIST_FAVORITED = ReadKind(
        "list_favorited",
        list(
            "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = " +
                "(SELECT u.id FROM users u WHERE u.username = r.k) LIMIT 1000) s)",
            listOf(
                "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = " +
                    "(SELECT fu.id FROM users fu WHERE fu.username = r.k) ORDER BY f.article_id DESC LIMIT r.l OFFSET r.o",
                FOLLOWING,
            ),
        ),
    )

    /**
     * v = viewer. Page: each followee's newest (limit + offset) articles, merged and cut. `following` is the
     * constant true: every row was selected through the viewer's follows in the same snapshot. The app clamps
     * offsets so r.l + r.o can't overflow.
     */
    val FEED = ReadKind(
        "feed",
        list(
            "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = " +
                "ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v)) LIMIT 1000) s)",
            listOf(
                "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 " +
                    "WHERE a2.author_id = fo.followee_id ORDER BY a2.id DESC LIMIT (r.l::bigint + r.o)) x " +
                    "WHERE fo.follower_id = r.v ORDER BY x.id DESC LIMIT r.l OFFSET r.o",
                "true",
            ),
        ),
    )

    val reads: List<ReadKind> = listOf(
        TAGS, ARTICLE_BY_SLUG, ARTICLE_BY_ID, COMMENTS, PROFILE, USER_BY_ID, USER_BY_EMAIL,
        LIST_ALL, LIST_ALL_DEEP, LIST_AUTHOR, LIST_TAG, LIST_FAVORITED, FEED,
    )

    private const val I8 = Oid.INT8
    private const val T = Oid.TEXT

    /**
     * $1 username, $2 email, $3 bcrypt hash. Row: id, email, username, bio, image. No row: username or email taken
     * (422); DO NOTHING (no conflict target covers both unique keys) means no 23505 in normal operation.
     */
    val USER_INSERT = WriteStmt(
        "user_insert",
        "INSERT INTO users (username, email, password_hash) VALUES (\$1, \$2, \$3) " +
            "ON CONFLICT DO NOTHING RETURNING id, email, username, bio, image",
        intArrayOf(T, T, T),
    )

    /** $1 id, $2 email, $3 username, $4 hash, $5 bio, $6 image (NULL = unchanged). Row: email, username, bio, image. */
    val USER_UPDATE = WriteStmt(
        "user_update",
        "UPDATE users SET email = COALESCE(\$2, email), username = COALESCE(\$3, username), " +
            "password_hash = COALESCE(\$4, password_hash), bio = COALESCE(\$5, bio), image = COALESCE(\$6, image) " +
            "WHERE id = \$1 RETURNING email, username, bio, image",
        intArrayOf(I8, T, T, T, T, T),
    )

    /** $1 viewer, $2 username. Row: username, bio, image (following is the constant true). No row: 404. */
    val FOLLOW = WriteStmt(
        "follow",
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = \$2), " +
            "w AS (INSERT INTO follows (follower_id, followee_id) SELECT \$1, t.id FROM t ON CONFLICT DO NOTHING) " +
            "SELECT t.username, t.bio, t.image FROM t",
        intArrayOf(I8, T),
    )

    /** $1 viewer, $2 username. Row: username, bio, image (following false). No row: 404. */
    val UNFOLLOW = WriteStmt(
        "unfollow",
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = \$2), " +
            "w AS (DELETE FROM follows fo USING t WHERE fo.follower_id = \$1 AND fo.followee_id = t.id) " +
            "SELECT t.username, t.bio, t.image FROM t",
        intArrayOf(I8, T),
    )

    /** $1 viewer, $2 slug. Row: article id (then ARTICLE_BY_ID after commit). No row: 404. */
    val FAVORITE = WriteStmt(
        "favorite",
        "WITH t AS (SELECT id FROM articles WHERE slug = \$2), " +
            "w AS (INSERT INTO favorites (user_id, article_id) SELECT \$1, t.id FROM t ON CONFLICT DO NOTHING) " +
            "SELECT t.id FROM t",
        intArrayOf(I8, T),
    )

    /** $1 viewer, $2 slug. Row: article id. No row: 404. */
    val UNFAVORITE = WriteStmt(
        "unfavorite",
        "WITH t AS (SELECT id FROM articles WHERE slug = \$2), " +
            "w AS (DELETE FROM favorites f USING t WHERE f.user_id = \$1 AND f.article_id = t.id) " +
            "SELECT t.id FROM t",
        intArrayOf(I8, T),
    )

    /**
     * $1 author, $2 slug prefix (slugify(title) + "-", computed in the app), $3 title, $4 description, $5 body,
     * $6 tagList. Article, missing tags and links in one statement (one transaction) returning the full article
     * (layout from column 0). Only missing tags are inserted, in name order (no burned ids, no deadlock inside a
     * statement); DO UPDATE returns a tag another transaction committed after this snapshot.
     */
    val ARTICLE_CREATE = WriteStmt(
        "article_create",
        "WITH n AS (SELECT nextval('articles_id_seq'::regclass) AS id), " +
            "a AS (INSERT INTO articles (id, slug, author_id, title, description, body) " +
            "SELECT n.id, \$2 || n.id, \$1, \$3, \$4, \$5 FROM n " +
            "RETURNING id, slug, title, description, body, created_at, updated_at, author_id), " +
            "e AS MATERIALIZED (SELECT id, name FROM tags WHERE name = ANY (\$6::text[])), " +
            "t AS (INSERT INTO tags (name) SELECT x.name FROM (SELECT DISTINCT unnest(\$6::text[]) AS name) x " +
            "WHERE NOT EXISTS (SELECT 1 FROM e WHERE e.name = x.name) ORDER BY x.name " +
            "ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name RETURNING id, name), " +
            "g AS (SELECT id, name FROM e UNION ALL SELECT id, name FROM t), " +
            "l AS (INSERT INTO article_tags (article_id, tag_id) SELECT a.id, g.id FROM a, g) " +
            "SELECT a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " +
            "ARRAY(SELECT g.name FROM g ORDER BY 1), 0::int8, false, u.username, u.bio, u.image, " +
            "(SELECT true FROM follows fo WHERE fo.follower_id = \$1 AND fo.followee_id = \$1) IS NOT NULL " +
            "FROM a JOIN users u ON u.id = a.author_id",
        intArrayOf(I8, T, T, T, T, Oid.TEXT_ARRAY),
    )

    /**
     * $1 viewer, $2 slug, $3 title, $4 description, $5 body (NULL = unchanged), $6 new slug prefix (NULL unless the
     * title changes). Row: id, author_id. No row: 404; author_id != viewer: 403 (the UPDATE only fires for the
     * author); else ARTICLE_BY_ID after commit.
     */
    val ARTICLE_UPDATE = WriteStmt(
        "article_update",
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = \$2), " +
            "w AS (UPDATE articles a SET title = COALESCE(\$3, a.title), description = COALESCE(\$4, a.description), " +
            "body = COALESCE(\$5, a.body), slug = CASE WHEN \$6::text IS NULL THEN a.slug ELSE \$6 || a.id END, " +
            "updated_at = now() FROM t WHERE a.id = t.id AND t.author_id = \$1) " +
            "SELECT t.id, t.author_id FROM t",
        intArrayOf(I8, T, T, T, T, T),
    )

    /** $1 viewer, $2 slug. Row: author_id. No row: 404; author_id != viewer: 403; else deleted (204). */
    val ARTICLE_DELETE = WriteStmt(
        "article_delete",
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = \$2), " +
            "w AS (DELETE FROM articles a USING t WHERE a.id = t.id AND t.author_id = \$1) " +
            "SELECT t.author_id FROM t",
        intArrayOf(I8, T),
    )

    /**
     * $1 viewer, $2 slug, $3 body. Row: id, created_at, updated_at, username, bio, image (the body is echoed from the
     * request). No row: 404.
     */
    val COMMENT_CREATE = WriteStmt(
        "comment_create",
        "WITH t AS (SELECT id FROM articles WHERE slug = \$2), " +
            "c AS (INSERT INTO comments (article_id, author_id, body) SELECT t.id, \$1, \$3 FROM t " +
            "RETURNING id, created_at, updated_at, author_id) " +
            "SELECT c.id, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id",
        intArrayOf(I8, T, T),
    )

    /**
     * $1 viewer, $2 slug, $3 comment id. Row: author_id. No row: 404 (also a comment of another article);
     * author_id != viewer: 403; else deleted (204).
     */
    val COMMENT_DELETE = WriteStmt(
        "comment_delete",
        "WITH t AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id " +
            "WHERE c.id = \$3 AND a.slug = \$2), " +
            "w AS (DELETE FROM comments c USING t WHERE c.id = t.id AND t.author_id = \$1) " +
            "SELECT t.author_id FROM t",
        intArrayOf(I8, T, I8),
    )

    val writes: List<WriteStmt> = listOf(
        USER_INSERT, USER_UPDATE, FOLLOW, UNFOLLOW, FAVORITE, UNFAVORITE,
        ARTICLE_CREATE, ARTICLE_UPDATE, ARTICLE_DELETE, COMMENT_CREATE, COMMENT_DELETE,
    )
}
