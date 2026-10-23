using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Http;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Npgsql;
using static Conduit.Data.Sql;

namespace Conduit.Endpoints;

public static class Articles
{
    /// <summary>Writes one article from the columns Sql.Columns selects, starting at column <paramref name="c"/>.</summary>
    static void Write(Utf8JsonWriter w, NpgsqlDataReader r, int c, bool body)
    {
        w.WriteStartObject();
        Rows.WriteText(w, Names.Slug, r, c++);
        Rows.WriteText(w, Names.Title, r, c++);
        Rows.WriteText(w, Names.Description, r, c++);
        if (body) Rows.WriteText(w, Names.Body, r, c++);
        JsonFields.WriteTimestamp(w, Names.CreatedAt, r.GetFieldValue<DateTime>(c++));
        JsonFields.WriteTimestamp(w, Names.UpdatedAt, r.GetFieldValue<DateTime>(c++));
        w.WritePropertyName(Names.TagList);
        Rows.WriteRaw(w, r, c++);
        w.WriteNumber(Names.FavoritesCount, r.GetInt64(c++));
        w.WriteBoolean(Names.Favorited, r.GetBoolean(c++));
        w.WriteStartObject(Names.Author);
        Rows.WritePerson(w, r, c);
        w.WriteBoolean(Names.Following, r.GetBoolean(c + 3));
        w.WriteEndObject();
        w.WriteEndObject();
    }

    /// <summary>{"article": ...} from the first row, or null when there is none.</summary>
    static readonly Func<NpgsqlDataReader, ValueTask<JsonOut?>> ReadSingle = static async r => await r.ReadAsync() ? Single(r, 0) : null;

    /// <summary>{"article": ...} from the reader's current row.</summary>
    static JsonOut Single(NpgsqlDataReader r, int c)
    {
        var j = JsonOut.Rent();
        j.W.WriteStartObject();
        j.W.WritePropertyName(Names.Article);
        Write(j.W, r, c, true);
        j.W.WriteEndObject();
        return j;
    }

    // GET /api/articles
    public static Task List(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer < 0) return Responses.Unauthorized(ctx);
        var q = ctx.Request.QueryString;
        if (!Query.TryPage(q, out long limit, out long offset)) return Responses.Unprocessable(ctx, "limit must be 1-100 and offset >= 0");
        // The first non-empty filter in the order tag, author, favorited applies.
        string? f;
        if (!string.IsNullOrEmpty(f = Query.Get(q, "tag"))) return Page(ctx, ListKind.Tag, viewer, limit, offset, f);
        if (!string.IsNullOrEmpty(f = Query.Get(q, "author"))) return Page(ctx, ListKind.Author, viewer, limit, offset, f);
        if (!string.IsNullOrEmpty(f = Query.Get(q, "favorited"))) return Page(ctx, ListKind.Favorited, viewer, limit, offset, f);
        return Page(ctx, ListKind.Global, viewer, limit, offset, null);
    }

    // GET /api/articles/feed
    public static Task Feed(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) return Responses.Unauthorized(ctx);
        if (!Query.TryPage(ctx.Request.QueryString, out long limit, out long offset)) return Responses.Unprocessable(ctx, "limit must be 1-100 and offset >= 0");
        return Page(ctx, ListKind.Feed, viewer, limit, offset, null);
    }

    /// <summary>The page and its capped count in one statement.</summary>
    static async Task Page(HttpContext ctx, ListKind kind, long viewer, long limit, long offset, string? filter)
    {
        var cmd = Db.Command(Sql.List[(int)kind], Db.P(viewer), Db.P(limit), Db.P(offset));
        // feed: per followee, the newest limit + offset articles are enough
        if (kind == ListKind.Feed) cmd.Parameters.Add(Db.P(offset > long.MaxValue - limit ? long.MaxValue : offset + limit));
        else if (filter is not null) cmd.Parameters.Add(Db.P(filter));
        await Responses.Send(ctx, 200, await Db.Reader.Run(cmd, ReadPage, ctx.RequestAborted));
    }

    static readonly Func<NpgsqlDataReader, ValueTask<JsonOut>> ReadPage = static async r =>
    {
        var j = JsonOut.Rent();
        try
        {
            var w = j.W;
            long n = 0;
            w.WriteStartObject();
            w.WriteStartArray(Names.Articles);
            while (await r.ReadAsync())
            {
                if (!r.IsDBNull(0)) Write(w, r, 0, false);
                n = r.GetInt64(r.FieldCount - 1);
            }
            w.WriteEndArray();
            w.WriteNumber(Names.ArticlesCount, n);
            w.WriteEndObject();
            return j;
        }
        catch
        {
            j.Dispose(); // the response is the error, not this buffer
            throw;
        }
    };

    // GET /api/articles/{slug}
    public static async Task Get(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer < 0) { await Responses.Unauthorized(ctx); return; }
        var j = await Db.Reader.Run(Db.Command(ArticleBySlug, Db.P(viewer), Db.P(slug)), ReadSingle, ctx.RequestAborted);
        if (j is null) await Responses.Error(ctx, 404, "article not found");
        else await Responses.Send(ctx, 200, j);
    }

    // POST /api/articles
    public static async Task Create(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "article", out var a)) { await Responses.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryReqString(a, "title", out string title) | !Body.TryReqString(a, "description", out string description)
            | !Body.TryReqString(a, "body", out string body))
        {
            await Responses.Unprocessable(ctx, "title, description and body are required");
            return;
        }
        string[]? tags = null;
        if (a.TryGetProperty("tagList", out var tl) && tl.ValueKind != JsonValueKind.Null)
        {
            if (tl.ValueKind != JsonValueKind.Array) { await Responses.Unprocessable(ctx, "tagList must be an array of non-empty strings"); return; }
            var list = new List<string>(tl.GetArrayLength());
            foreach (var t in tl.EnumerateArray())
            {
                if (t.ValueKind != JsonValueKind.String || t.GetString() is not { Length: > 0 } s)
                {
                    await Responses.Unprocessable(ctx, "tagList must be an array of non-empty strings");
                    return;
                }
                list.Add(s);
            }
            if (list.Count > 0) tags = list.ToArray();
        }

        // Insert, tags and read-back commit together, in the writer's group.
        var insert = Db.Command(InsertArticle, Db.P(viewer), Db.P(title), Db.P(description), Db.P(body));
        var select = Db.Command(InsertedArticle, Db.P(viewer));
        NpgsqlBatchCommand[] commands = tags is null ? [insert, select]
            : [insert, Db.Command(InsertTags, Db.P(tags)), Db.Command(InsertArticleTags, Db.P(tags)), select];
        var j = await Db.Writer.Run(commands, static r => Single(r!, 0), ctx.RequestAborted);
        await Responses.Send(ctx, 201, j);
    }

    // PUT /api/articles/{slug}
    public static async Task Update(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "article", out var a)) { await Responses.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryOptString(a, "title", true, out string? title) | !Body.TryOptString(a, "description", true, out string? description)
            | !Body.TryOptString(a, "body", true, out string? body))
        {
            await Responses.Unprocessable(ctx, "title, description and body must be non-empty strings");
            return;
        }

        var updated = await Db.Writer.Run(
            Db.Command(UpdateArticle, Db.P(viewer), Db.P(slug), Db.Text(title), Db.Text(description), Db.Text(body)),
            static r => r is null ? default : new Updated(r.GetInt64(0), r.IsDBNull(1) ? null : Single(r, 1)), ctx.RequestAborted);
        if (updated.Article is not null) await Responses.Send(ctx, 200, updated.Article);
        else if (updated.Author == 0) await Responses.Error(ctx, 404, "article not found");
        else await Responses.Error(ctx, 403, "not the author");
    }

    /// <summary>The article's author (0 when there is no such article), and the article if the viewer wrote it.</summary>
    readonly record struct Updated(long Author, JsonOut? Article) : IDisposable
    {
        public void Dispose() => Article?.Dispose();
    }

    // DELETE /api/articles/{slug}
    public static async Task Delete(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        long? author = await Db.Writer.Run(Db.Command(DeleteArticle, Db.P(viewer), Db.P(slug)), static r => r?.GetInt64(0), ctx.RequestAborted);
        if (author is null) await Responses.Error(ctx, 404, "article not found");
        else if (author != viewer) await Responses.Error(ctx, 403, "not the author");
        else await Responses.NoContent(ctx);
    }

    // POST and DELETE /api/articles/{slug}/favorite
    public static async Task Favorite(HttpContext ctx, string slug, bool favorite)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        var j = await Db.Writer.Run(Db.Command(favorite ? Sql.Favorite : Unfavorite, Db.P(viewer), Db.P(slug)),
            static r => r is null ? null : Single(r, 0), ctx.RequestAborted);
        if (j is null) await Responses.Error(ctx, 404, "article not found");
        else await Responses.Send(ctx, 200, j);
    }
}
