using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using Npgsql;

namespace Conduit;

/// <summary>
/// The Conduit API: a hand-written router over Kestrel's request delegate, no routing framework.
/// Split over several files, all of one class: Api.cs (router + auth), Api.Users.cs, Api.Articles.cs, Api.Comments.cs.
/// Every request takes the same path:
///   Handle (catches errors -> 500)
///   -> Route (splits the path, picks a handler by segment count, first segment and HTTP method)
///   -> Required / Optional (checks the token, then calls the handler with the viewer's user id)
///   -> the handler (validates the body, runs SQL, builds a response)
///   -> Http.Json / Http.Error / Http.NoContent (writes status and body).
/// </summary>
internal sealed partial class Api(NpgsqlDataSource db, Auth auth, ILogger<Api> log)
{
    internal async Task Handle(HttpContext ctx)
    {
#if DEBUG
        var started = Stopwatch.GetTimestamp();
#endif
        try
        {
            await Route(ctx);
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            log.LogError(e, "unhandled error on {Method} {Path}", ctx.Request.Method, ctx.Request.Path);
            if (!ctx.Response.HasStarted) await Http.Error(ctx, 500, "internal error");
        }
#if DEBUG
        finally
        {
            LogRequest(ctx, started);
        }
#endif
    }

#if DEBUG
    /// <summary>One line per request: method, path and query, status, time, and the error message if there was one.</summary>
    private void LogRequest(HttpContext ctx, long started)
    {
        var status = ctx.Response.StatusCode;
        var level = status >= 500 ? LogLevel.Error : status >= 400 ? LogLevel.Warning : LogLevel.Information;
        var error = ctx.Items.TryGetValue(Http.ErrorItem, out var message) ? $": {message}" : "";
        log.Log(level, "{Method} {Target} -> {Status} in {Elapsed:0.0} ms{Error}",
            ctx.Request.Method, ctx.Request.Path + ctx.Request.QueryString, status,
            Stopwatch.GetElapsedTime(started).TotalMilliseconds, error);
    }
#endif

    private Task Route(HttpContext ctx)
    {
        var req = ctx.Request;
        var m = req.Method;
#if DEBUG
        // Local testing only: Swagger UI and its OpenAPI description (OpenApi.cs). Not compiled into Release builds.
        if (m == "GET" && req.Path.Value is "/swagger" or "/swagger/openapi.json") return OpenApi.Serve(ctx);
#endif
        // "/api/articles/x/comments" -> ["", "api", "articles", "x", "comments"]; every segment must be non-empty.
        var s = (req.Path.Value ?? "").Split('/');
        if (s.Length < 3 || s[0].Length != 0 || s[1] != "api") return NotFound(ctx);
        for (var i = 2; i < s.Length; i++)
            if (s[i].Length == 0) return NotFound(ctx);

        switch (s.Length)
        {
            case 3:
                switch (s[2])
                {
                    case "users" when m == "POST": return Register(ctx);
                    case "user" when m == "GET": return Required(ctx, CurrentUser);
                    case "user" when m == "PUT": return Required(ctx, UpdateUser);
                    case "articles" when m == "GET": return Optional(ctx, ListArticles);
                    case "articles" when m == "POST": return Required(ctx, CreateArticle);
                    case "tags" when m == "GET": return Tags(ctx);
                }
                break;
            case 4:
                switch (s[2])
                {
                    case "users" when s[3] == "login" && m == "POST": return Login(ctx);
                    case "profiles" when m == "GET": return Optional(ctx, (c, v, _) => GetProfile(c, v, s[3]));
                    case "articles" when s[3] == "feed" && m == "GET": return Required(ctx, Feed);
                    case "articles" when m == "GET": return Optional(ctx, (c, v, _) => GetArticle(c, v, s[3]));
                    case "articles" when m == "PUT": return Required(ctx, (c, v, _) => UpdateArticle(c, v, s[3]));
                    case "articles" when m == "DELETE": return Required(ctx, (c, v, _) => DeleteArticle(c, v, s[3]));
                }
                break;
            case 5:
                switch (s[2], s[4])
                {
                    case ("profiles", "follow") when m == "POST": return Required(ctx, (c, v, _) => Follow(c, v, s[3], true));
                    case ("profiles", "follow") when m == "DELETE": return Required(ctx, (c, v, _) => Follow(c, v, s[3], false));
                    case ("articles", "favorite") when m == "POST": return Required(ctx, (c, v, _) => Favorite(c, v, s[3], true));
                    case ("articles", "favorite") when m == "DELETE": return Required(ctx, (c, v, _) => Favorite(c, v, s[3], false));
                    case ("articles", "comments") when m == "GET": return Optional(ctx, (c, v, _) => ListComments(c, v, s[3]));
                    case ("articles", "comments") when m == "POST": return Required(ctx, (c, v, _) => CreateComment(c, v, s[3]));
                }
                break;
            case 6:
                if (s[2] == "articles" && s[4] == "comments" && m == "DELETE")
                    return Required(ctx, (c, v, _) => DeleteComment(c, v, s[3], s[5]));
                break;
        }
        return NotFound(ctx);
    }

    private static Task NotFound(HttpContext ctx) => Http.Error(ctx, 404, "not found");

    // ---------- auth wrappers ----------

    private delegate Task Authed(HttpContext ctx, long viewer, string token);

    /// <summary>A missing or invalid token gives 401.</summary>
    private async Task Required(HttpContext ctx, Authed next)
    {
        var (id, token, _) = await auth.Authenticate(ctx.Request);
        if (id == 0)
        {
            await Http.Error(ctx, 401, "unauthorized");
            return;
        }
        await next(ctx, id, token);
    }

    /// <summary>No header means viewer 0; a header that is present but invalid gives 401.</summary>
    private async Task Optional(HttpContext ctx, Authed next)
    {
        var (id, token, present) = await auth.Authenticate(ctx.Request);
        if (present && id == 0)
        {
            await Http.Error(ctx, 401, "unauthorized");
            return;
        }
        await next(ctx, id, token);
    }

    // ---------- JSON output shared by several endpoints ----------

    /// <summary>RFC 3339 UTC with exactly 3 fractional digits (truncated).</summary>
    private static string Ts(DateTime t) => t.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    private static void NullableString(Utf8JsonWriter w, string name, string? v)
    {
        if (v is null) w.WriteNull(name);
        else w.WriteString(name, v);
    }

    private static void WriteProfileFields(Utf8JsonWriter w, string username, string? bio, string? image, bool following)
    {
        w.WriteString("username", username);
        NullableString(w, "bio", bio);
        NullableString(w, "image", image);
        w.WriteBoolean("following", following);
    }

    private static Task WriteProfile(HttpContext ctx, string username, string? bio, string? image, bool following) =>
        Http.Json(ctx, 200, w =>
        {
            w.WriteStartObject();
            w.WriteStartObject("profile");
            WriteProfileFields(w, username, bio, image, following);
            w.WriteEndObject();
            w.WriteEndObject();
        });
}
