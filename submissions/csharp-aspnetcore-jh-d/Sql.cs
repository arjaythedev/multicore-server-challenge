namespace Conduit;

/// <summary>
/// The statements. They return exactly what SPEC.md's reference SQL returns. Differences, all measured and compared with the
/// reference on the full seed: LIMIT is a literal (a generic plan can't see a LIMIT parameter and falls back to a full scan + sort),
/// the page is cut before the per-row sub-queries run, the tag array uses a scalar sub-query instead of a join, and
/// several reference statements that only look something up are folded into the statement that needs the result.
/// $1 is always the viewer (bigint, 0 when anonymous) in article statements.
/// </summary>
static class Sql
{
    const string TagArray =
        "ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS n FROM article_tags at WHERE at.article_id = a.id ORDER BY n) AS tag_list";

    const string Counts =
        "(SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count, " +
        "EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = $1) AS favorited";

    const string Author =
        "u.username, u.bio, u.image, " +
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = a.author_id) AS following";

    // Column order read by Api.WriteArticle: slug, title, description, [body,] created_at, updated_at, tag_list, favorites_count, favorited, username, bio, image, following.
    const string ListCols = "a.slug, a.title, a.description, a.created_at, a.updated_at, " + TagArray + ", " + Counts + ", " + Author;
    const string FullCols = "a.slug, a.title, a.description, a.body, a.created_at, a.updated_at, " + TagArray + ", " + Counts + ", " + Author;
    const string ArticleJoin = " FROM articles a JOIN users u ON u.id = a.author_id";

    // ---- single articles: $1 viewer, $2 slug / id ----
    public const string BySlug = "SELECT " + FullCols + ArticleJoin + " WHERE a.slug = $2";
    public const string ById = "SELECT " + FullCols + ArticleJoin + " WHERE a.id = $2";

    // ---- lists: $1 viewer, $2 offset, [$3 filter]; the limit is a literal, one cached text per value ----
    static readonly string[][] listCache = [new string[101], new string[101], new string[101], new string[101], new string[101]];

    public const int KindAll = 0, KindTag = 1, KindAuthor = 2, KindFavorited = 3, KindFeed = 4;

    public static string List(int kind, int n) => listCache[kind][n] ??= BuildList(kind, n);

    static string BuildList(int kind, int n) => kind switch
    {
        KindAll => "SELECT " + ListCols +
                   " FROM (SELECT id, slug, title, description, created_at, updated_at, author_id FROM articles ORDER BY id DESC LIMIT " + n + " OFFSET $2) a" +
                   " JOIN users u ON u.id = a.author_id ORDER BY a.id DESC",
        KindTag => "SELECT " + ListCols + ArticleJoin +
                   " WHERE a.id IN (SELECT at.article_id FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $3)" +
                   " ORDER BY at.article_id DESC LIMIT " + n + " OFFSET $2) ORDER BY a.id DESC",
        KindAuthor => "SELECT " + ListCols + ArticleJoin +
                      " WHERE a.author_id = (SELECT au.id FROM users au WHERE au.username = $3) ORDER BY a.id DESC LIMIT " + n + " OFFSET $2",
        KindFavorited => "SELECT " + ListCols + ArticleJoin +
                         " WHERE a.id IN (SELECT f.article_id FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $3)" +
                         " ORDER BY f.article_id DESC LIMIT " + n + " OFFSET $2) ORDER BY a.id DESC",
        _ => "SELECT " + ListCols + ArticleJoin +
             " WHERE a.id IN (SELECT x.id FROM follows fo CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id" +
             " ORDER BY a2.id DESC LIMIT (" + n + " + $2)) x WHERE fo.follower_id = $1 ORDER BY x.id DESC LIMIT " + n + " OFFSET $2) ORDER BY a.id DESC",
    };

    // ---- the capped counts: $1 = filter (feed: viewer) ----
    public const string CountAll = "SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s";
    public const string CountTag = "SELECT count(*) FROM (SELECT 1 FROM article_tags at WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = $1) LIMIT 1000) s";
    public const string CountAuthor = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = $1) LIMIT 1000) s";
    public const string CountFavorited = "SELECT count(*) FROM (SELECT 1 FROM favorites f WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = $1) LIMIT 1000) s";
    public const string CountFeed = "SELECT count(*) FROM (SELECT 1 FROM articles a WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = $1) LIMIT 1000) s";

    // ---- articles: write side ----
    // $1 author, $2 title, $3 description, $4 body. The id comes from the identity sequence, as in the reference.
    public const string ArticleInsert =
        "INSERT INTO articles (id, slug, author_id, title, description, body) " +
        "SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id, $1, $2, $3, $4 " +
        "FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n RETURNING id";
    public const string TagsInsert = "INSERT INTO tags (name) SELECT DISTINCT unnest($1::text[]) ON CONFLICT (name) DO NOTHING";
    public const string ArticleTagsInsert =
        "INSERT INTO article_tags (article_id, tag_id) SELECT currval(pg_get_serial_sequence('articles', 'id')), t.id FROM tags t WHERE t.name = ANY($1::text[])";

    public const string ArticleOwner = "SELECT id, author_id FROM articles WHERE slug = $1";
    // $1 slug, $2 title, $3 description, $4 body, $5 viewer: only the author's own row is touched.
    public const string ArticleUpdate =
        "UPDATE articles SET title = COALESCE($2, title), description = COALESCE($3, description), body = COALESCE($4, body), " +
        "slug = CASE WHEN $2::text IS NULL THEN slug ELSE trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END, " +
        "updated_at = now() WHERE slug = $1 AND author_id = $5";
    public const string ArticleDelete = "DELETE FROM articles WHERE slug = $1 AND author_id = $2";

    // $1 viewer, $2 slug
    public const string FavoriteInsert =
        "INSERT INTO favorites (user_id, article_id) SELECT $1, a.id FROM articles a WHERE a.slug = $2 ON CONFLICT DO NOTHING";
    public const string FavoriteDelete =
        "DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT a.id FROM articles a WHERE a.slug = $2)";

    // ---- comments ----
    // $1 viewer, $2 slug: one row per comment, or a single all-NULL row when the article exists but has none, or no row at all (404).
    public const string Comments =
        "SELECT c.id, c.body, c.created_at, c.updated_at, c.username, c.bio, c.image, c.following FROM (SELECT id FROM articles WHERE slug = $2) a " +
        "LEFT JOIN LATERAL (SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, " +
        "EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = c.author_id) AS following " +
        "FROM comments c JOIN users u ON u.id = c.author_id WHERE c.article_id = a.id " +
        "ORDER BY c.created_at DESC, c.id DESC LIMIT 100) c ON true ORDER BY c.created_at DESC, c.id DESC";

    // $1 slug, $2 viewer, $3 body: inserts only when the article exists (no row back = 404)
    public const string CommentInsert =
        "WITH c AS (INSERT INTO comments (article_id, author_id, body) SELECT a.id, $2, $3 FROM articles a WHERE a.slug = $1 " +
        "RETURNING id, body, created_at, updated_at, author_id) " +
        "SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image FROM c JOIN users u ON u.id = c.author_id";

    // $1 comment id, $2 slug, [$3 viewer]
    public const string CommentOwner =
        "SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = $1 AND a.slug = $2";
    public const string CommentDelete =
        "DELETE FROM comments c USING articles a WHERE c.id = $1 AND a.id = c.article_id AND a.slug = $2 AND c.author_id = $3";

    // ---- users and profiles ----
    public const string UserInsert = "INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, username, email, bio, image";
    public const string UserByEmail = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = $1";
    public const string UserById = "SELECT username, email, bio, image FROM users WHERE id = $1";
    public const string UserUpdate =
        "UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username), password_hash = COALESCE($4, password_hash), " +
        "bio = COALESCE($5, bio), image = COALESCE($6, image) WHERE id = $1 RETURNING username, email, bio, image";

    public const string Profile =
        "SELECT u.username, u.bio, u.image, EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = $1 AND fo.followee_id = u.id) AS following " +
        "FROM users u WHERE u.username = $2";
    // $1 viewer, $2 username
    public const string FollowInsert = "INSERT INTO follows (follower_id, followee_id) SELECT $1, u.id FROM users u WHERE u.username = $2 ON CONFLICT DO NOTHING";
    public const string FollowDelete = "DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT u.id FROM users u WHERE u.username = $2)";
    public const string ProfileBare = "SELECT username, bio, image FROM users WHERE username = $1";

    public const string Tags = "SELECT name FROM tags ORDER BY name";
}
