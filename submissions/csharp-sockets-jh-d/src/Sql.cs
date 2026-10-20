using System.Text.RegularExpressions;

namespace Conduit;

// All SQL in one place. In the per-request forms $1 is the viewer (0 = anonymous) wherever an article or profile is
// rendered. Article rows have the columns: id, slug, title, description, [body], created_at, updated_at, tag_list,
// favorites_count, favorited, username, bio, image, following (see Json.Article).
//
// Reads run batched (Batch.cs): the per-request query becomes the inner side of a LATERAL join over the unnested
// request parameters r(i, v = viewer, l = limit, o = offset, k = key), so it is executed once for each request.
// Subqueries that use no request parameter are tied to the request row (r.i >= 0) so they too run once per
// request rather than once per statement: no request reuses another's results.
static partial class Sql
{
    // true when the database orders text by code point (C / C.UTF-8 / POSIX): the app then sorts tag names itself
    // by UTF-8 bytes, which is exactly ORDER BY name, saving Postgres a sort node per article
    public static bool AppSortsTags;

    public static readonly Stmt Collation = Stmt.Define(
        "SELECT datlocprovider::text, datcollate, coalesce(datlocale, '') FROM pg_database WHERE datname = current_database()");

    // Tag names are looked up by primary key (the planner otherwise hash-joins a scan of all tags for every article).
    // favorited/following are bounded per-row probes rather than hashed subplans over all the viewer's rows.
    static string TagOrder => AppSortsTags ? "" : " ORDER BY 1";
    const string Following = "(SELECT true FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) IS NOT NULL";
    static string Tail(string following) =>
        "a.created_at, a.updated_at, " +
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) FROM article_tags at WHERE at.article_id = a.id" +
        TagOrder + ") AS tag_list, " +
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " +
        "(SELECT true FROM favorites f WHERE f.user_id = $1 AND f.article_id = a.id) IS NOT NULL AS favorited, " +
        "u.username, u.bio, u.image, " + following + " AS following";
    static string ArticleTail => Tail(Following);
    static string FeedTail => Tail("true"); // the viewer follows every feed author (same snapshot)

    const string ListCols = "a.id, a.slug, a.title, a.description, ";
    static string FullSelect => "SELECT a.id, a.slug, a.title, a.description, a.body, " + ArticleTail +
                                " FROM articles a JOIN users u ON u.id = a.author_id";
    // the page is cut in a subquery before anything is joined or computed: OFFSET rows cost an index step only
    const string PageCols = "SELECT a.id, a.slug, a.title, a.description, a.created_at, a.updated_at, a.author_id FROM articles a";

    // a page of article ids (a subquery producing column "id", newest first) -> article rows
    static string ListOf(string ids, string tail) =>
        "SELECT " + ListCols + tail + " FROM (" + ids + ") p JOIN articles a ON a.id = p.id JOIN users u ON u.id = a.author_id ORDER BY p.id DESC";

    // ---------- batched reads ----------

    static string Unnest(Layout l) => l switch
    {
        Layout.None => "unnest($1::int4[]) AS r(i)",
        Layout.Viewer => "unnest($1::int4[], $2::int8[]) AS r(i, v)",
        Layout.ViewerKey => "unnest($1::int4[], $2::int8[], $3::text[]) AS r(i, v, k)",
        Layout.List => "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[]) AS r(i, v, l, o)",
        _ => "unnest($1::int4[], $2::int8[], $3::int4[], $4::int8[], $5::text[]) AS r(i, v, l, o, k)",
    };

    static uint[] Oids(Layout l) => l switch
    {
        Layout.None => [Oid.Int4Array],
        Layout.Viewer => [Oid.Int4Array, Oid.Int8Array],
        Layout.ViewerKey => [Oid.Int4Array, Oid.Int8Array, Oid.TextArray],
        Layout.List => [Oid.Int4Array, Oid.Int8Array, Oid.Int4Array, Oid.Int8Array],
        _ => [Oid.Int4Array, Oid.Int8Array, Oid.Int4Array, Oid.Int8Array, Oid.TextArray],
    };

    [GeneratedRegex(@"\$(\d+)")]
    private static partial Regex ParamRef();

    // per-request parameters -> request row columns
    static string Bind(string sql, Layout l) => ParamRef().Replace(sql, m =>
    {
        int n = int.Parse(m.Groups[1].Value);
        return l switch
        {
            Layout.Viewer => n == 1 ? "r.v" : throw new ArgumentException(sql),
            Layout.ViewerKey => n == 1 ? "r.v" : n == 2 ? "r.k" : throw new ArgumentException(sql),
            _ => n switch { 1 => "r.v", 2 => "r.l", 3 => "r.o", 4 => "r.k", _ => throw new ArgumentException(sql) },
        };
    });

    static Kind Batched(string name, string perRequest, Layout l, int maxInflight = 0) => new(name, Stmt.Define(
        "SELECT r.i, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (" + Bind(perRequest, l) + ") x", Oids(l)), l, 0, maxInflight);

    // lists: (i, count, article columns...), and one row with NULL article columns when the page is empty.
    // OFFSET 0 keeps the count a subquery evaluated once per request: pulled up, it would run once per article row.
    static Kind BatchedList(string name, string page, string count, Layout l, int maxInflight = 0) => new(name, Stmt.Define(
        "SELECT r.i, c.n, x.* FROM " + Unnest(l) + " CROSS JOIN LATERAL (SELECT " + Bind(count, l) + " AS n OFFSET 0) c " +
        "LEFT JOIN LATERAL (" + Bind(page, l) + ") x ON true", Oids(l)), l, 0, maxInflight);

    // "at least 1000?" is answered by whether a 1000th row exists (OFFSET 999), cheaper than counting 1000 rows;
    // the exact count is only taken below that
    const string CountAll =
        "CASE WHEN EXISTS (SELECT 1 FROM articles c WHERE r.i >= 0 ORDER BY c.id OFFSET 999) THEN 1000 " +
        "ELSE (SELECT count(*) FROM articles c WHERE r.i >= 0) END";
    // one pass over at most 1000 index entries; EXISTS (... OFFSET 999) then count(*) scanned twice below 1000
    const string CountTag =
        "(SELECT count(*) FROM (SELECT 1 FROM article_tags c WHERE c.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) LIMIT 1000) s)";
    const string CountAuthor =
        "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE c.author_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s)";
    const string CountFavorited =
        "(SELECT count(*) FROM (SELECT 1 FROM favorites c WHERE c.user_id = (SELECT u.id FROM users u WHERE u.username = $4) LIMIT 1000) s)";
    // followees as an array: one index scan over articles_author_idx for all of them
    const string FeedAuthors = "c.author_id = ANY (ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1))";
    const string CountFeed = "(SELECT count(*) FROM (SELECT 1 FROM articles c WHERE " + FeedAuthors + " LIMIT 1000) s)";

    public static Kind Tags, Article, Comments, Profile, User, ListAll, ListTag, ListAuthor, ListFavorited, ListFeed;

    // ---------- single statements (writes, logins) ----------

    public static Stmt ArticleBySlug, ArticleInsert, TagsInsert, ArticleTagsInsert, ArticleByCurrval, ArticleUpdate,
        ArticleAuthorBySlug, ArticleDelete, FavoriteInsert, FavoriteDelete, CommentInsert, CommentDelete, CommentAuthor,
        UserInsert, UserByEmail, UserUpdate, Follow, Unfollow;

    // after the collation is known (TagOrder)
    public static void Define()
    {
        const uint I8 = Oid.Int8, T = Oid.Text;

        // the names as a text[] (in name order, from the index); the app writes the JSON
        Tags = new Kind("tags", Stmt.Define(
            "SELECT r.i, ARRAY(SELECT t.name FROM tags t WHERE r.i >= 0 ORDER BY t.name) " +
            "FROM " + Unnest(Layout.None), Oids(Layout.None)), Layout.None);
        Article = Batched("article", FullSelect + " WHERE a.slug = $2", Layout.ViewerKey);
        Comments = Batched("comments", CommentsSql, Layout.ViewerKey);
        Profile = Batched("profile", ProfileSql, Layout.ViewerKey);
        User = Batched("user", UserById, Layout.Viewer);

        ListAll = BatchedList("list", "SELECT " + ListCols + ArticleTail + " FROM (" + PageCols +
            " ORDER BY a.id DESC LIMIT $2 OFFSET $3) a JOIN users u ON u.id = a.author_id ORDER BY a.id DESC", CountAll, Layout.List);
        ListAuthor = BatchedList("author", "SELECT " + ListCols + ArticleTail + " FROM (" + PageCols +
            " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $4) ORDER BY a.id DESC LIMIT $2 OFFSET $3) a" +
            " JOIN users u ON u.id = a.author_id ORDER BY a.id DESC", CountAuthor, Layout.ListKey);
        ListTag = BatchedList("tag", ListOf(
            "SELECT at.article_id AS id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $4) " +
            "ORDER BY at.article_id DESC LIMIT $2 OFFSET $3", ArticleTail), CountTag, Layout.ListKey);
        ListFavorited = BatchedList("favorited", ListOf(
            "SELECT f.article_id AS id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $4) " +
            "ORDER BY f.article_id DESC LIMIT $2 OFFSET $3", ArticleTail), CountFavorited, Layout.ListKey);
        ListFeed = BatchedList("feed", ListOf(
            "SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id " +
            "ORDER BY a2.id DESC LIMIT ($2::bigint + $3::bigint)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT $2 OFFSET $3",
            FeedTail), CountFeed, Layout.List);

        ArticleBySlug = Stmt.Define(FullSelect + " WHERE a.slug = $2", I8, T);
        // $1 viewer, $2 slug prefix ("<slugified title>-"), $3 title, $4 description, $5 body
        ArticleInsert = Stmt.Define("""
            INSERT INTO articles (id, slug, author_id, title, description, body)
            SELECT n.id, $2 || n.id, $1, $3, $4, $5
              FROM (SELECT nextval('articles_id_seq'::regclass) AS id) n
            """, I8, T, T, T, T);
        // only tags that don't exist yet (no sequence burn), in name order (no deadlock between concurrent creates)
        TagsInsert = Stmt.Define("""
            INSERT INTO tags (name)
            SELECT n FROM (SELECT DISTINCT unnest($1::text[]) AS n) x
             WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = x.n)
             ORDER BY n
            ON CONFLICT (name) DO NOTHING
            """, Oid.TextArray);
        ArticleTagsInsert = Stmt.Define("""
            INSERT INTO article_tags (article_id, tag_id)
            SELECT (SELECT currval('articles_id_seq'::regclass)), t.id FROM tags t WHERE t.name = ANY($1::text[])
            """, Oid.TextArray);
        ArticleByCurrval = Stmt.Define(FullSelect + " WHERE a.id = (SELECT currval('articles_id_seq'::regclass))", I8);
        // $1 viewer, $2 slug, $3 title, $4 description, $5 body, $6 new slug prefix (NULL when the title is unchanged)
        ArticleUpdate = Stmt.Define("""
            WITH a AS (
              UPDATE articles SET title = COALESCE($3, title), description = COALESCE($4, description), body = COALESCE($5, body),
                     slug = CASE WHEN $6::text IS NULL THEN slug ELSE $6 || id END,
                     updated_at = now()
               WHERE slug = $2 AND author_id = $1
              RETURNING id, slug, title, description, body, created_at, updated_at, author_id)
            SELECT a.id, a.slug, a.title, a.description, a.body,
            """ + ArticleTail + " FROM a JOIN users u ON u.id = a.author_id", I8, T, T, T, T, T);
        ArticleAuthorBySlug = Stmt.Define("SELECT author_id FROM articles WHERE slug = $1", T);
        ArticleDelete = Stmt.Define("DELETE FROM articles WHERE slug = $1 AND author_id = $2", T, I8);
        // the write, then the read-back as its own statement in the same Sync group (one round trip): its snapshot
        // then includes a conflicting write that the insert waited for
        FavoriteInsert = Stmt.Define(
            "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING", I8, T);
        FavoriteDelete = Stmt.Define(
            "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)", I8, T);
        // $1 viewer, $2 slug, $3 body
        CommentInsert = Stmt.Define("""
            WITH c AS (INSERT INTO comments (article_id, author_id, body)
                       SELECT a.id, $1, $3 FROM articles a WHERE a.slug = $2
                       RETURNING id, body, created_at, updated_at, author_id)
            SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
              FROM c JOIN users u ON u.id = c.author_id
            """, I8, T, T);
        // $1 comment id, $2 slug, $3 viewer
        CommentDelete = Stmt.Define(
            "DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3", I8, T, I8);
        CommentAuthor = Stmt.Define(
            "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2", I8, T);
        UserInsert = Stmt.Define(
            "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image", T, T, T);
        UserByEmail = Stmt.Define("SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1", T);
        UserUpdate = Stmt.Define("""
            UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
                             password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
             WHERE id = $1
            RETURNING id, username, email, bio, image
            """, I8, T, T, T, T, T);
        Follow = Stmt.Define("""
            WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
                 i AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM u ON CONFLICT DO NOTHING)
            SELECT username, bio, image FROM u
            """, I8, T);
        Unfollow = Stmt.Define("""
            WITH u AS (SELECT id, username, bio, image FROM users WHERE username = $2),
                 d AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id IN (SELECT id FROM u))
            SELECT username, bio, image FROM u
            """, I8, T);
    }

    // $1 viewer, $2 slug. One row with NULL comment columns when the article has no comments; no row = no article.
    // The viewer's followees are read once for the request (an index range of ~20 rows) and each comment's author is
    // checked against that array, instead of one follows-index probe per comment (up to 100 per request).
    const string CommentsSql = """
        SELECT a.id, c.id AS comment_id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               c.author_id = ANY (f.ids) AS following
          FROM articles a
          CROSS JOIN LATERAL (SELECT ARRAY(SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) AS ids) f
          LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, c.author_id FROM comments c
                              WHERE c.article_id = a.id ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true
          LEFT JOIN users u ON u.id = c.author_id
         WHERE a.slug = $2
         ORDER BY c.created_at DESC, c.id DESC
        """;

    // $1 viewer, $2 username
    const string ProfileSql = """
        SELECT u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following
          FROM users u WHERE u.username = $2
        """;

    const string UserById = "SELECT id, username, email, bio, image FROM users WHERE id = $1";
}
