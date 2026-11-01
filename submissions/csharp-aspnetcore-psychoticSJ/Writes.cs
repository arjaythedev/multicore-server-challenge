using System.Text;
using System.Text.Json;
using Npgsql;
using NpgsqlTypes;

namespace ConduitChallenge;

internal sealed class Writes(Db db, Passwords passwords)
{
    static readonly SqlQuery FindUser = new("SELECT id, email, username, bio, image FROM users WHERE id = $1", NpgsqlDbType.Bigint);
    static readonly SqlQuery FindLogin = new("SELECT id, email, username, bio, image, password_hash FROM users WHERE email = $1", NpgsqlDbType.Text);
    static readonly SqlQuery FindArticle = new("""
        SELECT a.slug, a.title, a.description, a.body,
               ARRAY(SELECT t.name FROM article_tags at JOIN tags t ON t.id = at.tag_id
                     WHERE at.article_id = a.id ORDER BY t.name),
               a.created_at, a.updated_at, (fv.present IS NOT NULL),
               (SELECT count(*) FROM favorites f WHERE f.article_id = a.id),
               u.username, u.bio, u.image, (fo.present IS NOT NULL)
        FROM (
            SELECT id, slug, title, description, body, created_at, updated_at, author_id
            FROM articles WHERE id = $2 LIMIT 1
        ) a CROSS JOIN LATERAL (
            SELECT username, bio, image FROM users WHERE id = a.author_id LIMIT 1
        ) u
        LEFT JOIN LATERAL (
            SELECT 1 AS present FROM favorites f
            WHERE f.user_id = $1 AND f.article_id = a.id LIMIT 1
        ) fv ON true
        LEFT JOIN LATERAL (
            SELECT 1 AS present FROM follows f
            WHERE f.follower_id = $1 AND f.followee_id = a.author_id LIMIT 1
        ) fo ON true
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Bigint);
    static readonly SqlQuery RegisterUser = new("INSERT INTO users (username, email, password_hash) VALUES ($1, $2, $3) RETURNING id, email, username, bio, image", NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text);
    static readonly SqlQuery UpdateUser = new("""
        UPDATE users SET email = COALESCE($2, email), username = COALESCE($3, username),
            password_hash = COALESCE($4, password_hash), bio = COALESCE($5, bio), image = COALESCE($6, image)
        WHERE id = $1 RETURNING id, email, username, bio, image
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text);
    static readonly SqlQuery Follow = new("""
        WITH target AS MATERIALIZED (SELECT id, username, bio, image FROM users WHERE username = $2),
        changed AS (INSERT INTO follows (follower_id, followee_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING)
        SELECT username, bio, image FROM target
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text);
    static readonly SqlQuery Unfollow = new("""
        WITH target AS MATERIALIZED (SELECT id, username, bio, image FROM users WHERE username = $2),
        changed AS (DELETE FROM follows WHERE follower_id = $1 AND followee_id = (SELECT id FROM target))
        SELECT username, bio, image FROM target
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text);
    static readonly SqlQuery Favorite = new("""
        WITH target AS MATERIALIZED (SELECT id FROM articles WHERE slug = $2),
        changed AS (INSERT INTO favorites (user_id, article_id) SELECT $1, id FROM target ON CONFLICT DO NOTHING)
        SELECT id FROM target
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text);
    static readonly SqlQuery Unfavorite = new("""
        WITH target AS MATERIALIZED (SELECT id FROM articles WHERE slug = $2),
        changed AS (DELETE FROM favorites WHERE user_id = $1 AND article_id = (SELECT id FROM target))
        SELECT id FROM target
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text);
    static readonly SqlQuery CreateArticle = new("""
        INSERT INTO articles (id, slug, author_id, title, description, body)
        SELECT n.id, trim(both '-' from lower(regexp_replace($2, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || n.id,
            $1, $2, $3, $4
        FROM (SELECT nextval(pg_get_serial_sequence('articles', 'id')) AS id) n
        RETURNING id
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text);
    static readonly SqlQuery CreateTags = new("""
        INSERT INTO tags (name)
        SELECT DISTINCT n.name FROM unnest($1::text[]) AS n(name)
        WHERE NOT EXISTS (SELECT 1 FROM tags t WHERE t.name = n.name)
        ORDER BY n.name ON CONFLICT (name) DO NOTHING
        """, NpgsqlDbType.Array | NpgsqlDbType.Text);
    static readonly SqlQuery LinkTags = new("""
        INSERT INTO article_tags (article_id, tag_id)
        SELECT $1, id FROM tags WHERE name = ANY($2::text[])
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Array | NpgsqlDbType.Text);
    static readonly SqlQuery UpdateArticle = new("""
        WITH target AS MATERIALIZED (SELECT id, author_id FROM articles WHERE slug = $2),
        changed AS (
            UPDATE articles a SET title = COALESCE($3, a.title), description = COALESCE($4, a.description),
                body = COALESCE($5, a.body),
                slug = CASE WHEN $3::text IS NULL THEN a.slug ELSE
                    trim(both '-' from lower(regexp_replace($3, '[^A-Za-z0-9]+', '-', 'g'))) || '-' || a.id END,
                updated_at = now()
            FROM target t WHERE a.id = t.id AND t.author_id = $1 RETURNING a.id
        )
        SELECT t.author_id, (SELECT id FROM changed) FROM target t
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text, NpgsqlDbType.Text);
    static readonly SqlQuery DeleteArticle = new("""
        WITH target AS MATERIALIZED (SELECT id, author_id FROM articles WHERE slug = $2),
        changed AS (DELETE FROM articles a USING target t WHERE a.id = t.id AND t.author_id = $1)
        SELECT author_id FROM target
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text);
    static readonly SqlQuery CreateComment = new("""
        WITH target AS (SELECT id FROM articles WHERE slug = $2),
        changed AS (
            INSERT INTO comments (article_id, author_id, body) SELECT id, $1, $3 FROM target
            RETURNING id, body, created_at, updated_at, author_id
        )
        SELECT c.id, c.body, c.created_at, c.updated_at, u.username, u.bio, u.image, false
        FROM changed c JOIN users u ON u.id = c.author_id
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text, NpgsqlDbType.Text);
    static readonly SqlQuery DeleteComment = new("""
        WITH target AS MATERIALIZED (
            SELECT c.id, c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
            WHERE c.id = $3 AND a.slug = $2
        ), changed AS (DELETE FROM comments c USING target t WHERE c.id = t.id AND t.author_id = $1)
        SELECT author_id FROM target
        """, NpgsqlDbType.Bigint, NpgsqlDbType.Text, NpgsqlDbType.Bigint);

    public async ValueTask<ApiResult> UserAsync(long viewer, string token, CancellationToken ct)
    {
        await using var session = await db.ReadAsync(ct);
        var cmd = await session.CommandAsync(FindUser, ct);
        DbSession.Set(cmd, 0, viewer);
        var user = await UserRowAsync(cmd, ct);
        return user is null ? Json.Error(401, "Unknown user") : user.Response(token);
    }

    public async ValueTask<ApiResult> RegisterAsync(JsonElement input, CancellationToken ct)
    {
        var username = Input.Required(input, "username");
        var email = Input.Required(input, "email");
        var password = Input.Required(input, "password");
        CheckPassword(password);
        var hash = await passwords.HashAsync(password, ct);
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(RegisterUser, ct);
        DbSession.Set(cmd, 0, username);
        DbSession.Set(cmd, 1, email);
        DbSession.Set(cmd, 2, hash);
        var user = await UserRowAsync(cmd, ct);
        return user!.Response(Auth.Issue(user.Id), 201);
    }

    public async ValueTask<ApiResult> LoginAsync(JsonElement input, CancellationToken ct)
    {
        var email = Input.Required(input, "email");
        var password = Input.Required(input, "password");
        UserRow? user;
        string hash;
        await using (var session = await db.ReadAsync(ct))
        {
            var cmd = await session.CommandAsync(FindLogin, ct);
            DbSession.Set(cmd, 0, email);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return Json.Error(401, "Invalid credentials");
            user = UserRow.From(reader);
            hash = reader.GetString(5);
            await reader.NextResultAsync(ct);
        }
        return await passwords.VerifyAsync(password, hash, ct)
            ? user.Response(Auth.Issue(user.Id)) : Json.Error(401, "Invalid credentials");
    }

    public async ValueTask<ApiResult> UpdateUserAsync(long viewer, string token, JsonElement input, CancellationToken ct)
    {
        var email = Input.Optional(input, "email", false);
        var username = Input.Optional(input, "username", false);
        var password = Input.Optional(input, "password", false);
        var bio = Input.Optional(input, "bio");
        var image = Input.Optional(input, "image");
        string? hash = null;
        if (password is not null)
        {
            CheckPassword(password);
            hash = await passwords.HashAsync(password, ct);
        }
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(UpdateUser, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set<string?>(cmd, 1, email);
        DbSession.Set<string?>(cmd, 2, username);
        DbSession.Set<string?>(cmd, 3, hash);
        DbSession.Set<string?>(cmd, 4, bio);
        DbSession.Set<string?>(cmd, 5, image);
        var user = await UserRowAsync(cmd, ct);
        return user is null ? Json.Error(401, "Unknown user") : user.Response(token);
    }

    public async ValueTask<ApiResult> FollowAsync(long viewer, string username, bool follow, CancellationToken ct)
    {
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(follow ? Follow : Unfollow, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set(cmd, 1, username);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return Json.Error(404, "Unknown profile");
        var name = reader.GetString(0);
        var bio = reader.IsDBNull(1) ? null : reader.GetString(1);
        var image = reader.IsDBNull(2) ? null : reader.GetString(2);
        await reader.NextResultAsync(ct);
        return Json.Profile(name, bio, image, follow);
    }

    public async ValueTask<ApiResult> FavoriteAsync(long viewer, string slug, bool favorite, CancellationToken ct)
    {
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(favorite ? Favorite : Unfavorite, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set(cmd, 1, slug);
        long articleId;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct)) return Json.Error(404, "Unknown article");
            articleId = reader.GetInt64(0);
            await reader.NextResultAsync(ct);
        }
        return await ArticleResponseAsync(session, viewer, articleId, 200, ct);
    }

    public async ValueTask<ApiResult> CreateArticleAsync(long viewer, JsonElement input, CancellationToken ct)
    {
        var title = Input.Required(input, "title");
        var description = Input.Required(input, "description");
        var body = Input.Required(input, "body");
        var tags = Input.Tags(input);
        await using var session = await db.WriteAsync(ct);
        long id;
        await using (var tx = await session.Connection.BeginTransactionAsync(ct))
        {
            var cmd = await session.CommandAsync(CreateArticle, ct);
            DbSession.Set(cmd, 0, viewer);
            DbSession.Set(cmd, 1, title);
            DbSession.Set(cmd, 2, description);
            DbSession.Set(cmd, 3, body);
            await using (var reader = await cmd.ExecuteReaderAsync(ct))
            {
                await reader.ReadAsync(ct);
                id = reader.GetInt64(0);
                await reader.NextResultAsync(ct);
            }
            if (tags.Length > 0)
            {
                cmd = await session.CommandAsync(CreateTags, ct);
                DbSession.Set(cmd, 0, tags);
                await cmd.ExecuteNonQueryAsync(ct);
                cmd = await session.CommandAsync(LinkTags, ct);
                DbSession.Set(cmd, 0, id);
                DbSession.Set(cmd, 1, tags);
                await cmd.ExecuteNonQueryAsync(ct);
            }
            var commitAt = WriteMetrics.Stamp();
            await tx.CommitAsync(ct);
            WriteMetrics.RecordCommit(WriteMetrics.Elapsed(commitAt));
        }
        return await ArticleResponseAsync(session, viewer, id, 201, ct);
    }

    public async ValueTask<ApiResult> UpdateArticleAsync(long viewer, string slug, JsonElement input, CancellationToken ct)
    {
        var title = Input.Optional(input, "title", false);
        var description = Input.Optional(input, "description", false);
        var body = Input.Optional(input, "body", false);
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(UpdateArticle, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set(cmd, 1, slug);
        DbSession.Set<string?>(cmd, 2, title);
        DbSession.Set<string?>(cmd, 3, description);
        DbSession.Set<string?>(cmd, 4, body);
        long changedId;
        await using (var reader = await cmd.ExecuteReaderAsync(ct))
        {
            if (!await reader.ReadAsync(ct)) return Json.Error(404, "Unknown article");
            var owner = reader.GetInt64(0);
            changedId = reader.IsDBNull(1) ? 0 : reader.GetInt64(1);
            await reader.NextResultAsync(ct);
            if (owner != viewer) return Json.Error(403, "Article belongs to another author");
            if (changedId == 0) return Json.Error(404, "Unknown article");
        }
        return await ArticleResponseAsync(session, viewer, changedId, 200, ct);
    }

    public ValueTask<ApiResult> DeleteArticleAsync(long viewer, string slug, CancellationToken ct) => DeleteAsync(DeleteArticle, viewer, slug, 0, ct);
    public ValueTask<ApiResult> DeleteCommentAsync(long viewer, string slug, long id, CancellationToken ct) => DeleteAsync(DeleteComment, viewer, slug, id, ct);

    async ValueTask<ApiResult> DeleteAsync(SqlQuery query, long viewer, string slug, long id, CancellationToken ct)
    {
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(query, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set(cmd, 1, slug);
        if (ReferenceEquals(query, DeleteComment)) DbSession.Set(cmd, 2, id);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return Json.Error(404, "Unknown resource");
        var owner = reader.GetInt64(0);
        await reader.NextResultAsync(ct);
        return owner == viewer ? new ApiResult(204, null) : Json.Error(403, "Resource belongs to another author");
    }

    public async ValueTask<ApiResult> CreateCommentAsync(long viewer, string slug, JsonElement input, CancellationToken ct)
    {
        var body = Input.Required(input, "body");
        await using var session = await db.WriteAsync(ct);
        var cmd = await session.CommandAsync(CreateComment, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set(cmd, 1, slug);
        DbSession.Set(cmd, 2, body);
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return Json.Error(404, "Unknown article");
        var buffer = new PooledBuffer();
        try
        {
            using (var writer = new Utf8JsonWriter(buffer))
            {
                writer.WriteStartObject();
                writer.WritePropertyName("comment");
                Json.Comment(writer, reader);
                writer.WriteEndObject();
            }
            await reader.NextResultAsync(ct);
            return new ApiResult(201, buffer);
        }
        catch { buffer.Dispose(); throw; }
    }

    static async ValueTask<ApiResult> ArticleResponseAsync(DbSession session, long viewer, long articleId, int status, CancellationToken ct)
    {
        var cmd = await session.CommandAsync(FindArticle, ct);
        DbSession.Set(cmd, 0, viewer);
        DbSession.Set(cmd, 1, articleId);
        PooledBuffer? buffer = null;
        try
        {
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return Json.Error(404, "Unknown article");
            buffer = new PooledBuffer(2048);
            using (var writer = new Utf8JsonWriter(buffer))
            {
                writer.WriteStartObject();
                writer.WritePropertyName("article"u8);
                Json.Article(writer, reader);
                writer.WriteEndObject();
            }
            await reader.NextResultAsync(ct);
            return new ApiResult(status, buffer);
        }
        catch { buffer?.Dispose(); throw; }
    }

    static async ValueTask<UserRow?> UserRowAsync(NpgsqlCommand cmd, CancellationToken ct)
    {
        await using var reader = await cmd.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        var row = UserRow.From(reader);
        await reader.NextResultAsync(ct);
        return row;
    }

    static void CheckPassword(string password)
    {
        if (Encoding.UTF8.GetByteCount(password) > 72) throw new ApiFailure(422, "Password exceeds 72 UTF-8 bytes");
    }

    sealed record UserRow(long Id, string Email, string Username, string? Bio, string? Image)
    {
        public static UserRow From(NpgsqlDataReader reader) => new(reader.GetInt64(0), reader.GetString(1), reader.GetString(2),
            reader.IsDBNull(3) ? null : reader.GetString(3), reader.IsDBNull(4) ? null : reader.GetString(4));
        public ApiResult Response(string token, int status = 200) => Json.User(Id, Email, Username, Bio, Image, token, status);
    }
}

internal sealed class ApiFailure(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}

internal static class Input
{
    public static string Required(JsonElement input, string name) => Optional(input, name, false)
        ?? throw new ApiFailure(422, $"{name} is required");

    public static string? Optional(JsonElement input, string name, bool allowEmpty = true)
    {
        if (!input.TryGetProperty(name, out var value) || value.ValueKind == JsonValueKind.Null) return null;
        if (value.ValueKind != JsonValueKind.String) throw new ApiFailure(422, $"{name} must be a string");
        var text = Text(value);
        if (!allowEmpty && text.Length == 0) throw new ApiFailure(422, $"{name} must not be empty");
        return text;
    }

    public static string[] Tags(JsonElement input)
    {
        if (!input.TryGetProperty("tagList", out var tags) || tags.ValueKind == JsonValueKind.Null) return [];
        if (tags.ValueKind != JsonValueKind.Array) throw new ApiFailure(422, "tagList must be an array");
        var values = new string[tags.GetArrayLength()];
        var i = 0;
        foreach (var tag in tags.EnumerateArray())
        {
            if (tag.ValueKind != JsonValueKind.String || Text(tag) is not { Length: > 0 } text)
                throw new ApiFailure(422, "Tags must be non-empty strings");
            values[i++] = text;
        }
        return values;
    }

    static string Text(JsonElement value)
    {
        try { return value.GetString()!; }
        catch (InvalidOperationException) { throw new ApiFailure(422, "Invalid Unicode string"); }
    }
}
