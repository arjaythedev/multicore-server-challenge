package conduit;

/**
 * SQL fragments shared by the reads and writes that return articles. An article is always returned as the same
 * columns, in this order, so {@link conduit.json.Render#articleOpen} can write it from any statement:
 *
 * <pre>
 *   id, slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count,
 *   author_id, username, bio, image
 * </pre>
 *
 * followed by the viewer's favorited and following flags, or (in batched reads) with the flags in rows of their own.
 */
public final class ArticleSql {
    private ArticleSql() {
    }

    /** Statement used at startup to find out how the database orders text. */
    public static final String COLLATION =
            "SELECT datlocprovider::text, datcollate::text, coalesce(datlocale, '') FROM pg_database"
                    + " WHERE datname = current_database()";

    /**
     * True when the database orders text by code point (collation C, POSIX or C.UTF-8, as on a default Ubuntu
     * cluster). ORDER BY name then equals sorting the names' UTF-8 bytes, so the server sorts each article's few tag
     * names itself and Postgres saves a sort per article. Otherwise Postgres sorts them.
     */
    public static boolean serverSortsTags;

    public static boolean isCodePointOrder(String provider, String collate, String locale) {
        String name = "b".equals(provider) ? locale : "c".equals(provider) ? collate : null;  // builtin, libc; ICU: no
        if (name == null) return false;
        return name.equals("C") || name.equals("POSIX") || name.equalsIgnoreCase("C.UTF-8") || name.equalsIgnoreCase("C.UTF8");
    }

    /**
     * The tag names of article {@code a} (sorted, unless the server sorts them). Each name is fetched by primary key:
     * the planner would otherwise hash-join a scan of all tags for every article.
     */
    private static String tagList() {
        return "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at"
                + " WHERE at.article_id = a.id" + (serverSortsTags ? "" : " ORDER BY 1") + ")";
    }

    private static final String FAVORITES_COUNT = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)";

    /**
     * The viewer-independent columns of article {@code a} by author {@code u}, from id to image (see above).
     * favorited and following are computed per viewer afterwards.
     */
    public static String articleColumns(boolean withBody) {
        return "a.id, a.slug, a.title, a.description, " + (withBody ? "a.body, " : "")
                + "a.created_at, a.updated_at, " + tagList() + " AS tag_list, " + FAVORITES_COUNT + " AS favorites_count, "
                + "a.author_id, u.username, u.bio, u.image";
    }

    /**
     * {@code CROSS JOIN LATERAL} the viewer-independent columns of the article matching {@code condition}, as
     * relation {@code m}. The lookup runs once per outer row through an index: OFFSET 0 keeps the planner from
     * flattening it into a join, which with a generic plan's guessed row counts can become a scan of all articles.
     */
    public static String lateralArticle(String condition, boolean withBody) {
        return "CROSS JOIN LATERAL (SELECT " + articleColumns(withBody)
                + " FROM articles a JOIN users u ON u.id = a.author_id WHERE " + condition + " OFFSET 0) m";
    }

    /**
     * The final SELECT of a batched statement whose distinct articles are in relation {@code m} (columns id .. image).
     * It returns two kinds of rows with the same columns:
     *
     * <pre>
     *   i, total, favorited, following, id, slug, ..., image
     *   NULL, NULL, NULL, NULL,          an article of m          -- once per distinct article ("shared")
     *   request, count, flags, flags,    article id, NULLs...     -- per request and article it shows
     * </pre>
     *
     * so that each article's columns are sent (and rendered) once, however many requests show it. The request rows
     * are {@code SELECT requestColumns ... requestFrom}; their columns are i, total, favorited, following, article id.
     */
    public static String sharedArticles(boolean withBody, String requestColumns, String requestFrom) {
        return "SELECT NULL::int4 AS i, NULL::int8 AS total, NULL::bool AS favorited, NULL::bool AS following, m.* FROM m"
                + " UNION ALL SELECT " + requestColumns
                + ", NULL::text, NULL::text, NULL::text" + (withBody ? ", NULL::text" : "")
                + ", NULL::timestamptz, NULL::timestamptz, NULL::text[], NULL::int8, NULL::int8, NULL::text, NULL::text, NULL::text"
                + " " + requestFrom;
    }

    /** Column positions in the rows of {@link #sharedArticles}. */
    public static final int REQUEST = 0, TOTAL = 1, FAVORITED = 2, FOLLOWING = 3, ARTICLE = 4;

    /** Whether {@code viewer} favorited article {@code article}: one primary key probe. */
    public static String favorited(String viewer, String article) {
        return "EXISTS (SELECT 1 FROM favorites f WHERE f.user_id = " + viewer + " AND f.article_id = " + article + ")";
    }

    /** Whether {@code viewer} follows {@code author}: one primary key probe. */
    public static String following(String viewer, String author) {
        return "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = " + viewer + " AND fo.followee_id = " + author + ")";
    }

    /**
     * One full article (with body) for a single viewer ($1), filtered by {@code where}; used by the writes that
     * answer with the article they changed.
     */
    public static String fullArticleFor(String where) {
        return "SELECT " + articleColumns(true) + ", " + favorited("$1", "a.id") + " AS favorited, "
                + following("$1", "a.author_id") + " AS following"
                + " FROM articles a JOIN users u ON u.id = a.author_id WHERE " + where;
    }
}
