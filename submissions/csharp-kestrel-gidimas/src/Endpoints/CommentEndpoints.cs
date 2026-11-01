using System.Globalization;
using System.Security.Claims;
using Conduit.Auth;
using Conduit.Data;
using Conduit.Json;
using Dapper;
using Npgsql;

namespace Conduit.Endpoints;

/// <summary>Comments on articles.</summary>
public static class CommentEndpoints
{
    public static void MapCommentEndpoints(this RouteGroupBuilder api)
    {
        api.MapGet("/articles/{slug}/comments", List).AddEndpointFilter<RejectInvalidTokenFilter>();
        api.MapPost("/articles/{slug}/comments", Create).RequireAuthorization();
        api.MapDelete("/articles/{slug}/comments/{id}", Delete).RequireAuthorization();
    }

    private static async Task<IResult> List(string slug, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        await using var conn = await db.OpenConnectionAsync();
        await using var results = await conn.QueryMultipleAsync(Sql.Comments, new { viewer = principal.Id(), slug });
        if (await results.ReadSingleOrDefaultAsync<long?>() is null)
        {
            return ApiErrors.NotFound();
        }

        var comments = await results.ReadAsync<CommentRow>();
        return TypedResults.Ok(new CommentsResponse(comments.Select(c => c.ToDto()).ToList()));
    }

    private static async Task<IResult> Create(string slug, NewCommentRequest request, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        if (string.IsNullOrEmpty(request.Comment?.Body))
        {
            return ApiErrors.Unprocessable("body is required");
        }

        await using var conn = await db.OpenConnectionAsync();
        var articleId = await conn.QuerySingleOrDefaultAsync<long?>(Sql.ArticleIdBySlug, new { slug });
        if (articleId is null)
        {
            return ApiErrors.NotFound();
        }

        // SPEC.md: a new comment's author.following is false (CommentRow.Following stays false).
        var comment = await conn.QuerySingleAsync<CommentRow>(Sql.InsertComment, new { id = articleId, viewer = principal.Id(), request.Comment.Body });
        return Results.Json(new CommentResponse(comment.ToDto()), statusCode: StatusCodes.Status201Created);
    }

    private static async Task<IResult> Delete(string slug, string id, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        // A non-integer id can't match any comment.
        if (!long.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out var commentId))
        {
            return ApiErrors.NotFound();
        }

        await using var conn = await db.OpenConnectionAsync();
        var authorId = await conn.QuerySingleOrDefaultAsync<long?>(Sql.CommentAuthor, new { id = commentId, slug });
        if (authorId is null)
        {
            return ApiErrors.NotFound();
        }

        if (authorId != principal.Id())
        {
            return ApiErrors.Forbidden();
        }

        await conn.ExecuteAsync(Sql.DeleteComment, new { id = commentId });
        return TypedResults.NoContent();
    }
}
