namespace Conduit.Data;

/// <summary>
/// The SQL. Responses match SPEC.md's reference SQL; the statements differ where that is cheaper for Postgres:
/// one statement per request where the reference runs several, the page is picked before the per-article
/// subqueries run (so OFFSET rows are never decorated), tag names come by primary key lookups instead of a hash
/// join over all tags per article, and an anonymous viewer skips the favorited/following probes.
/// $1 is always the viewer (0 = anonymous).
/// </summary>
public static class Sql
{
    static string Slugify(string x) => $"trim(both '-' from lower(regexp_replace({x}, '[^A-Za-z0-9]+', '-', 'g')))";

    // The tag list as JSON text, written into the response as is: cheaper for both sides than a text[] column
    // (feed CPU per request fell 11%). An article without tags gets "[]".
    const string TagList = "convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id ORDER BY 1))::text, 'UTF8')";
    const string FavoritesCount = "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id)";
    const string Favorited = "($1 <> 0 AND EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1))";
    /// <summary>Whether the viewer follows <paramref name="followee"/> (false for an anonymous viewer).</summary>
    static string Following(string followee) =>
        $"($1 <> 0 AND EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = {followee}))";

    /// <summary>Article columns, read by Articles.Write in this order.</summary>
    static string Columns(bool body, string favorited = Favorited, string favoritesCount = FavoritesCount, string? following = null) =>
        $"a.slug, a.title, a.description, {(body ? "a.body, " : "")}a.created_at, a.updated_at, {TagList}, {favoritesCount}, {favorited}, " +
        $"u.username, u.bio, u.image, {following ?? Following("a.author_id")}";

    // ---------- users ----------

    public const string Register = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image";
    public const string Login = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";
    public const string CurrentUser = "SELECT username, email, bio, image FROM users WHERE id = $1";
    public const string UpdateUser =
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), " +
        "bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING username, email, bio, image";

    // ---------- profiles ----------

    public static readonly string Profile = $"SELECT u.username, u.bio, u.image, {Following("u.id")} FROM users u WHERE u.username = $2";
    public const string Follow =
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), " +
        "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) " +
        "SELECT username, bio, image FROM t";
    public const string Unfollow =
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), " +
        "w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) " +
        "SELECT username, bio, image FROM t";

    // ---------- article lists: $2 limit, $3 offset, $4 filter (feed: limit + offset) ----------

    public enum ListKind { Global, Tag, Author, Favorited, Feed }

    /// <summary>
    /// One list page and its capped count in one statement: the count row, with the page joined to it (an empty
    /// page leaves one row whose page columns are NULL). The page's inner LIMIT is the constant 100 (the largest
    /// limit allowed) and $2 applies outside it: with a bare LIMIT $2 the generic plan expects a tenth of the table
    /// and memoizes the users join, which zeroes a hash table of that size on every execution.
    /// </summary>
    static string PageWithCount(string count, string ids, string? following = null) =>
        $"WITH c AS ({count}) SELECT p.*, c.n FROM c LEFT JOIN LATERAL (" +
        $"SELECT {Columns(false, following: following)}, a.id FROM (SELECT id FROM ({ids} LIMIT 100 OFFSET $3) b ORDER BY id DESC LIMIT $2) p " +
        "JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY a.id DESC) p ON true ORDER BY p.id DESC";

    /// <summary>min(1000, rows): small sets are counted, a 1000th row proves the cap without counting to it.</summary>
    static string Capped(string from, string key) =>
        $"SELECT CASE WHEN EXISTS (SELECT 1 {from} ORDER BY {key} OFFSET 999 LIMIT 1) THEN 1000::bigint ELSE (SELECT count(*) {from}) END AS n";

    static string Capped(string select) => $"SELECT count(*) AS n FROM ({select} LIMIT 1000) s";

    /// <summary>By <see cref="ListKind"/>. Columns: the article columns, a.id, then the count.</summary>
    public static readonly string[] List =
    [
        PageWithCount(Capped("FROM articles a", "a.id"), "SELECT id FROM articles ORDER BY id DESC"),
        PageWithCount(Capped("FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4)", "at.article_id"),
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " +
            "ORDER BY at.article_id DESC"),
        PageWithCount(Capped("SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $4)"),
            "SELECT a2.id FROM articles a2 WHERE a2.author_id = (SELECT au.id FROM users au WHERE au.username = $4) " +
            "ORDER BY a2.id DESC"),
        PageWithCount(Capped("SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4)"),
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " +
            "ORDER BY f.article_id DESC"),
        // Being in the feed proves the viewer follows the author, in the same snapshot.
        PageWithCount(Capped("SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1)"),
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " +
            "ORDER BY a2.id DESC LIMIT $4) x WHERE fo.follower_id = $1 ORDER BY x.id DESC", following: "true"),
    ];

    // ---------- single articles ----------

    public static readonly string ArticleBySlug = $"SELECT {Columns(true)} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.slug = $2";

    /// <summary>Create runs as one batch (one implicit transaction): insert, tags, article_tags, then the article.</summary>
    public static readonly string InsertArticle =
        "INSERT INTO articles (id, slug, author_id, title, description, body) " +
        $"SELECT n.id, {Slugify("$2")} || '-' || n.id, $1, $2, $3, $4 FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n";
    // New names are inserted in sorted order: two creates adding the same new tags then wait on each other in one
    // order instead of deadlocking. Two writer groups can still deadlock across their creates; the writer runs the
    // losing write again.
    public const string InsertTags = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ORDER BY 1 ON CONFLICT (name) DO NOTHING";
    public const string InsertArticleTags =
        "INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])";
    public static readonly string InsertedArticle =
        $"SELECT {Columns(true)} FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT currval(pg_get_serial_sequence('articles', 'id')))";

    /// <summary>$2 slug, $3 title, $4 description, $5 body. Returns author_id, then the article if the viewer wrote it.</summary>
    public static readonly string UpdateArticle =
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), " +
        "a AS (UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body), " +
        $"slug = CASE WHEN $3::text IS NULL THEN slug ELSE {Slugify("$3")} || '-' || id END, updated_at = now() " +
        "WHERE id = (SELECT id FROM t WHERE author_id = $1) RETURNING id, slug, title, description, body, created_at, updated_at, author_id) " +
        $"SELECT t.author_id, x.* FROM t LEFT JOIN LATERAL (SELECT {Columns(true)} FROM a JOIN users u ON u.id = a.author_id) x ON true";

    /// <summary>Returns author_id; the article is deleted only if the viewer wrote it.</summary>
    public const string DeleteArticle =
        "WITH t AS (SELECT id, author_id FROM articles WHERE slug = $2), " +
        "d AS (DELETE FROM articles WHERE id = (SELECT id FROM t WHERE author_id = $1)) " +
        "SELECT author_id FROM t";

    // The favorite toggles write and read in one statement, and the read sees the statement's snapshot: not the
    // write, and not what a concurrent transaction committed while the write waited for it (ON CONFLICT and
    // DELETE look past the snapshot). After the statement the viewer's favorite exists (favorite) or not
    // (unfavorite), whoever wrote or removed it, so the count is the snapshot's corrected by whether the snapshot
    // holds that row. Counting the rows the write changed instead goes wrong when a concurrent toggle did the work.
    const string ViewerFavoriteInSnapshot = "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1)";
    public static readonly string Favorite =
        "WITH t AS (SELECT id FROM articles WHERE slug = $2), " +
        "w AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) " +
        $"SELECT {Columns(true, "true", $"({FavoritesCount} + (NOT {ViewerFavoriteInSnapshot})::int)")} " +
        "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM t)";
    public static readonly string Unfavorite =
        "WITH t AS (SELECT id FROM articles WHERE slug = $2), " +
        "w AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM t)) " +
        $"SELECT {Columns(true, "false", $"({FavoritesCount} - ({ViewerFavoriteInSnapshot})::int)")} " +
        "FROM articles a JOIN users u ON u.id = a.author_id WHERE a.id = (SELECT id FROM t)";

    // ---------- comments ----------

    /// <summary>No row: unknown article. One row with a NULL id: no comments.</summary>
    public static readonly string Comments =
        "SELECT x.id, x.created_at, x.updated_at, x.body, x.username, x.bio, x.image, x.following FROM articles a " +
        $"LEFT JOIN LATERAL (SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image, {Following("c.author_id")} AS following " +
        "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id " +
        "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) x ON true " +
        "WHERE a.slug = $2 ORDER BY x.created_at DESC, x.id DESC";

    /// <summary>$2 body, $3 slug. No row: unknown article.</summary>
    public const string CreateComment =
        "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $2 FROM articles a WHERE a.slug = $3 " +
        "RETURNING id, created_at, updated_at) " +
        "SELECT c.id, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c, users u WHERE u.id = $1";

    /// <summary>$2 comment id, $3 slug. Returns author_id; the comment is deleted only if the viewer wrote it.</summary>
    public const string DeleteComment =
        "WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $2 AND a.slug = $3), " +
        "d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = $1)) " +
        "SELECT author_id FROM c";

    // ---------- tags ----------

    /// <summary>The tag names as one JSON array (NULL without tags), so the server copies it instead of a row per tag.
    /// array_to_json, not json_agg: json_agg puts a space after every comma.</summary>
    public const string Tags = "SELECT convert_to(array_to_json(array_agg(name ORDER BY name))::text, 'UTF8') FROM tags";
}
