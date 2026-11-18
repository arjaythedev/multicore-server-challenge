using System.Data.Common;
using System.Text.Json;

namespace Conduit;

internal sealed partial class Api
{
    private sealed record ArticleRow(string Slug, string Title, string Description, string? Body, string[] Tags,
        DateTime CreatedAt, DateTime UpdatedAt, bool Favorited, long FavoritesCount,
        string Username, string? Bio, string? Image, bool Following);

    /// <summary>Reads one row of ListSelect (full = false) or FullSelect (full = true, which has "body" after "description").</summary>
    private static ArticleRow ReadArticle(DbDataReader r, bool full)
    {
        var o = full ? 1 : 0;
        return new ArticleRow(
            Slug: r.GetString(1),
            Title: r.GetString(2),
            Description: r.GetString(3),
            Body: full ? r.GetString(4) : null,
            Tags: r.GetFieldValue<string[]>(6 + o),
            CreatedAt: r.GetDateTime(4 + o),
            UpdatedAt: r.GetDateTime(5 + o),
            FavoritesCount: r.GetInt64(7 + o),
            Favorited: r.GetBoolean(8 + o),
            Username: r.GetString(9 + o),
            Bio: r.GetNullableString(10 + o),
            Image: r.GetNullableString(11 + o),
            Following: r.GetBoolean(12 + o));
    }

    private static void WriteArticle(Utf8JsonWriter w, ArticleRow a)
    {
        w.WriteStartObject();
        w.WriteString("slug", a.Slug);
        w.WriteString("title", a.Title);
        w.WriteString("description", a.Description);
        if (a.Body != null) w.WriteString("body", a.Body);
        w.WriteStartArray("tagList");
        foreach (var t in a.Tags) w.WriteStringValue(t);
        w.WriteEndArray();
        w.WriteString("createdAt", Ts(a.CreatedAt));
        w.WriteString("updatedAt", Ts(a.UpdatedAt));
        w.WriteBoolean("favorited", a.Favorited);
        w.WriteNumber("favoritesCount", a.FavoritesCount);
        w.WriteStartObject("author");
        WriteProfileFields(w, a.Username, a.Bio, a.Image, a.Following);
        w.WriteEndObject();
        w.WriteEndObject();
    }

    /// <summary>Runs FullSelect with the given WHERE query ($1 viewer, $2 slug or id) and writes the article, or 404.</summary>
    private async Task WriteFullArticle(HttpContext ctx, int status, string query, long viewer, object key)
    {
        ArticleRow row;
        await using (var cmd = db.CreateCommand(query))
        {
            cmd.AddInt8(viewer);
            if (key is long id) cmd.AddInt8(id);
            else cmd.AddText((string)key);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
            {
                await Http.Error(ctx, 404, "article not found");
                return;
            }
            row = ReadArticle(r, full: true);
        }
        await Http.Json(ctx, status, w =>
        {
            w.WriteStartObject();
            w.WritePropertyName("article");
            WriteArticle(w, row);
            w.WriteEndObject();
        });
    }

    private async Task WriteList(HttpContext ctx, string list, string count, long viewer, long limit, long offset, string? filter, bool feed = false)
    {
        var rows = new List<ArticleRow>();
        await using (var cmd = db.CreateCommand(list))
        {
            cmd.AddInt8(viewer);
            cmd.AddInt8(limit);
            cmd.AddInt8(offset);
            if (filter != null) cmd.AddText(filter);
            await using var r = await cmd.ExecuteReaderAsync();
            while (await r.ReadAsync()) rows.Add(ReadArticle(r, full: false));
        }
        long total;
        await using (var cmd = db.CreateCommand(count))
        {
            if (filter != null) cmd.AddText(filter);
            else if (feed) cmd.AddInt8(viewer);
            total = (long)(await cmd.ExecuteScalarAsync())!;
        }
        await Http.Json(ctx, 200, w =>
        {
            w.WriteStartObject();
            w.WriteStartArray("articles");
            foreach (var a in rows) WriteArticle(w, a);
            w.WriteEndArray();
            w.WriteNumber("articlesCount", total);
            w.WriteEndObject();
        });
    }

    // GET /api/articles
    private Task ListArticles(HttpContext ctx, long viewer, string _)
    {
        var valid = true;
        long limit = 20, offset = 0;
        string? tag = null, author = null, favorited = null;

        // One pass over the query string. Names match exactly (case-sensitive), a repeated name uses its first value,
        // and limit/offset must be plain digits: no sign, no spaces.
        foreach (var (key, value) in ctx.Request.Query)
        {
            switch (key)
            {
                case "limit":
                    valid &= Http.ParseUint(value, out limit) && limit is >= 1 and <= 100;
                    break;
                case "offset":
                    valid &= Http.ParseUint(value, out offset);
                    break;
                case "tag":
                    tag = value;
                    break;
                case "author":
                    author = value;
                    break;
                case "favorited":
                    favorited = value;
                    break;
            }
        }

        if (!valid)
            return Http.Error(ctx, 422, "limit must be 1-100 and offset >= 0");

        // The first non-empty filter in the order tag, author, favorited applies, whatever the order in the URL.
        if (!string.IsNullOrEmpty(tag))
            return WriteList(ctx, Sql.ListByTag, Sql.CountByTag, viewer, limit, offset, tag);
        if (!string.IsNullOrEmpty(author))
            return WriteList(ctx, Sql.ListByAuthor, Sql.CountByAuthor, viewer, limit, offset, author);
        if (!string.IsNullOrEmpty(favorited))
            return WriteList(ctx, Sql.ListByFavorite, Sql.CountByFavorite, viewer, limit, offset, favorited);
        return WriteList(ctx, Sql.ListAll, Sql.CountAll, viewer, limit, offset, null);
    }

    // GET /api/articles/feed
    private Task Feed(HttpContext ctx, long viewer, string _)
    {
        long limit = 20, offset = 0;
        var valid = true;

        foreach (var (key, value) in ctx.Request.Query)
        {
            switch (key)
            {
                case "limit":
                    valid &= Http.ParseUint(value, out limit) && limit is >= 1 and <= 100;
                    break;
                case "offset":
                    valid &= Http.ParseUint(value, out offset);
                    break;
            }
        }

        if (!valid)
            return Http.Error(ctx, 422, "limit must be 1-100 and offset >= 0");

        return WriteList(ctx, Sql.ListFeed, Sql.CountFeed, viewer, limit, offset, null, feed: true);
    }

    // GET /api/articles/{slug}
    private Task GetArticle(HttpContext ctx, long viewer, string slug) =>
        WriteFullArticle(ctx, 200, Sql.ArticleBySlug, viewer, slug);

    // POST /api/articles
    private async Task CreateArticle(HttpContext ctx, long viewer, string _)
    {
        using var body = await Http.ReadWrapper(ctx, "article");
        if (!body.IsValid)
        {
            await Http.Error(ctx, 422, "invalid body");
            return;
        }
        var a = body.Element;
        var okTitle = Http.ReqString(a, "title"u8, out var title);
        var okDescription = Http.ReqString(a, "description"u8, out var description);
        var okBody = Http.ReqString(a, "body"u8, out var text);
        if (!okTitle || !okDescription || !okBody)
        {
            await Http.Error(ctx, 422, "title, description and body are required");
            return;
        }

        // tagList is optional: an array of non-empty strings.
        var tags = new List<string>();
        if (a.TryGetProperty("tagList"u8, out var tagList) && tagList.ValueKind != JsonValueKind.Null)
        {
            if (tagList.ValueKind != JsonValueKind.Array)
            {
                await Http.Error(ctx, 422, "tagList must be an array of non-empty strings");
                return;
            }
            foreach (var item in tagList.EnumerateArray())
            {
                string? tag = null;
                try { if (item.ValueKind == JsonValueKind.String) tag = item.GetString(); }
                catch (InvalidOperationException) { }
                if (string.IsNullOrEmpty(tag))
                {
                    await Http.Error(ctx, 422, "tagList must be an array of non-empty strings");
                    return;
                }
                tags.Add(tag);
            }
        }

        long id;
        await using (var conn = await db.OpenConnectionAsync())
        await using (var tx = await conn.BeginTransactionAsync())
        {
            await using (var cmd = new Npgsql.NpgsqlCommand(Sql.InsertArticle, conn, tx))
            {
                cmd.AddInt8(viewer);
                cmd.AddText(title);
                cmd.AddText(description);
                cmd.AddText(text);
                id = (long)(await cmd.ExecuteScalarAsync())!;
            }
            if (tags.Count > 0)
            {
                var names = tags.ToArray();
                await using (var cmd = new Npgsql.NpgsqlCommand(Sql.InsertTags, conn, tx))
                {
                    cmd.AddTextArray(names);
                    await cmd.ExecuteNonQueryAsync();
                }
                await using (var cmd = new Npgsql.NpgsqlCommand(Sql.InsertArticleTags, conn, tx))
                {
                    cmd.AddInt8(id);
                    cmd.AddTextArray(names);
                    await cmd.ExecuteNonQueryAsync();
                }
            }
            await tx.CommitAsync();
        }
        await WriteFullArticle(ctx, 201, Sql.ArticleById, viewer, id);
    }

    /// <summary>SELECT id, author_id FROM articles WHERE slug = $1: 404 if missing, 403 if the viewer isn't the author. Returns 0 after responding.</summary>
    private async Task<long> OwnArticle(HttpContext ctx, long viewer, string slug)
    {
        long id, authorId;
        await using (var cmd = db.CreateCommand("SELECT id, author_id FROM articles WHERE slug = $1"))
        {
            cmd.AddText(slug);
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync())
            {
                await Http.Error(ctx, 404, "article not found");
                return 0;
            }
            id = r.GetInt64(0);
            authorId = r.GetInt64(1);
        }
        if (authorId != viewer)
        {
            await Http.Error(ctx, 403, "not the author");
            return 0;
        }
        return id;
    }

    // PUT /api/articles/{slug}
    private async Task UpdateArticle(HttpContext ctx, long viewer, string slug)
    {
        using var body = await Http.ReadWrapper(ctx, "article");
        if (!body.IsValid)
        {
            await Http.Error(ctx, 422, "invalid body");
            return;
        }
        var ok = Http.OptString(body.Element, "title"u8, true, out var title)
               & Http.OptString(body.Element, "description"u8, true, out var description)
               & Http.OptString(body.Element, "body"u8, true, out var text);
        if (!ok)
        {
            await Http.Error(ctx, 422, "title, description and body must be non-empty strings");
            return;
        }
        var id = await OwnArticle(ctx, viewer, slug);
        if (id == 0) return;

        await using (var cmd = db.CreateCommand(Sql.UpdateArticle))
        {
            cmd.AddInt8(id);
            cmd.AddText(title);
            cmd.AddText(description);
            cmd.AddText(text);
            await cmd.ExecuteNonQueryAsync();
        }
        await WriteFullArticle(ctx, 200, Sql.ArticleById, viewer, id);
    }

    // DELETE /api/articles/{slug}
    private async Task DeleteArticle(HttpContext ctx, long viewer, string slug)
    {
        var id = await OwnArticle(ctx, viewer, slug);
        if (id == 0) return;
        await using (var cmd = db.CreateCommand("DELETE FROM articles WHERE id = $1"))
        {
            cmd.AddInt8(id);
            await cmd.ExecuteNonQueryAsync();
        }
        await Http.NoContent(ctx);
    }

    /// <summary>SELECT id FROM articles WHERE slug = $1. Returns 0 after responding 404.</summary>
    private async Task<long> ArticleId(HttpContext ctx, string slug)
    {
        await using var cmd = db.CreateCommand("SELECT id FROM articles WHERE slug = $1");
        cmd.AddText(slug);
        var id = await cmd.ExecuteScalarAsync();
        if (id is null)
        {
            await Http.Error(ctx, 404, "article not found");
            return 0;
        }
        return (long)id;
    }

    // POST and DELETE /api/articles/{slug}/favorite
    private async Task Favorite(HttpContext ctx, long viewer, string slug, bool favorite)
    {
        var id = await ArticleId(ctx, slug);
        if (id == 0) return;
        await using (var cmd = db.CreateCommand(favorite
            ? "INSERT INTO favorites (user_id, article_id) VALUES ($1, $2) ON CONFLICT DO NOTHING"
            : "DELETE FROM favorites WHERE user_id = $1 AND article_id = $2"))
        {
            cmd.AddInt8(viewer);
            cmd.AddInt8(id);
            await cmd.ExecuteNonQueryAsync();
        }
        await WriteFullArticle(ctx, 200, Sql.ArticleById, viewer, id);
    }
}
