using System;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Http;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit.Endpoints;

public static class Tags
{
    // GET /api/tags
    public static async Task List(HttpContext ctx) =>
        await Responses.Send(ctx, 200, await Db.Reader.Run(Db.Command(Sql.Tags), Read, ctx.RequestAborted));

    static readonly Func<NpgsqlDataReader, ValueTask<JsonOut>> Read = static async r =>
    {
        await r.ReadAsync();
        var j = JsonOut.Rent();
        try
        {
            var w = j.W;
            w.WriteStartObject();
            w.WritePropertyName(Names.Tags);
            if (r.IsDBNull(0)) { w.WriteStartArray(); w.WriteEndArray(); }
            else Rows.WriteRaw(w, r, 0);
            w.WriteEndObject();
            return j;
        }
        catch
        {
            j.Dispose(); // the response is the error, not this buffer
            throw;
        }
    };
}
