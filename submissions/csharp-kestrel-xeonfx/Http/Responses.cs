using System.Buffers;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Conduit.Http;

/// <summary>Whole responses: a buffered JSON body with its Content-Length, or an error in the spec's shape.</summary>
public static class Responses
{
    const string ContentType = "application/json";

    /// <summary>Writes the buffered JSON as the whole response and returns the buffer to the pool. Kestrel sends it
    /// when the handler returns.</summary>
    public static Task Send(HttpContext ctx, int status, JsonOut j)
    {
        var res = ctx.Response;
        res.StatusCode = status;
        res.ContentType = ContentType;
        var body = j.Written;
        res.ContentLength = body.Length;
        res.BodyWriter.Write(body);
        j.Dispose();
        return Task.CompletedTask;
    }

    public static Task NoContent(HttpContext ctx)
    {
        ctx.Response.StatusCode = StatusCodes.Status204NoContent;
        return Task.CompletedTask;
    }

    public static Task Error(HttpContext ctx, int status, string message)
    {
        var j = JsonOut.Rent();
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartObject(Names.Errors);
        w.WriteStartArray(Names.Body);
        w.WriteStringValue(message);
        w.WriteEndArray();
        w.WriteEndObject();
        w.WriteEndObject();
        return Send(ctx, status, j);
    }

    public static Task NotFound(HttpContext ctx) => Error(ctx, 404, "not found");
    public static Task Unauthorized(HttpContext ctx) => Error(ctx, 401, "unauthorized");
    public static Task Unprocessable(HttpContext ctx, string message) => Error(ctx, 422, message);
}
