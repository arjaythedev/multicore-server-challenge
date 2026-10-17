using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit;

public static class Profiles
{
    static JsonOut Profile(NpgsqlDataReader r, bool following)
    {
        var j = JsonOut.Rent();
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartObject(Names.Profile);
        Http.WritePerson(w, r, 0);
        w.WriteBoolean(Names.Following, following);
        w.WriteEndObject();
        w.WriteEndObject();
        return j;
    }

    // GET /api/profiles/{username}
    public static async Task Get(HttpContext ctx, string username)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer < 0) { await Http.Unauthorized(ctx); return; }
        JsonOut j;
        await using (var cmd = Db.Source.CreateCommand(Sql.Profile))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(username));
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "profile not found"); return; }
            j = Profile(r, r.GetBoolean(3));
        }
        await Http.Send(ctx, 200, j);
    }

    // POST and DELETE /api/profiles/{username}/follow
    public static async Task Follow(HttpContext ctx, string username, bool follow)
    {
        long viewer = Auth.Viewer(ctx);
        if (viewer <= 0) { await Http.Unauthorized(ctx); return; }
        JsonOut j;
        await using (var cmd = Db.Source.CreateCommand(follow ? Sql.Follow : Sql.Unfollow))
        {
            cmd.Parameters.Add(Db.P(viewer));
            cmd.Parameters.Add(Db.P(username));
            await using var r = await cmd.ExecuteReaderAsync();
            if (!await r.ReadAsync()) { await Http.Error(ctx, 404, "profile not found"); return; }
            j = Profile(r, follow);
        }
        await Http.Send(ctx, 200, j);
    }
}
