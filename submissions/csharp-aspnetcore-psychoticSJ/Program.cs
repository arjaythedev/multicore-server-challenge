using System.Globalization;
using System.IO.Pipelines;
using System.Net;
using System.Text.Json;
using ConduitChallenge;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Npgsql;

var builder = WebApplication.CreateSlimBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.SetMinimumLevel(LogLevel.Warning);
var host = Environment.GetEnvironmentVariable("HOST") ?? "127.0.0.1";
var port = Settings.Number("PORT", 3000, 1, 65535);
builder.WebHost.ConfigureKestrel(options =>
{
    options.AddServerHeader = false;
    options.Limits.KeepAliveTimeout = TimeSpan.FromMinutes(2);
    options.Listen(host == "localhost" ? IPAddress.Loopback : IPAddress.Parse(host), port,
        endpoint => endpoint.Protocols = HttpProtocols.Http1);
});
Auth.Configure(Environment.GetEnvironmentVariable("JWT_SECRET") ?? "multicore-server-challenge");
var databaseUrl = Environment.GetEnvironmentVariable("DATABASE_URL")
    ?? builder.Configuration.GetConnectionString("Conduit")
    ?? "postgres://conduit:conduit@127.0.0.1:55432/conduit_dev";
await using var db = new Db(databaseUrl);
await db.StartAsync(CancellationToken.None);
await using var reads = new Reads(db);
using var passwords = new Passwords();
var writes = new Writes(db, passwords);
var app = builder.Build();
app.Run(context => Api.HandleAsync(context, reads, writes));
await app.RunAsync();

internal static class Settings
{
    public static int Number(string name, int fallback, int min, int max)
    {
        var text = Environment.GetEnvironmentVariable(name);
        if (text is null) return fallback;
        if (int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var number) && number >= min && number <= max)
            return number;
        throw new InvalidOperationException($"{name} must be between {min} and {max}");
    }
}

internal static class Api
{
    static readonly string[] FilterNames = ["tag", "author", "favorited"];

    public static async Task HandleAsync(HttpContext context, Reads reads, Writes writes)
    {
        ApiResult? result = null;
        try
        {
            result = await DispatchAsync(context, reads, writes);
            await SendAsync(context, result);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested) { }
        catch (ApiFailure failure)
        {
            using var error = Json.Error(failure.Status, failure.Message);
            await SendAsync(context, error);
        }
        catch (JsonException)
        {
            using var error = Json.Error(422, "Malformed JSON");
            await SendAsync(context, error);
        }
        catch (PostgresException failure) when (failure.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            using var error = Json.Error(422, "Value already exists");
            await SendAsync(context, error);
        }
        catch (Exception failure)
        {
            context.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("Conduit").LogError(failure, "Request failed");
            if (context.Response.HasStarted) context.Abort();
            else
            {
                using var error = Json.Error(500, "Request failed");
                await SendAsync(context, error);
            }
        }
        finally { result?.Dispose(); }
    }

    static ValueTask<FlushResult> SendAsync(HttpContext context, ApiResult result)
    {
        context.Response.StatusCode = result.StatusCode;
        if (result.Body is not { } body) return default;
        context.Response.ContentType = "application/json";
        context.Response.ContentLength = body.WrittenMemory.Length;
        return context.Response.BodyWriter.WriteAsync(body.WrittenMemory, context.RequestAborted);
    }

    static async ValueTask<ApiResult> DispatchAsync(HttpContext context, Reads reads, Writes writes)
    {
        var route = Match(context.Request.Method, context.Request.Path.Value ?? "");
        var ct = context.RequestAborted;
        if (route.Kind == Kind.Unknown) return Json.Error(404, "Unknown endpoint");
        if (route.Kind == Kind.Tags) return await reads.TagsAsync(ct);
        long viewer = 0;
        string? token = null;
        if (route.Kind is not (Kind.Register or Kind.Login))
        {
            var required = route.Kind is not (Kind.List or Kind.Article or Kind.Profile or Kind.Comments);
            if (!Auth.TryRead(context, required, out viewer, out token, route.Kind is Kind.User or Kind.UpdateUser))
                return Json.Error(401, "Invalid or missing token");
        }
        switch (route.Kind)
        {
            case Kind.User: return await writes.UserAsync(viewer, token!, ct);
            case Kind.Profile: return await reads.ProfileAsync(viewer, route.Key!, ct);
            case Kind.Article: return await reads.ArticleAsync(viewer, route.Key!, ct);
            case Kind.Comments: return await reads.CommentsAsync(viewer, route.Key!, ct);
            case Kind.Follow: return await writes.FollowAsync(viewer, route.Key!, true, ct);
            case Kind.Unfollow: return await writes.FollowAsync(viewer, route.Key!, false, ct);
            case Kind.Favorite: return await writes.FavoriteAsync(viewer, route.Key!, true, ct);
            case Kind.Unfavorite: return await writes.FavoriteAsync(viewer, route.Key!, false, ct);
            case Kind.DeleteArticle: return await writes.DeleteArticleAsync(viewer, route.Key!, ct);
            case Kind.DeleteComment:
                if (!long.TryParse(route.Id, NumberStyles.None, CultureInfo.InvariantCulture, out var id) || id <= 0)
                    return Json.Error(404, "Unknown comment");
                return await writes.DeleteCommentAsync(viewer, route.Key!, id, ct);
            case Kind.List:
            case Kind.Feed:
                var query = context.Request.Query;
                var limit = PageNumber(query, "limit", 20, 1, 100);
                var offset = PageNumber(query, "offset", 0, 0, int.MaxValue);
                var filter = route.Kind == Kind.Feed ? "feed" : "global";
                string? key = null;
                if (filter == "global")
                    foreach (var name in FilterNames)
                    {
                        var value = query[name].ToString();
                        if (value.Length == 0) continue;
                        filter = name;
                        key = value;
                        break;
                    }
                return await reads.ListAsync(viewer, filter, key, limit, offset, ct);
        }
        using var document = await JsonDocument.ParseAsync(context.Request.Body, cancellationToken: ct);
        var wrapper = route.Kind is Kind.Register or Kind.Login or Kind.UpdateUser ? "user"
            : route.Kind == Kind.CreateComment ? "comment" : "article";
        if (document.RootElement.ValueKind != JsonValueKind.Object ||
            !document.RootElement.TryGetProperty(wrapper, out var input) || input.ValueKind != JsonValueKind.Object)
            return Json.Error(422, $"{wrapper} must be an object");
        return route.Kind switch
        {
            Kind.Register => await writes.RegisterAsync(input, ct),
            Kind.Login => await writes.LoginAsync(input, ct),
            Kind.UpdateUser => await writes.UpdateUserAsync(viewer, token!, input, ct),
            Kind.CreateArticle => await writes.CreateArticleAsync(viewer, input, ct),
            Kind.UpdateArticle => await writes.UpdateArticleAsync(viewer, route.Key!, input, ct),
            Kind.CreateComment => await writes.CreateCommentAsync(viewer, route.Key!, input, ct),
            _ => Json.Error(404, "Unknown endpoint")
        };
    }

    static int PageNumber(IQueryCollection query, string name, int fallback, int min, int max)
    {
        if (!query.TryGetValue(name, out var values)) return fallback;
        if (values.Count != 1 || !int.TryParse(values[0], NumberStyles.None, CultureInfo.InvariantCulture, out var value) || value < min || value > max)
            throw new ApiFailure(422, $"Invalid {name}");
        return value;
    }

    static Route Match(string method, string path)
    {
        var kind = (method, path) switch
        {
            ("GET", "/api/tags") => Kind.Tags,
            ("POST", "/api/users") => Kind.Register,
            ("POST", "/api/users/login") => Kind.Login,
            ("GET", "/api/user") => Kind.User,
            ("PUT", "/api/user") => Kind.UpdateUser,
            ("GET", "/api/articles") => Kind.List,
            ("POST", "/api/articles") => Kind.CreateArticle,
            ("GET", "/api/articles/feed") => Kind.Feed,
            _ => Kind.Unknown
        };
        if (kind != Kind.Unknown) return new(kind);
        if (path.StartsWith("/api/profiles/", StringComparison.Ordinal))
        {
            var tail = path.AsSpan(14);
            var slash = tail.IndexOf('/');
            if (slash < 0 && tail.Length > 0 && method == "GET") return new(Kind.Profile, tail.ToString());
            if (slash > 0 && tail[slash..].SequenceEqual("/follow"))
                return new(method == "POST" ? Kind.Follow : method == "DELETE" ? Kind.Unfollow : Kind.Unknown, tail[..slash].ToString());
        }
        if (path.StartsWith("/api/articles/", StringComparison.Ordinal))
        {
            var tail = path.AsSpan(14);
            var slash = tail.IndexOf('/');
            if (slash < 0 && tail.Length > 0)
                return new(method == "GET" ? Kind.Article : method == "PUT" ? Kind.UpdateArticle : method == "DELETE" ? Kind.DeleteArticle : Kind.Unknown, tail.ToString());
            if (slash > 0)
            {
                var slug = tail[..slash].ToString();
                var suffix = tail[slash..];
                if (suffix.SequenceEqual("/favorite"))
                    return new(method == "POST" ? Kind.Favorite : method == "DELETE" ? Kind.Unfavorite : Kind.Unknown, slug);
                if (suffix.SequenceEqual("/comments"))
                    return new(method == "GET" ? Kind.Comments : method == "POST" ? Kind.CreateComment : Kind.Unknown, slug);
                if (method == "DELETE" && suffix.StartsWith("/comments/") && suffix.Length > 10 && !suffix[10..].Contains('/'))
                    return new(Kind.DeleteComment, slug, suffix[10..].ToString());
            }
        }
        return new(Kind.Unknown);
    }
    readonly record struct Route(Kind Kind, string? Key = null, string? Id = null);
    enum Kind { Unknown, Tags, Register, Login, User, UpdateUser, Profile, Follow, Unfollow, List, Feed,
        Article, CreateArticle, UpdateArticle, DeleteArticle, Favorite, Unfavorite, Comments, CreateComment, DeleteComment }
}
