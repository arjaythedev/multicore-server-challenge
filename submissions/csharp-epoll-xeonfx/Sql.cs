/// <summary>
/// The SQL. Reads run in batches: every read statement takes arrays of distinct keys (one per batch, whoever asked
/// for them) and tags each row with its key's 1-based ordinal k, so the same page, tag, author, slug, username or
/// viewer asked for by several waiting requests is read once. Phase A finds what each request is about; phase B
/// enriches the union of the articles it found (tags, favorites count, author) and answers the viewers'
/// favorited/following flags with one primary-key scan per viewer. Writes run one statement per request in group
/// commits. Responses match SPEC.md's reference SQL.
/// </summary>
static class Sql
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

    /// <summary>Article columns, read by Loop.Article in this order.</summary>
    static string Columns(bool body, string favorited = Favorited, string favoritesCount = FavoritesCount, string? following = null) =>
        $"a.slug, a.title, a.description, {(body ? "a.body, " : "")}a.created_at, a.updated_at, {TagList}, {favoritesCount}, {favorited}, " +
        $"u.username, u.bio, u.image, {following ?? Following("a.author_id")}";

    // ---------- batched reads ----------

    /// <summary>Phase A and phase B of a batch share one snapshot.</summary>
    public const string Begin = "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY";
    public const string Commit = "COMMIT";
    public const string Rollback = "ROLLBACK";

    /// <summary>The tag names as one JSON array (NULL without tags). array_to_json, not json_agg: json_agg puts a space
    /// after every comma.</summary>
    public const string Tags = "SELECT convert_to(array_to_json(array_agg(name ORDER BY name))::text, 'UTF8') FROM tags";

    /// <summary>k, username, email, bio, image.</summary>
    public const string Users =
        "SELECT r.k, u.username, u.email, u.bio, u.image FROM unnest($1::int8[]) WITH ORDINALITY r(id, k) JOIN users u ON u.id = r.id";

    /// <summary>k, id, username, email, bio, image, password_hash.</summary>
    public const string Login =
        "SELECT r.k, u.id, u.username, u.email, u.bio, u.image, u.password_hash " +
        "FROM unnest($1::text[]) WITH ORDINALITY r(email, k) JOIN users u ON u.email = r.email";

    /// <summary>k, id, username, bio, image; following comes from phase B.</summary>
    public const string Profiles =
        "SELECT r.k, u.id, u.username, u.bio, u.image FROM unnest($1::text[]) WITH ORDINALITY r(name, k) JOIN users u ON u.username = r.name";

    /// <summary>An article's own columns after k, in the order Loop reads them.</summary>
    const string ArticleColumns = "a.id, a.author_id, a.slug, a.title, a.description, a.created_at, a.updated_at";
    /// <summary>A count row's padding: NULLs typed as <see cref="ArticleColumns"/> after the id.</summary>
    const string CountPadding = "NULL::int8, NULL::text, NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz";

    /// <summary>k, the article columns, body.</summary>
    public const string Articles =
        $"SELECT r.k, {ArticleColumns}, a.body FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug";

    /// <summary>k, then id, created_at, updated_at, body, author_id, username, bio, image of each of the article's
    /// newest 100 comments. No row: unknown article. One row with a NULL id: no comments.</summary>
    public const string Comments =
        "SELECT r.k, c.id, c.created_at, c.updated_at, c.body, c.author_id, u.username, u.bio, u.image " +
        "FROM unnest($1::text[]) WITH ORDINALITY r(slug, k) JOIN articles a ON a.slug = r.slug " +
        "LEFT JOIN LATERAL (SELECT c.id, c.created_at, c.updated_at, c.body, c.author_id FROM comments c WHERE c.article_id = a.id " +
        "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true LEFT JOIN users u ON u.id = c.author_id";

    /// <summary>min(1000, rows): a 1000th row proves the cap without counting to it.</summary>
    static string Capped(string from, string key) =>
        $"CASE WHEN EXISTS (SELECT 1 {from} ORDER BY {key} OFFSET 999 LIMIT 1) THEN 1000::int8 ELSE (SELECT count(*) {from}) END";

    static string Capped(string select) => $"(SELECT count(*) FROM ({select} LIMIT 1000) s)";

    /// <summary>
    /// A list statement: the capped counts (rows with k &lt;= 0: -k is the count key, the count in column 1) and the
    /// pages (k &gt; 0: the article columns) in one statement. <paramref name="ids"/> picks a page's ids with LIMIT
    /// r.lim OFFSET r.off, by index alone; the articles are read for those ids only. The page's ids come through a
    /// constant LIMIT 100 (the largest limit allowed): with only r.lim the generic plan expects a tenth of the table and
    /// joins the articles by hash.
    /// </summary>
    static string List(string counts, string pages, string ids) =>
        $"{counts} UNION ALL SELECT r.k, {ArticleColumns} FROM {pages} " +
        $"CROSS JOIN LATERAL (SELECT p.id FROM ({ids} LIMIT 100 OFFSET r.off) p LIMIT r.lim) p JOIN articles a ON a.id = p.id";

    /// <summary>$1 limits, $2 offsets.</summary>
    public static readonly string Global = List(
        $"SELECT 0::int8, {Capped("FROM articles a", "a.id")}, {CountPadding}",
        "unnest($1::int8[], $2::int8[]) WITH ORDINALITY r(lim, off, k)",
        "SELECT id FROM articles ORDER BY id DESC");

    /// <summary>$1 the tags to count, then $2 tags, $3 limits, $4 offsets of the pages.</summary>
    public static readonly string Tag = List(
        $"SELECT -r.k, {Capped("FROM article_tags at WHERE at.tag_id = t.id", "at.article_id")}, {CountPadding} " +
        "FROM unnest($1::text[]) WITH ORDINALITY r(name, k) LEFT JOIN tags t ON t.name = r.name",
        "unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(name, lim, off, k) JOIN tags t ON t.name = r.name",
        "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = t.id ORDER BY at.article_id DESC");

    /// <summary>As <see cref="Tag"/>, by author username.</summary>
    public static readonly string Author = List(
        $"SELECT -r.k, {Capped("SELECT 1 FROM articles a WHERE a.author_id = u.id")}, {CountPadding} " +
        "FROM unnest($1::text[]) WITH ORDINALITY r(name, k) LEFT JOIN users u ON u.username = r.name",
        "unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(name, lim, off, k) JOIN users u ON u.username = r.name",
        "SELECT a2.id FROM articles a2 WHERE a2.author_id = u.id ORDER BY a2.id DESC");

    /// <summary>As <see cref="Tag"/>, by the username who favorited.</summary>
    public static readonly string FavoritedBy = List(
        $"SELECT -r.k, {Capped("SELECT 1 FROM favorites f WHERE f.user_id = u.id")}, {CountPadding} " +
        "FROM unnest($1::text[]) WITH ORDINALITY r(name, k) LEFT JOIN users u ON u.username = r.name",
        "unnest($2::text[], $3::int8[], $4::int8[]) WITH ORDINALITY r(name, lim, off, k) JOIN users u ON u.username = r.name",
        "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = u.id ORDER BY f.article_id DESC");

    /// <summary>$1 the viewers to count, then $2 viewers, $3 limits, $4 offsets and $5 limit + offset of the pages:
    /// per followee, its newest limit + offset articles are enough.</summary>
    public static readonly string Feed = List(
        $"SELECT -r.k, {Capped("SELECT 1 FROM articles a WHERE a.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = r.v))")}, {CountPadding} " +
        "FROM unnest($1::int8[]) WITH ORDINALITY r(v, k)",
        "unnest($2::int8[], $3::int8[], $4::int8[], $5::int8[]) WITH ORDINALITY r(v, lim, off, depth, k)",
        "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " +
        "ORDER BY a2.id DESC LIMIT r.depth) x WHERE fo.follower_id = r.v ORDER BY x.id DESC");

    /// <summary>Phase B, once per distinct article: $1 ids, $2 their authors. id, the tag list as JSON, the favorites
    /// count, the author's username, bio and image.</summary>
    public const string Enrich =
        "SELECT r.id, convert_to(array_to_json(ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) " +
        "FROM article_tags at WHERE at.article_id = r.id ORDER BY 1))::text, 'UTF8'), " +
        "(SELECT count(*) FROM favorites f WHERE f.article_id = r.id), u.username, u.bio, u.image " +
        "FROM unnest($1::int8[], $2::int8[]) r(id, author) JOIN users u ON u.id = r.author";

    /// <summary>Phase B, the viewers' flags: ($1 viewer, $2 article) pairs asked about favorites and ($3 viewer,
    /// $4 user) pairs asked about follows. Rows (0, viewer, article) for each favorite that exists and (1, viewer, user)
    /// for each follow; each viewer's pairs are one primary-key scan (= ANY) instead of a probe each.</summary>
    public const string Flags =
        "SELECT 0::int8, p.v, f.article_id FROM (SELECT v, array_agg(a) AS aa FROM unnest($1::int8[], $2::int8[]) x(v, a) GROUP BY v) p " +
        "CROSS JOIN LATERAL (SELECT f.article_id FROM favorites f WHERE f.user_id = p.v AND f.article_id = ANY (p.aa)) f " +
        "UNION ALL " +
        "SELECT 1::int8, q.v, fo.followee_id FROM (SELECT v, array_agg(u) AS uu FROM unnest($3::int8[], $4::int8[]) x(v, u) GROUP BY v) q " +
        "CROSS JOIN LATERAL (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = q.v AND fo.followee_id = ANY (q.uu)) fo";

    // ---------- writes ----------

    // ---------- users ----------

    public const string Register = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image";
    public const string UpdateUser =
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), " +
        "bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING username, email, bio, image";

    // ---------- profiles ----------

    public const string Follow =
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), " +
        "w AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM t ON CONFLICT DO NOTHING) " +
        "SELECT username, bio, image FROM t";
    public const string Unfollow =
        "WITH t AS (SELECT id, username, bio, image FROM users WHERE username = $2), " +
        "w AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM t)) " +
        "SELECT username, bio, image FROM t";

    // ---------- single articles ----------

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

    /// <summary>$2 body, $3 slug. No row: unknown article. The body comes back so the server keeps nothing while it
    /// waits; the columns are a listed comment's without following, which is false for one's own comment.</summary>
    public const string CreateComment =
        "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $1, $2 FROM articles a WHERE a.slug = $3 " +
        "RETURNING id, created_at, updated_at, body) " +
        "SELECT c.id, c.created_at, c.updated_at, c.body, u.username, u.bio, u.image FROM c, users u WHERE u.id = $1";

    /// <summary>$2 comment id, $3 slug. Returns author_id; the comment is deleted only if the viewer wrote it.</summary>
    public const string DeleteComment =
        "WITH c AS (SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $2 AND a.slug = $3), " +
        "d AS (DELETE FROM comments WHERE id = (SELECT id FROM c WHERE author_id = $1)) " +
        "SELECT author_id FROM c";

}

/// <summary>The prepared statements by number: each one's wire name is 'A' + its number.</summary>
static class Statement
{
    public const byte Begin = 0, Commit = 1, Rollback = 2, Tags = 3, Users = 4, Login = 5, Profile = 6, Article = 7, Comments = 8,
        Global = 9, Tag = 10, Author = 11, Favorited = 12, Feed = 13, Enrich = 14, Flags = 15,
        Register = 16, UpdateUser = 17, Follow = 18, Unfollow = 19, InsertArticle = 20, InsertTags = 21, InsertArticleTags = 22,
        InsertedArticle = 23, UpdateArticle = 24, DeleteArticle = 25, Favorite = 26, Unfavorite = 27, CreateComment = 28,
        DeleteComment = 29;

    public const uint Int8 = 20, Text = 25, Int8Array = 1016, TextArray = 1009;

    /// <summary>Every statement by number, with its parameter types; prepared once on every connection.</summary>
    public static readonly (string Sql, uint[] Types)[] All =
    [
        (Sql.Begin, []),
        (Sql.Commit, []),
        (Sql.Rollback, []),
        (Sql.Tags, []),
        (Sql.Users, [Int8Array]),
        (Sql.Login, [TextArray]),
        (Sql.Profiles, [TextArray]),
        (Sql.Articles, [TextArray]),
        (Sql.Comments, [TextArray]),
        (Sql.Global, [Int8Array, Int8Array]),
        (Sql.Tag, [TextArray, TextArray, Int8Array, Int8Array]),
        (Sql.Author, [TextArray, TextArray, Int8Array, Int8Array]),
        (Sql.FavoritedBy, [TextArray, TextArray, Int8Array, Int8Array]),
        (Sql.Feed, [Int8Array, Int8Array, Int8Array, Int8Array, Int8Array]),
        (Sql.Enrich, [Int8Array, Int8Array]),
        (Sql.Flags, [Int8Array, Int8Array, Int8Array, Int8Array]),
        (Sql.Register, [Text, Text, Text]),
        (Sql.UpdateUser, [Int8, Text, Text, Text, Text, Text]),
        (Sql.Follow, [Int8, Text]),
        (Sql.Unfollow, [Int8, Text]),
        (Sql.InsertArticle, [Int8, Text, Text, Text]),
        (Sql.InsertTags, [TextArray]),
        (Sql.InsertArticleTags, [TextArray]),
        (Sql.InsertedArticle, [Int8]),
        (Sql.UpdateArticle, [Int8, Text, Text, Text, Text]),
        (Sql.DeleteArticle, [Int8, Text]),
        (Sql.Favorite, [Int8, Text]),
        (Sql.Unfavorite, [Int8, Text]),
        (Sql.CreateComment, [Int8, Text, Text]),
        (Sql.DeleteComment, [Int8, Int8, Text]),
    ];
}
