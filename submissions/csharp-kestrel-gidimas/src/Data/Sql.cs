namespace Conduit.Data;

/// <summary>
/// The statements, following SPEC.md's reference SQL. @viewer is the requesting user's id (0 when anonymous;
/// no user has id 0).
/// </summary>
internal static class Sql
{
    /// <summary>
    /// Everything after the article's own text columns, shared by the list and full selects. Tag names are looked
    /// up by primary key per tag; joining tags instead made Postgres hash the whole tags table for every article.
    /// </summary>
    private const string ArticleRest = """
        a.created_at, a.updated_at,
               ARRAY(SELECT (SELECT t.name FROM tags t WHERE t.id = at.tag_id) AS name
                       FROM article_tags at WHERE at.article_id = a.id ORDER BY 1) AS tag_list,
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id) AS favorites_count,
               EXISTS (SELECT 1 FROM favorites f WHERE f.article_id = a.id AND f.user_id = @viewer) AS favorited,
               u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = a.author_id) AS following
        """;

    private const string ListColumns = "SELECT a.id, a.slug, a.title, a.description, " + ArticleRest;
    private const string ArticleListSelect = ListColumns + " FROM articles a JOIN users u ON u.id = a.author_id";
    private const string ArticleFullSelect = "SELECT a.id, a.slug, a.title, a.description, a.body, " + ArticleRest +
        " FROM articles a JOIN users u ON u.id = a.author_id";

    public const string ArticleBySlug = ArticleFullSelect + " WHERE a.slug = @slug";
    public const string ArticleById = ArticleFullSelect + " WHERE a.id = @id";

    // Lists: the page, then the capped count (articlesCount stops at 1,000), sent together in one round trip.
    // Each list picks its page of articles first and only then computes tags, counts and flags, so rows skipped by
    // OFFSET cost nothing (computing them for skipped rows made offset 400 take 20 ms instead of 1.6 ms).
    // An unknown tag or username makes the subselect NULL, which matches nothing: an empty list.

    public const string ListAll = ListColumns + """
          FROM (SELECT * FROM articles ORDER BY id DESC LIMIT @limit OFFSET @offset) a
          JOIN users u ON u.id = a.author_id
         ORDER BY a.id DESC;
        SELECT count(*) FROM (SELECT 1 FROM articles a LIMIT 1000) s;
        """;

    public const string ListByTag = ArticleListSelect + """
         WHERE a.id IN (SELECT at.article_id FROM article_tags at
                         WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = @tag)
                         ORDER BY at.article_id DESC LIMIT @limit OFFSET @offset)
         ORDER BY a.id DESC;
        SELECT count(*) FROM (SELECT 1 FROM article_tags at
                               WHERE at.tag_id = (SELECT t.id FROM tags t WHERE t.name = @tag) LIMIT 1000) s;
        """;

    public const string ListByAuthor = ListColumns + """
          FROM (SELECT * FROM articles
                 WHERE author_id = (SELECT au.id FROM users au WHERE au.username = @author)
                 ORDER BY id DESC LIMIT @limit OFFSET @offset) a
          JOIN users u ON u.id = a.author_id
         ORDER BY a.id DESC;
        SELECT count(*) FROM (SELECT 1 FROM articles a
                               WHERE a.author_id = (SELECT u.id FROM users u WHERE u.username = @author) LIMIT 1000) s;
        """;

    public const string ListByFavorited = ArticleListSelect + """
         WHERE a.id IN (SELECT f.article_id FROM favorites f
                         WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = @favorited)
                         ORDER BY f.article_id DESC LIMIT @limit OFFSET @offset)
         ORDER BY a.id DESC;
        SELECT count(*) FROM (SELECT 1 FROM favorites f
                               WHERE f.user_id = (SELECT fu.id FROM users fu WHERE fu.username = @favorited) LIMIT 1000) s;
        """;

    /// <summary>
    /// Articles by followed authors. The lateral join takes only each author's newest limit+offset articles, so the
    /// work is bounded per author instead of reading everything the followed authors ever wrote.
    /// </summary>
    public const string Feed = ArticleListSelect + """
         WHERE a.id IN (SELECT x.id FROM follows fo
                        CROSS JOIN LATERAL (SELECT a2.id FROM articles a2 WHERE a2.author_id = fo.followee_id
                                             ORDER BY a2.id DESC LIMIT (@limit + @offset)) x
                         WHERE fo.follower_id = @viewer
                         ORDER BY x.id DESC LIMIT @limit OFFSET @offset)
         ORDER BY a.id DESC;
        SELECT count(*) FROM (SELECT 1 FROM articles a
                               WHERE a.author_id IN (SELECT fo.followee_id FROM follows fo WHERE fo.follower_id = @viewer)
                               LIMIT 1000) s;
        """;

    // Article writes. The slug is the slugified title plus the id, so the id is drawn from the sequence first.

    public const string InsertArticle = """
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, trim(both '-' from lower(regexp_replace(@title, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
               @viewer, @title, @description, @body
          FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
        RETURNING id
        """;

    public const string InsertTags = "INSERT INTO tags (name) SELECT DISTINCT unnest(@tags::text[]) ON CONFLICT (name) DO NOTHING";

    public const string LinkTags = """
        INSERT INTO article_tags (article_id, tag_id) SELECT @id, t.id FROM tags t WHERE t.name = ANY(@tags::text[])
        """;

    public const string ArticleOwner = "SELECT id, author_id FROM articles WHERE slug = @slug";

    public const string UpdateArticle = """
        UPDATE articles
           SET title = COALESCE(@title, title), description = COALESCE(@description, description), body = COALESCE(@body, body),
               slug = CASE WHEN @title::text IS NULL THEN slug
                           ELSE trim(both '-' from lower(regexp_replace(@title, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || id END,
               updated_at = now()
         WHERE id = @id
        """;

    public const string DeleteArticle = "DELETE FROM articles WHERE id = @id";

    public const string ArticleIdBySlug = "SELECT id FROM articles WHERE slug = @slug";
    public const string InsertFavorite = "INSERT INTO favorites (user_id, article_id) VALUES (@viewer, @id) ON CONFLICT DO NOTHING";
    public const string DeleteFavorite = "DELETE FROM favorites WHERE user_id = @viewer AND article_id = @id";

    // Comments.

    /// <summary>The article's existence (→ 404) and its newest 100 comments, in one round trip.</summary>
    public const string Comments = """
        SELECT id FROM articles WHERE slug = @slug;
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = c.author_id) AS following
          FROM comments c JOIN users u ON u.id = c.author_id
         WHERE c.article_id = (SELECT id FROM articles WHERE slug = @slug)
         ORDER BY c.created_at DESC, c.id DESC
         LIMIT 100;
        """;

    public const string InsertComment = """
        WITH c AS (INSERT INTO comments (article_id, author_id, body) VALUES (@id, @viewer, @body)
                   RETURNING id, body, created_at, updated_at, author_id)
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image
          FROM c JOIN users u ON u.id = c.author_id
        """;

    public const string CommentAuthor = """
        SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id WHERE c.id = @id AND a.slug = @slug
        """;

    public const string DeleteComment = "DELETE FROM comments WHERE id = @id";

    // Users and profiles.

    public const string InsertUser = """
        INSERT INTO users (username, email, password_hash) VALUES (@username, @email, @passwordHash)
        RETURNING id, username, email, bio, image
        """;

    public const string UserByEmail = "SELECT id, username, email, bio, image, password_hash FROM users WHERE email = @email";
    public const string UserById = "SELECT id, username, email, bio, image FROM users WHERE id = @viewer";

    public const string UpdateUser = """
        UPDATE users SET email = COALESCE(@email, email), username = COALESCE(@username, username),
               password_hash = COALESCE(@passwordHash, password_hash), bio = COALESCE(@bio, bio), image = COALESCE(@image, image)
         WHERE id = @viewer
        RETURNING id, username, email, bio, image
        """;

    public const string Profile = """
        SELECT u.id, u.username, u.bio, u.image,
               EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = @viewer AND fo.followee_id = u.id) AS following
          FROM users u WHERE u.username = @username
        """;

    public const string ProfileBase = "SELECT id, username, bio, image FROM users WHERE username = @username";
    public const string InsertFollow = "INSERT INTO follows (follower_id, followee_id) VALUES (@viewer, @id) ON CONFLICT DO NOTHING";
    public const string DeleteFollow = "DELETE FROM follows WHERE follower_id = @viewer AND followee_id = @id";

    public const string Tags = "SELECT name FROM tags ORDER BY name";
}
