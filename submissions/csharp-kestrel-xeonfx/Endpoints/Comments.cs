using System;
using System.Text.Json;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Http;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit.Endpoints;

public static class Comments
{
    /// <summary>
    /// Writes a comment from columns id, created_at, updated_at, body, username, bio, image, following. A created
    /// comment's row has no body and following columns: its body is the one sent.
    /// </summary>
    static void Write(Utf8JsonWriter w, NpgsqlDataReader r, string? created)
    {
        w.WriteStartObject();
        w.WriteNumber(Names.Id, r.GetInt64(0));
        JsonFields.WriteTimestamp(w, Names.CreatedAt, r.GetFieldValue<DateTime>(1));
        JsonFields.WriteTimestamp(w, Names.UpdatedAt, r.GetFieldValue<DateTime>(2));
        if (created is null) Rows.WriteText(w, Names.Body, r, 3);
        else w.WriteString(Names.Body, created);
        w.WriteStartObject(Names.Author);
        Rows.WritePerson(w, r, created is null ? 4 : 3);
        w.WriteBoolean(Names.Following, created is null && r.GetBoolean(7));
        w.WriteEndObject();
        w.WriteEndObject();
    }

    // GET /api/articles/{slug}/comments
    public static async Task List(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer < 0) { await Responses.Unauthorized(ctx); return; }
        var j = await Db.Reader.Run(Db.Command(Sql.Comments, Db.P(viewer), Db.P(slug)), ReadList, ctx.RequestAborted);
        if (j is null) await Responses.Error(ctx, 404, "article not found");
        else await Responses.Send(ctx, 200, j);
    }

    /// <summary>{"comments": [...]}, or null when the article doesn't exist (no row).</summary>
    static readonly Func<NpgsqlDataReader, ValueTask<JsonOut?>> ReadList = static async r =>
    {
        if (!await r.ReadAsync()) return null;
        var j = JsonOut.Rent();
        var w = j.W;
        try
        {
            w.WriteStartObject();
            w.WriteStartArray(Names.Comments);
            if (!r.IsDBNull(0)) // a NULL id is the article's row without comments
                do Write(w, r, null);
                while (await r.ReadAsync());
            w.WriteEndArray();
            w.WriteEndObject();
            return j;
        }
        catch
        {
            j.Dispose(); // the response is the error, not this buffer
            throw;
        }
    };

    // POST /api/articles/{slug}/comments
    public static async Task Create(HttpContext ctx, string slug)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        using var doc = await Body.ReadAsync(ctx);
        if (!Body.TryWrapper(doc, "comment", out var c) || !Body.TryReqString(c, "body", out string body))
        {
            await Responses.Unprocessable(ctx, "body is required");
            return;
        }
        var j = await Db.Writer.Run(Db.Command(Sql.CreateComment, Db.P(viewer), Db.P(body), Db.P(slug)), Created, body, ctx.RequestAborted);
        if (j is null) await Responses.Error(ctx, 404, "article not found");
        else await Responses.Send(ctx, 201, j);
    }

    /// <summary>{"comment": ...} from the inserted row and the body that was sent, or null when the article doesn't exist.</summary>
    static readonly Func<NpgsqlDataReader?, object?, JsonOut?> Created = static (r, body) =>
    {
        if (r is null) return null;
        var j = JsonOut.Rent();
        j.W.WriteStartObject();
        j.W.WritePropertyName(Names.Comment);
        Write(j.W, r, (string)body!);
        j.W.WriteEndObject();
        return j;
    };

    // DELETE /api/articles/{slug}/comments/{id}
    public static async Task Delete(HttpContext ctx, string slug, string idText)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Responses.Unauthorized(ctx); return; }
        if (!Query.TryParseUint(idText, out long id)) { await Responses.Error(ctx, 404, "comment not found"); return; }
        long? author = await Db.Writer.Run(Db.Command(Sql.DeleteComment, Db.P(viewer), Db.P(id), Db.P(slug)), static r => r?.GetInt64(0), ctx.RequestAborted);
        if (author is null) await Responses.Error(ctx, 404, "comment not found");
        else if (author != viewer) await Responses.Error(ctx, 403, "not the author");
        else await Responses.NoContent(ctx);
    }
}
