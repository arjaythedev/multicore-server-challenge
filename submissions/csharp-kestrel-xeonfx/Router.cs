using System;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

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
            await Http.Error(ctx, e.StatusCode, e.StatusCode == StatusCodes.Status413PayloadTooLarge ? "request body too large" : "bad request");
        }
        catch (Exception e) when (!ctx.Response.HasStarted && !ctx.RequestAborted.IsCancellationRequested)
        {
            Console.Error.WriteLine($"error: {ctx.Request.Method} {ctx.Request.Path}: {e}");
            ctx.Response.Clear();
            await Http.Error(ctx, 500, "internal error");
        }
    }

    static Task Dispatch(HttpContext ctx)
    {
        string path = ctx.Request.Path.Value ?? "";
        if (!path.StartsWith("/api/", StringComparison.Ordinal)) return Http.NotFound(ctx);
        ReadOnlySpan<char> rest = path.AsSpan(5);
        Span<Range> seg = stackalloc Range[5];
        int n = rest.Split(seg, '/');
        if (n == seg.Length) return Http.NotFound(ctx); // deeper than any route
        for (int i = 0; i < n; i++)
            if (rest[seg[i]].IsEmpty) return Http.NotFound(ctx);

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
                return Http.NotFound(ctx);
            }
            string slug = rest[seg[1]].ToString();
            if (n == 2)
            {
                if (get) return slug == "feed" ? Articles.Feed(ctx) : Articles.Get(ctx, slug);
                if (put) return Articles.Update(ctx, slug);
                if (delete) return Articles.Delete(ctx, slug);
                return Http.NotFound(ctx);
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
            return Http.NotFound(ctx);
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
        return Http.NotFound(ctx);
    }
}

public static class Auth
{
    /// <summary>The viewer's user id; 0 when no Authorization header was sent; -1 when one was sent but isn't a valid token.</summary>
    public static long Viewer(HttpContext ctx)
    {
        string? value = Header(ctx);
        if (string.IsNullOrEmpty(value)) return 0;
        if (!value.StartsWith(Scheme, StringComparison.Ordinal)) return -1;
        long id = Jwt.Verify(value.AsSpan(Scheme.Length));
        return id > 0 ? id : -1;
    }

    /// <summary>The token the request presented (call after Viewer accepted it).</summary>
    public static string Token(HttpContext ctx) => Header(ctx)![Scheme.Length..];

    const string Scheme = "Token ";

    static string? Header(HttpContext ctx)
    {
        StringValues h = ctx.Request.Headers.Authorization;
        return h.Count > 0 ? h[0] : null;
    }
}
