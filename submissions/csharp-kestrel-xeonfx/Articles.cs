using System;
using System.Collections.Generic;
using System.Data;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Npgsql;
using static Conduit.Sql;

namespace Conduit;

public static class Articles
{
    /// <summary>Writes one article from the columns Sql.Columns selects, starting at column <paramref name="c"/>.</summary>
    static void Write(Utf8JsonWriter w, NpgsqlDataReader r, int c, bool body)
    {
        w.WriteStartObject();
        w.WriteString(Names.Slug, r.GetString(c++));
        w.WriteString(Names.Title, r.GetString(c++));
        w.WriteString(Names.Description, r.GetString(c++));
        if (body) w.WriteString(Names.Body, r.GetString(c++));
        Http.WriteTimestamp(w, Names.CreatedAt, r.GetFieldValue<DateTime>(c++));
        Http.WriteTimestamp(w, Names.UpdatedAt, r.GetFieldValue<DateTime>(c++));
        w.WriteStartArray(Names.TagList);
        foreach (string tag in r.GetFieldValue<string[]>(c++)) w.WriteStringValue(tag);
        w.WriteEndArray();
        w.WriteNumber(Names.FavoritesCount, r.GetInt64(c++));
        w.WriteBoolean(Names.Favorited, r.GetBoolean(c++));
        w.WriteStartObject(Names.Author);
        Http.WritePerson(w, r, c);
        w.WriteBoolean(Names.Following, r.GetBoolean(c + 3));
        w.WriteEndObject();
        w.WriteEndObject();
    }

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
        if (viewer < 0) return Http.Unauthorized(ctx);
        var q = ctx.Request.QueryString;
        if (!Query.TryPage(q, out long limit, out long offset)) return Http.Unprocessable(ctx, "limit must be 1-100 and offset >= 0");
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
        if (viewer <= 0) return Http.Unauthorized(ctx);
        if (!Query.TryPage(ctx.Request.QueryString, out long limit, out long offset)) return Http.Unprocessable(ctx, "limit must be 1-100 and offset >= 0");
        return Page(ctx, ListKind.Feed, viewer, limit, offset, null);
    }

    /// <summary>The page and its capped count in one round trip.</summary>
    static async Task Page(HttpContext ctx, ListKind kind, long viewer, long limit, long offset, string? filter)
    {
        var j = JsonOut.Rent();
        var w = j.W;
        await using (var batch = Db.Source.CreateBatch())
        {
            var page = new NpgsqlBatchCommand(Sql.List[(int)kind]);
            page.Parameters.Add(Db.P(viewer));
            page.Parameters.Add(Db.P(limit));
            page.Parameters.Add(Db.P(offset));
            var count = new NpgsqlBatchCommand(Sql.Count[(int)kind]);
            if (kind == ListKind.Feed)
            {
                // per followee, the newest limit + offset articles are enough
                page.Parameters.Add(Db.P(offset > long.MaxValue - limit ? long.MaxValue : offset + limit));
                count.Parameters.Add(Db.P(viewer));
            }
            else if (filter is not null)
            {
                page.Parameters.Add(Db.P(filter));
                count.Parameters.Add(Db.P(filter));
            }
            batch.BatchCommands.Add(page);
            batch.BatchCommands.Add(count);

            await using var r = await batch.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
            w.WriteStartObject();
            w.WriteStartArray(Names.Articles);
            while (await r.ReadAsync()) Write(w, r, 0, false);
            w.WriteEndArray();
            await r.NextResultAsync();
            await r.ReadAsync();
            w.WriteNumber(Names.ArticlesCount, r.GetInt64(0));
            w.WriteEndObject();
        }
        await Http.Send(ctx, 200, j);
    }

    // GET /api/articles/{slug}
    public static async Task Get(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer < 0) { await Http.Unauthorized(ctx); return; }
        JsonOut j;
        await using (var cmd = Db.Source.CreateCommand(ArticleBySlug))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(slug));
            await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
            if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "article not found"); return; }
            j = Single(r, 0);
        }
        await Http.Send(ctx, 200, j);
    }

    // POST /api/articles
    public static async Task Create(HttpContext ctx)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "article", out var a)) { await Http.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryReqString(a, "title", out string title) | !Body.TryReqString(a, "description", out string description)
            | !Body.TryReqString(a, "body", out string body))
        {
            await Http.Unprocessable(ctx, "title, description and body are required");
            return;
        }
        string[]? tags = null;
        if (a.TryGetProperty("tagList", out var tl) && tl.ValueKind != JsonValueKind.Null)
        {
            if (tl.ValueKind != JsonValueKind.Array) { await Http.Unprocessable(ctx, "tagList must be an array of non-empty strings"); return; }
            var list = new List<string>(tl.GetArrayLength());
            foreach (var t in tl.EnumerateArray())
            {
                if (t.ValueKind != JsonValueKind.String || t.GetString() is not { Length: > 0 } s)
                {
                    await Http.Unprocessable(ctx, "tagList must be an array of non-empty strings");
                    return;
                }
                list.Add(s);
            }
            if (list.Count > 0) tags = list.ToArray();
        }

        // One round trip, one implicit transaction (the batch ends in a single Sync): it commits as a whole,
        // and the response is sent only after the reader has consumed the commit's ReadyForQuery.
        JsonOut j;
        await using (var batch = Db.Source.CreateBatch())
        {
            var insert = new NpgsqlBatchCommand(InsertArticle);
            insert.Parameters.Add(Db.P(viewer));
            insert.Parameters.Add(Db.P(title));
            insert.Parameters.Add(Db.P(description));
            insert.Parameters.Add(Db.P(body));
            batch.BatchCommands.Add(insert);
            if (tags is not null)
            {
                var insertTags = new NpgsqlBatchCommand(InsertTags);
                insertTags.Parameters.Add(Db.P(tags));
                batch.BatchCommands.Add(insertTags);
                var link = new NpgsqlBatchCommand(InsertArticleTags);
                link.Parameters.Add(Db.P(tags));
                batch.BatchCommands.Add(link);
            }
            var select = new NpgsqlBatchCommand(InsertedArticle);
            select.Parameters.Add(Db.P(viewer));
            batch.BatchCommands.Add(select);

            await using var r = await batch.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
            while (r.FieldCount == 0 && await r.NextResultAsync()) { }
            await r.ReadAsync();
            j = Single(r, 0);
        }
        await Http.Send(ctx, 201, j);
    }

    // PUT /api/articles/{slug}
    public static async Task Update(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "article", out var a)) { await Http.Unprocessable(ctx, "invalid body"); return; }
        if (!Body.TryOptString(a, "title", true, out string? title) | !Body.TryOptString(a, "description", true, out string? description)
            | !Body.TryOptString(a, "body", true, out string? body))
        {
            await Http.Unprocessable(ctx, "title, description and body must be non-empty strings");
            return;
        }

        JsonOut j;
        await using (var cmd = Db.Source.CreateCommand(UpdateArticle))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(slug));
            cmd.Parameters.Add(Db.Text(title));
            cmd.Parameters.Add(Db.Text(description));
            cmd.Parameters.Add(Db.Text(body));
            await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
            if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "article not found"); return; }
            if (r.GetInt64(0) != viewer) { await Http.Error(ctx, 403, "not the author"); return; }
            j = Single(r, 1);
        }
        await Http.Send(ctx, 200, j);
    }

    // DELETE /api/articles/{slug}
    public static async Task Delete(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        long? author = null;
        await using (var cmd = Db.Source.CreateCommand(DeleteArticle))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(slug));
            await using var r = await cmd.ExecuteReaderAsync();
            if (await r.ReadAsync()) author = r.GetInt64(0);
        }
        if (author is null) await Http.Error(ctx, 404, "article not found");
        else if (author != viewer) await Http.Error(ctx, 403, "not the author");
        else await Http.NoContent(ctx);
    }

    // POST and DELETE /api/articles/{slug}/favorite
    public static async Task Favorite(HttpContext ctx, string slug, bool favorite)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        JsonOut j;
        await using (var cmd = Db.Source.CreateCommand(favorite ? Sql.Favorite : Unfavorite))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(slug));
            await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
            if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "article not found"); return; }
            j = Single(r, 0);
        }
        await Http.Send(ctx, 200, j);
    }
}
