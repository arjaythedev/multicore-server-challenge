using System;
using System.Data;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit;

public static class Comments
{
    /// <summary>
    /// Writes a comment from columns id, created_at, updated_at, body, username, bio, image, following, read in order
    /// (sequential access). A created comment's row has no body and following columns: its body is the one sent.
    /// </summary>
    static void Write(Utf8JsonWriter w, NpgsqlDataReader r, string? created)
    {
        w.WriteStartObject();
        w.WriteNumber(Names.Id, r.GetInt64(0));
        Http.WriteTimestamp(w, Names.CreatedAt, r.GetFieldValue<DateTime>(1));
        Http.WriteTimestamp(w, Names.UpdatedAt, r.GetFieldValue<DateTime>(2));
        w.WriteString(Names.Body, created ?? r.GetString(3));
        w.WriteStartObject(Names.Author);
        Http.WritePerson(w, r, created is null ? 4 : 3);
        w.WriteBoolean(Names.Following, created is null && r.GetBoolean(7));
        w.WriteEndObject();
        w.WriteEndObject();
    }

    // GET /api/articles/{slug}/comments
    public static async Task List(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer < 0) { await Http.Unauthorized(ctx); return; }
        await using var cmd = Db.Source.CreateCommand(Sql.Comments);
        cmd.Parameters.Add(Db.P(viewer));
        cmd.Parameters.Add(Db.P(slug));
        await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
        if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "article not found"); return; }
        var j = JsonOut.Rent();
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartArray(Names.Comments);
        if (!r.IsDBNull(0)) // a NULL id is the article's row without comments
            do Write(w, r, null);
            while (await r.ReadAsync());
        w.WriteEndArray();
        w.WriteEndObject();
        await Http.Send(ctx, 200, j);
    }

    // POST /api/articles/{slug}/comments
    public static async Task Create(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "comment", out var c) || !Body.TryReqString(c, "body", out string body))
        {
            await Http.Unprocessable(ctx, "body is required");
            return;
        }
        JsonOut j;
        await using (var cmd = Db.Source.CreateCommand(Sql.CreateComment))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(body));
            cmd.Parameters.Add(Db.P(slug));
            await using var r = await cmd.ExecuteReaderAsync(CommandBehavior.SequentialAccess);
            if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "article not found"); return; }
            j = JsonOut.Rent();
            j.W.WriteStartObject();
            j.W.WritePropertyName(Names.Comment);
            Write(j.W, r, body);
            j.W.WriteEndObject();
        }
        await Http.Send(ctx, 201, j);
    }

    // DELETE /api/articles/{slug}/comments/{id}
    public static async Task Delete(HttpContext ctx, string slug, string idText)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        if (!Query.TryParseUint(idText, out long id)) { await Http.Error(ctx, 404, "comment not found"); return; }
        long? author = null;
        await using (var cmd = Db.Source.CreateCommand(Sql.DeleteComment))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(id));
            cmd.Parameters.Add(Db.P(slug));
            await using var r = await cmd.ExecuteReaderAsync();
            if (await r.ReadAsync()) author = r.GetInt64(0);
        }
        if (author is null) await Http.Error(ctx, 404, "comment not found");
        else if (author != viewer) await Http.Error(ctx, 403, "not the author");
        else await Http.NoContent(ctx);
    }
}
