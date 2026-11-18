using Conduit.Data;
using Conduit.Json;
using Dapper;
using Npgsql;

namespace Conduit.Endpoints;

public static class TagEndpoints
{
    public static void MapTagEndpoints(this RouteGroupBuilder api) => api.MapGet("/tags", List);

    private static async Task<IResult> List(NpgsqlDataSource db)
    {
        await using var conn = await db.OpenConnectionAsync();
        var tags = await conn.QueryAsync<string>(Sql.Tags);
        return TypedResults.Ok(new TagsResponse(tags.AsList()));
    }
}
