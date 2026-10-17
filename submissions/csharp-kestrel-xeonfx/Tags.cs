using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Conduit;

public static class Tags
{
    // GET /api/tags
    public static async Task List(HttpContext ctx)
    {
        var j = JsonOut.Rent();
        var w = j.W;
        await using (var cmd = Db.Source.CreateCommand(Sql.Tags))
        {
            await using var r = await cmd.ExecuteReaderAsync();
            w.WriteStartObject();
            w.WriteStartArray(Names.Tags);
            while (await r.ReadAsync()) w.WriteStringValue(r.GetString(0));
            w.WriteEndArray();
            w.WriteEndObject();
        }
        await Http.Send(ctx, 200, j);
    }
}
