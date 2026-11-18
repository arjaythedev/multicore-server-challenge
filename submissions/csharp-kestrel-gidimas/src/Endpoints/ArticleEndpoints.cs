using System.Security.Claims;
using Conduit.Auth;
using Conduit.Data;
using Conduit.Json;
using Dapper;
using Npgsql;

namespace Conduit.Endpoints;

/// <summary>Articles, the feed and favorites.</summary>
public static class ArticleEndpoints
{
    public static void MapArticleEndpoints(this RouteGroupBuilder api)
    {
        api.MapGet("/articles", List).AddEndpointFilter<RejectInvalidTokenFilter>();
        api.MapGet("/articles/feed", Feed).RequireAuthorization();
        api.MapGet("/articles/{slug}", Get).AddEndpointFilter<RejectInvalidTokenFilter>();
        api.MapPost("/articles", Create).RequireAuthorization();
        api.MapPut("/articles/{slug}", Update).RequireAuthorization();
        api.MapDelete("/articles/{slug}", Delete).RequireAuthorization();
        api.MapPost("/articles/{slug}/favorite", (string slug, ClaimsPrincipal principal, NpgsqlDataSource db) =>
            SetFavorite(slug, principal.Id(), db, favorite: true)).RequireAuthorization();
        api.MapDelete("/articles/{slug}/favorite", (string slug, ClaimsPrincipal principal, NpgsqlDataSource db) =>
            SetFavorite(slug, principal.Id(), db, favorite: false)).RequireAuthorization();
    }

    /// <summary>Only the first filter given applies, in the order tag, author, favorited (SPEC.md).</summary>
    private static Task<IResult> List(
        string? tag, string? author, string? favorited, HttpRequest request, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        if (!Paging.TryRead(request, out var limit, out var offset))
        {
            return Task.FromResult(ApiErrors.Unprocessable("limit must be 1-100 and offset must be >= 0"));
        }

        var viewer = principal.Id();
        return !string.IsNullOrEmpty(tag) ? Page(db, Sql.ListByTag, new { viewer, limit, offset, tag })
            : !string.IsNullOrEmpty(author) ? Page(db, Sql.ListByAuthor, new { viewer, limit, offset, author })
            : !string.IsNullOrEmpty(favorited) ? Page(db, Sql.ListByFavorited, new { viewer, limit, offset, favorited })
            : Page(db, Sql.ListAll, new { viewer, limit, offset });
    }

    private static Task<IResult> Feed(HttpRequest request, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        if (!Paging.TryRead(request, out var limit, out var offset))
        {
            return Task.FromResult(ApiErrors.Unprocessable("limit must be 1-100 and offset must be >= 0"));
        }

        return Page(db, Sql.Feed, new { viewer = principal.Id(), limit, offset });
    }

    /// <summary>Runs a list statement pair (the page, then the capped count) in one round trip.</summary>
    private static async Task<IResult> Page(NpgsqlDataSource db, string sql, object parameters)
    {
        await using var conn = await db.OpenConnectionAsync();
        await using var results = await conn.QueryMultipleAsync(sql, parameters);
        var articles = (await results.ReadAsync<ArticleRow>()).Select(a => a.ToDto()).ToList();
        var count = await results.ReadSingleAsync<long>();
        return TypedResults.Ok(new ArticlesResponse(articles, count));
    }

    private static async Task<IResult> Get(string slug, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        await using var conn = await db.OpenConnectionAsync();
        var article = await conn.QuerySingleOrDefaultAsync<ArticleRow>(Sql.ArticleBySlug, new { viewer = principal.Id(), slug });
        return ArticleOrNotFound(article);
    }

    private static async Task<IResult> Create(NewArticleRequest request, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        var input = request.Article;
        if (input is null || string.IsNullOrEmpty(input.Title) || string.IsNullOrEmpty(input.Description) || string.IsNullOrEmpty(input.Body))
        {
            return ApiErrors.Unprocessable("title, description and body are required");
        }

        if (input.TagList is not null && input.TagList.Any(string.IsNullOrEmpty))
        {
            return ApiErrors.Unprocessable("tagList must contain non-empty strings");
        }

        var viewer = principal.Id();
        var tags = input.TagList?.OfType<string>().Distinct().ToArray() ?? [];

        await using var conn = await db.OpenConnectionAsync();
        long id;
        await using (var transaction = await conn.BeginTransactionAsync())
        {
            id = await conn.ExecuteScalarAsync<long>(Sql.InsertArticle, new { viewer, input.Title, input.Description, input.Body }, transaction);
            if (tags.Length > 0)
            {
                // ON CONFLICT DO NOTHING: a tag created concurrently by another request is simply reused.
                await conn.ExecuteAsync(Sql.InsertTags, new { tags }, transaction);
                await conn.ExecuteAsync(Sql.LinkTags, new { id, tags }, transaction);
            }

            await transaction.CommitAsync();
        }

        var article = await conn.QuerySingleAsync<ArticleRow>(Sql.ArticleById, new { viewer, id });
        return Results.Json(new ArticleResponse(article.ToDto()), statusCode: StatusCodes.Status201Created);
    }

    private static async Task<IResult> Update(string slug, UpdateArticleRequest request, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        var input = request.Article;
        if (input is null)
        {
            return ApiErrors.Unprocessable("article object required");
        }

        // Absent or null fields keep their value (COALESCE in the statement); an empty string is invalid.
        if (input.Title == "" || input.Description == "" || input.Body == "")
        {
            return ApiErrors.Unprocessable("title, description and body cannot be empty");
        }

        var viewer = principal.Id();
        await using var conn = await db.OpenConnectionAsync();
        var owner = await conn.QuerySingleOrDefaultAsync<ArticleOwnerRow>(Sql.ArticleOwner, new { slug });
        if (owner is null)
        {
            return ApiErrors.NotFound();
        }

        if (owner.AuthorId != viewer)
        {
            return ApiErrors.Forbidden();
        }

        await conn.ExecuteAsync(Sql.UpdateArticle, new { id = owner.Id, input.Title, input.Description, input.Body });
        return ArticleOrNotFound(await conn.QuerySingleOrDefaultAsync<ArticleRow>(Sql.ArticleById, new { viewer, id = owner.Id }));
    }

    private static async Task<IResult> Delete(string slug, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        await using var conn = await db.OpenConnectionAsync();
        var owner = await conn.QuerySingleOrDefaultAsync<ArticleOwnerRow>(Sql.ArticleOwner, new { slug });
        if (owner is null)
        {
            return ApiErrors.NotFound();
        }

        if (owner.AuthorId != principal.Id())
        {
            return ApiErrors.Forbidden();
        }

        await conn.ExecuteAsync(Sql.DeleteArticle, new { id = owner.Id });
        return TypedResults.NoContent();
    }

    private static async Task<IResult> SetFavorite(string slug, long viewer, NpgsqlDataSource db, bool favorite)
    {
        await using var conn = await db.OpenConnectionAsync();
        var id = await conn.QuerySingleOrDefaultAsync<long?>(Sql.ArticleIdBySlug, new { slug });
        if (id is null)
        {
            return ApiErrors.NotFound();
        }

        // INSERT ... ON CONFLICT DO NOTHING: favoriting twice is not an error.
        await conn.ExecuteAsync(favorite ? Sql.InsertFavorite : Sql.DeleteFavorite, new { viewer, id });
        return ArticleOrNotFound(await conn.QuerySingleOrDefaultAsync<ArticleRow>(Sql.ArticleById, new { viewer, id }));
    }

    /// <summary>The article may be deleted between the write and this read (by its author, concurrently).</summary>
    private static IResult ArticleOrNotFound(ArticleRow? article) =>
        article is null ? ApiErrors.NotFound() : TypedResults.Ok(new ArticleResponse(article.ToDto()));
}
