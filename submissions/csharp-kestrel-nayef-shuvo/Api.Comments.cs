namespace Conduit;

internal sealed partial class Api
{
    private sealed record CommentRow(long Id, string Body, DateTime CreatedAt, DateTime UpdatedAt,
        string Username, string? Bio, string? Image, bool Following);

    private static Task WriteComment(HttpContext ctx, int status, CommentRow c) =>
        Http.Json(ctx, status, w =>
        {
            w.WriteStartObject();
            w.WritePropertyName("comment");
            WriteCommentObject(w, c);
            w.WriteEndObject();
        });

    private static void WriteCommentObject(System.Text.Json.Utf8JsonWriter w, CommentRow c)
    {
        w.WriteStartObject();
        w.WriteNumber("id", c.Id);
        w.WriteString("createdAt", Ts(c.CreatedAt));
        w.WriteString("updatedAt", Ts(c.UpdatedAt));
        w.WriteString("body", c.Body);
        w.WriteStartObject("author");
        WriteProfileFields(w, c.Username, c.Bio, c.Image, c.Following);
        w.WriteEndObject();
        w.WriteEndObject();
    }

    // GET /api/articles/{slug}/comments
    private async Task ListComments(HttpContext ctx, long viewer, string slug)
    {
        var articleId = await ArticleId(ctx, slug);
        if (articleId == 0) return;

        var comments = new List<CommentRow>();
        await using (var cmd = db.CreateCommand(Sql.ListComments))
        {
            cmd.AddInt8(viewer);
            cmd.AddInt8(articleId);
            await using var r = await cmd.ExecuteReaderAsync();
            while (await r.ReadAsync())
                comments.Add(new CommentRow(r.GetInt64(0), r.GetString(1), r.GetDateTime(2), r.GetDateTime(3),
                    r.GetString(4), r.GetNullableString(5), r.GetNullableString(6), r.GetBoolean(7)));
        }
        await Http.Json(ctx, 200, w =>
        {
            w.WriteStartObject();
            w.WriteStartArray("comments");
            foreach (var c in comments) WriteCommentObject(w, c);
            w.WriteEndArray();
            w.WriteEndObject();
        });
    }

    // POST /api/articles/{slug}/comments
    private async Task CreateComment(HttpContext ctx, long viewer, string slug)
    {
        using var body = await Http.ReadWrapper(ctx, "comment");
        if (!body.IsValid)
        {
            await Http.Error(ctx, 422, "invalid body");
            return;
        }
        if (!Http.ReqString(body.Element, "body"u8, out var text))
        {
            await Http.Error(ctx, 422, "body is required");
            return;
        }
        var articleId = await ArticleId(ctx, slug);
        if (articleId == 0) return;

        CommentRow comment;
        await using (var cmd = db.CreateCommand(Sql.InsertComment))
        {
            cmd.AddInt8(articleId);
            cmd.AddInt8(viewer);
            cmd.AddText(text);
            await using var r = await cmd.ExecuteReaderAsync();
            await r.ReadAsync();
            // A new comment's author is the viewer, so "following" is false.
            comment = new CommentRow(r.GetInt64(0), r.GetString(1), r.GetDateTime(2), r.GetDateTime(3),
                r.GetString(4), r.GetNullableString(5), r.GetNullableString(6), false);
        }
        await WriteComment(ctx, 201, comment);
    }

    // DELETE /api/articles/{slug}/comments/{id}
    private async Task DeleteComment(HttpContext ctx, long viewer, string slug, string idText)
    {
        if (!Http.ParseUint(idText, out var id))
        {
            await Http.Error(ctx, 404, "comment not found");
            return;
        }
        long authorId;
        await using (var cmd = db.CreateCommand(@"SELECT c.author_id FROM comments c JOIN articles a ON a.id = c.article_id
 WHERE c.id = $1 AND a.slug = $2"))
        {
            cmd.AddInt8(id);
            cmd.AddText(slug);
            var result = await cmd.ExecuteScalarAsync();
            if (result is null)
            {
                await Http.Error(ctx, 404, "comment not found");
                return;
            }
            authorId = (long)result;
        }
        if (authorId != viewer)
        {
            await Http.Error(ctx, 403, "not the author");
            return;
        }
        await using (var cmd = db.CreateCommand("DELETE FROM comments WHERE id = $1"))
        {
            cmd.AddInt8(id);
            await cmd.ExecuteNonQueryAsync();
        }
        await Http.NoContent(ctx);
    }
}
