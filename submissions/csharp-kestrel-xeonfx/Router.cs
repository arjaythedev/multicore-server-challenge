using System;
using System.Threading.Tasks;
using CodeFusion.Security;
using Conduit.Endpoints;
using Conduit.Http;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit;

public static class Router
{
    public static async Task Handle(HttpContext ctx)
    {
        try
        {
            await Dispatch(ctx);
        }
        catch (BadHttpRequestException e) when (!ctx.Response.HasStarted)
        {
            // Kestrel rejected the request body: over MaxRequestBodySize (413) or malformed framing (400).
            ctx.Response.Clear();
            await Responses.Error(ctx, e.StatusCode, e.StatusCode == StatusCodes.Status413PayloadTooLarge ? "request body too large" : "bad request");
        }
        catch (ServerBusyException e) when (!ctx.Response.HasStarted)
        {
            // A full queue refused it (counted in the stats line), not a fault: no log line per refusal.
            await Busy(ctx, e.Message);
        }
        catch (BcryptQueueFullException) when (!ctx.Response.HasStarted)
        {
            // The bcrypt queue's own refusal, counted in the stats line as the others are.
            await Busy(ctx, "too many logins are waiting");
        }
        catch (PostgresException e) when (!ctx.Response.HasStarted && !ctx.RequestAborted.IsCancellationRequested
                                          && e.SqlState is PostgresErrorCodes.LockNotAvailable or PostgresErrorCodes.QueryCanceled)
        {
            // A lock or statement timeout: the database was blocked, the request itself may well succeed again.
            Console.Error.WriteLine($"busy: {ctx.Request.Method} {ctx.Request.Path}: {e.SqlState} {e.MessageText}");
            await Busy(ctx, "the database is busy");
        }
        catch (Exception e) when (!ctx.Response.HasStarted && !ctx.RequestAborted.IsCancellationRequested)
        {
            Console.Error.WriteLine($"error: {ctx.Request.Method} {ctx.Request.Path}: {e}");
            ctx.Response.Clear();
            await Responses.Error(ctx, 500, "internal error");
        }
    }

    static Task Busy(HttpContext ctx, string message)
    {
        ctx.Response.Clear();
        ctx.Response.Headers.RetryAfter = "1";
        return Responses.Error(ctx, StatusCodes.Status503ServiceUnavailable, message);
    }

    static Task Dispatch(HttpContext ctx)
    {
        string path = ctx.Request.Path.Value ?? "";
        if (!path.StartsWith("/api/", StringComparison.Ordinal)) return Responses.NotFound(ctx);
        ReadOnlySpan<char> rest = path.AsSpan(5);
        Span<Range> seg = stackalloc Range[5];
        int n = rest.Split(seg, '/');
        if (n == seg.Length) return Responses.NotFound(ctx); // deeper than any route
        for (int i = 0; i < n; i++)
            if (rest[seg[i]].IsEmpty) return Responses.NotFound(ctx);

        string method = ctx.Request.Method;
        bool get = HttpMethods.IsGet(method), post = HttpMethods.IsPost(method),
             put = HttpMethods.IsPut(method), delete = HttpMethods.IsDelete(method);
        ReadOnlySpan<char> s0 = rest[seg[0]];

        if (s0.SequenceEqual("articles"))
        {
            if (n == 1)
            {
                if (get) return Articles.List(ctx);
                if (post) return Articles.Create(ctx);
                return Responses.NotFound(ctx);
            }
            string slug = rest[seg[1]].ToString();
            if (n == 2)
            {
                if (get) return slug == "feed" ? Articles.Feed(ctx) : Articles.Get(ctx, slug);
                if (put) return Articles.Update(ctx, slug);
                if (delete) return Articles.Delete(ctx, slug);
                return Responses.NotFound(ctx);
            }
            ReadOnlySpan<char> s2 = rest[seg[2]];
            if (n == 3 && s2.SequenceEqual("comments"))
            {
                if (get) return Comments.List(ctx, slug);
                if (post) return Comments.Create(ctx, slug);
            }
            else if (n == 3 && s2.SequenceEqual("favorite"))
            {
                if (post) return Articles.Favorite(ctx, slug, true);
                if (delete) return Articles.Favorite(ctx, slug, false);
            }
            else if (n == 4 && s2.SequenceEqual("comments") && delete)
                return Comments.Delete(ctx, slug, rest[seg[3]].ToString());
            return Responses.NotFound(ctx);
        }
        if (s0.SequenceEqual("tags") && n == 1 && get) return Tags.List(ctx);
        if (s0.SequenceEqual("user") && n == 1)
        {
            if (get) return Users.Current(ctx);
            if (put) return Users.Update(ctx);
        }
        if (s0.SequenceEqual("profiles"))
        {
            if (n == 2 && get) return Profiles.Get(ctx, rest[seg[1]].ToString());
            if (n == 3 && rest[seg[2]].SequenceEqual("follow"))
            {
                if (post) return Profiles.Follow(ctx, rest[seg[1]].ToString(), true);
                if (delete) return Profiles.Follow(ctx, rest[seg[1]].ToString(), false);
            }
        }
        if (s0.SequenceEqual("users") && post)
        {
            if (n == 1) return Users.Register(ctx);
            if (n == 2 && rest[seg[1]].SequenceEqual("login")) return Users.Login(ctx);
        }
        return Responses.NotFound(ctx);
    }
}
