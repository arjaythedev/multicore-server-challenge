using System.Security.Claims;
using Conduit.Auth;
using Conduit.Data;
using Conduit.Json;
using Dapper;
using Npgsql;

namespace Conduit.Endpoints;

/// <summary>Profiles and follows.</summary>
public static class ProfileEndpoints
{
    public static void MapProfileEndpoints(this RouteGroupBuilder api)
    {
        api.MapGet("/profiles/{username}", Get).AddEndpointFilter<RejectInvalidTokenFilter>();
        api.MapPost("/profiles/{username}/follow", (string username, ClaimsPrincipal principal, NpgsqlDataSource db) =>
            SetFollowing(username, principal.Id(), db, following: true)).RequireAuthorization();
        api.MapDelete("/profiles/{username}/follow", (string username, ClaimsPrincipal principal, NpgsqlDataSource db) =>
            SetFollowing(username, principal.Id(), db, following: false)).RequireAuthorization();
    }

    private static async Task<IResult> Get(string username, ClaimsPrincipal principal, NpgsqlDataSource db)
    {
        await using var conn = await db.OpenConnectionAsync();
        var profile = await conn.QuerySingleOrDefaultAsync<ProfileRow>(Sql.Profile, new { viewer = principal.Id(), username });
        return profile is null ? ApiErrors.NotFound() : TypedResults.Ok(new ProfileResponse(profile.ToDto()));
    }

    private static async Task<IResult> SetFollowing(string username, long viewer, NpgsqlDataSource db, bool following)
    {
        await using var conn = await db.OpenConnectionAsync();
        var target = await conn.QuerySingleOrDefaultAsync<ProfileRow>(Sql.ProfileBase, new { username });
        if (target is null)
        {
            return ApiErrors.NotFound();
        }

        // INSERT ... ON CONFLICT DO NOTHING: following twice is not an error.
        await conn.ExecuteAsync(following ? Sql.InsertFollow : Sql.DeleteFollow, new { viewer, id = target.Id });
        return TypedResults.Ok(new ProfileResponse(target.ToDto() with { Following = following }));
    }
}
