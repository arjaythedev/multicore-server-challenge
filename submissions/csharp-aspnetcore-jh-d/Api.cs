using System.Buffers;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.WebUtilities;
using Npgsql;
using static Conduit.Db;

namespace Conduit;

/// <summary>The 19 endpoints of SPEC.md: a hand-written router and handlers over raw Kestrel, no MVC and no reflection.</summary>
static class Api
{
    // ------------------------------------------------------------------ dispatch

    public static async Task Handle(HttpContext ctx)
    {
        try
        {
            await Route(ctx);
        }
        catch (BadHttpRequestException e)
        {
            if (!ctx.Response.HasStarted) Err(ctx, e.StatusCode, "bad request");
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"{ctx.Request.Method} {ctx.Request.Path}: {e}");
            if (!ctx.Response.HasStarted) Err(ctx, 500, "internal error");
        }
    }

    static Task Route(HttpContext ctx)
    {
        var req = ctx.Request;
        string path = req.Path.Value ?? "/";
        string m = req.Method;
        if (path.Length < 6 || !path.StartsWith("/api/", StringComparison.Ordinal)) return NotFound(ctx);

        ReadOnlySpan<char> rest = path.AsSpan(5);
        Span<Range> segs = stackalloc Range[5];
        int n = rest.Split(segs, '/');
        if (n > 4) return NotFound(ctx);
        for (int i = 0; i < n; i++)
            if (rest[segs[i]].Length == 0) return NotFound(ctx);

        ReadOnlySpan<char> s0 = rest[segs[0]];
        switch (n)
        {
            case 1:
                if (s0.SequenceEqual("tags")) return HttpMethods.IsGet(m) ? Tags(ctx) : NotFound(ctx);
                if (s0.SequenceEqual("user"))
                    return HttpMethods.IsGet(m) ? CurrentUser(ctx) : HttpMethods.IsPut(m) ? UpdateUser(ctx) : NotFound(ctx);
                if (s0.SequenceEqual("users")) return HttpMethods.IsPost(m) ? Register(ctx) : NotFound(ctx);
                if (s0.SequenceEqual("articles"))
                    return HttpMethods.IsGet(m) ? ListArticles(ctx, Sql.KindAll) : HttpMethods.IsPost(m) ? CreateArticle(ctx) : NotFound(ctx);
                break;
            case 2:
            {
                ReadOnlySpan<char> s1 = rest[segs[1]];
                if (s0.SequenceEqual("users")) return s1.SequenceEqual("login") && HttpMethods.IsPost(m) ? Login(ctx) : NotFound(ctx);
                if (s0.SequenceEqual("profiles")) return HttpMethods.IsGet(m) ? Profile(ctx, s1.ToString()) : NotFound(ctx);
                if (s0.SequenceEqual("articles"))
                {
                    if (HttpMethods.IsGet(m)) return s1.SequenceEqual("feed") ? ListArticles(ctx, Sql.KindFeed) : Article(ctx, s1.ToString());
                    if (HttpMethods.IsPut(m)) return UpdateArticle(ctx, s1.ToString());
                    if (HttpMethods.IsDelete(m)) return DeleteArticle(ctx, s1.ToString());
                }
                break;
            }
            case 3:
            {
                ReadOnlySpan<char> s1 = rest[segs[1]], s2 = rest[segs[2]];
                if (s0.SequenceEqual("profiles") && s2.SequenceEqual("follow"))
                    return HttpMethods.IsPost(m) ? Profile(ctx, s1.ToString(), true) : HttpMethods.IsDelete(m) ? Profile(ctx, s1.ToString(), false) : NotFound(ctx);
                if (s0.SequenceEqual("articles"))
                {
                    if (s2.SequenceEqual("favorite"))
                        return HttpMethods.IsPost(m) ? Article(ctx, s1.ToString(), true) : HttpMethods.IsDelete(m) ? Article(ctx, s1.ToString(), false) : NotFound(ctx);
                    if (s2.SequenceEqual("comments"))
                        return HttpMethods.IsGet(m) ? ListComments(ctx, s1.ToString()) : HttpMethods.IsPost(m) ? CreateComment(ctx, s1.ToString()) : NotFound(ctx);
                }
                break;
            }
            case 4:
                if (s0.SequenceEqual("articles") && rest[segs[2]].SequenceEqual("comments") && HttpMethods.IsDelete(m))
                    return DeleteComment(ctx, rest[segs[1]].ToString(), rest[segs[3]].ToString());
                break;
        }
        return NotFound(ctx);
    }

    static Task NotFound(HttpContext ctx)
    {
        Err(ctx, 404, "not found");
        return Task.CompletedTask;
    }

    // ------------------------------------------------------------------ responses

    static readonly ConcurrentDictionary<string, byte[]> errorBodies = new();

    static void Err(HttpContext ctx, int status, string message)
    {
        var body = errorBodies.GetOrAdd(message, static m => Encoding.UTF8.GetBytes("{\"errors\":{\"body\":[\"" + m + "\"]}}"));
        Send(ctx, status, body);
    }

    static void Send(HttpContext ctx, int status, ReadOnlySpan<byte> body)
    {
        var res = ctx.Response;
        res.StatusCode = status;
        res.ContentType = "application/json";
        res.ContentLength = body.Length;
        res.BodyWriter.Write(body);
    }

    static void Send(HttpContext ctx, int status, Out o)
    {
        Send(ctx, status, o.Finish());
        o.Return();
    }

    static void NoContent(HttpContext ctx) => ctx.Response.StatusCode = 204;

    // ------------------------------------------------------------------ auth

    readonly record struct Who(long Id, string? Token, bool Present);

    static Who Authenticate(HttpContext ctx)
    {
        var values = ctx.Request.Headers.Authorization;
        if (values.Count == 0) return default;
        string? h = values[0];
        if (h is null || !h.StartsWith("Token ", StringComparison.Ordinal)) return new Who(0, null, true);
        string token = h.Substring(6);
        long id = Jwt.Verify(token);
        return id > 0 ? new Who(id, token, true) : new Who(0, null, true);
    }

    /// <summary>Required: missing or invalid token gives 401. Optional: no header is anonymous (viewer 0), but a header that is present and invalid gives 401.</summary>
    static bool Authorize(HttpContext ctx, out Who who, bool required)
    {
        who = Authenticate(ctx);
        if (who.Id != 0 || (!required && !who.Present)) return true;
        Err(ctx, 401, "unauthorized");
        return false;
    }

    // ------------------------------------------------------------------ request parsing

    static async ValueTask<JsonDocument?> ReadJson(HttpContext ctx)
    {
        try { return await JsonDocument.ParseAsync(ctx.Request.Body); }
        catch (JsonException) { return null; }
    }

    /// <summary>The body must be a JSON object holding an object under <paramref name="key"/> (matched case-sensitively).</summary>
    static bool Wrapper(JsonDocument? doc, string key, out JsonElement inner)
    {
        inner = default;
        if (doc is null || doc.RootElement.ValueKind != JsonValueKind.Object) return false;
        if (!doc.RootElement.TryGetProperty(key, out inner)) return false;
        return inner.ValueKind == JsonValueKind.Object;
    }

    /// <summary>Present and a non-empty string.</summary>
    static bool ReqStr(JsonElement o, string key, out string value)
    {
        value = "";
        if (!o.TryGetProperty(key, out var e) || e.ValueKind != JsonValueKind.String) return false;
        value = e.GetString() ?? "";
        return value.Length > 0;
    }

    /// <summary>Absent or null leaves the value null; otherwise it must be a string (non-empty when asked). False means invalid.</summary>
    static bool OptStr(JsonElement o, string key, bool nonEmpty, out string? value)
    {
        value = null;
        if (!o.TryGetProperty(key, out var e) || e.ValueKind == JsonValueKind.Null) return true;
        if (e.ValueKind != JsonValueKind.String) return false;
        value = e.GetString() ?? "";
        return !(nonEmpty && value.Length == 0);
    }

    /// <summary>limit (default 20, 1..100) and offset (default 0, >= 0): ASCII digits only; a parameter that is present, even empty, must be valid.</summary>
    static bool ParseQuery(HttpContext ctx, out int limit, out long offset, out int kind, out string filter, bool filters)
    {
        limit = 20;
        offset = 0;
        kind = Sql.KindAll;
        filter = "";
        bool seenLimit = false, seenOffset = false, seenTag = false, seenAuthor = false, seenFav = false;
        string tag = "", author = "", fav = "";
        foreach (var pair in new QueryStringEnumerable(ctx.Request.QueryString.Value))
        {
            switch (pair.DecodeName().Span)
            {
                case "limit" when !seenLimit:
                    seenLimit = true;
                    if (!long.TryParse(pair.DecodeValue().Span, NumberStyles.None, CultureInfo.InvariantCulture, out long l) || l < 1 || l > 100) return false;
                    limit = (int)l;
                    break;
                case "offset" when !seenOffset:
                    seenOffset = true;
                    if (!long.TryParse(pair.DecodeValue().Span, NumberStyles.None, CultureInfo.InvariantCulture, out offset)) return false;
                    offset = Math.Min(offset, int.MaxValue); // far past the last row anyway; keeps the feed's LIMIT (n + offset) from overflowing bigint
                    break;
                case "tag" when filters && !seenTag:
                    seenTag = true;
                    tag = pair.DecodeValue().ToString();
                    break;
                case "author" when filters && !seenAuthor:
                    seenAuthor = true;
                    author = pair.DecodeValue().ToString();
                    break;
                case "favorited" when filters && !seenFav:
                    seenFav = true;
                    fav = pair.DecodeValue().ToString();
                    break;
            }
        }
        // Only the first non-empty filter in the order tag, author, favorited applies.
        if (tag.Length > 0) { kind = Sql.KindTag; filter = tag; }
        else if (author.Length > 0) { kind = Sql.KindAuthor; filter = author; }
        else if (fav.Length > 0) { kind = Sql.KindFavorited; filter = fav; }
        return true;
    }

    static bool ParseId(string s, out long id) => long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out id);

    // ------------------------------------------------------------------ users

    static void WriteUser(Out o, string token, string username, string email, string? bio, string? image)
    {
        var w = o.W;
        w.WriteStartObject(P.User);
        w.WriteString(P.Email, email);
        w.WriteString(P.Token, token);
        w.WriteString(P.Username, username);
        w.WriteString(P.Bio, bio);
        w.WriteString(P.Image, image);
        w.WriteEndObject();
    }

    static string? Str(NpgsqlDataReader r, int i) => r.IsDBNull(i) ? null : r.GetString(i);

    static async Task Register(HttpContext ctx)
    {
        using var doc = await ReadJson(ctx);
        if (!Wrapper(doc, "user", out var u)) { Err(ctx, 422, "invalid body"); return; }
        bool ok = ReqStr(u, "username", out string username);
        ok &= ReqStr(u, "email", out string email);
        ok &= ReqStr(u, "password", out string password);
        if (!ok) { Err(ctx, 422, "username, email and password are required"); return; }
        if (Pw.TooLong(password)) { Err(ctx, 422, "password is too long"); return; }

        string hash = await Pw.Hash(password);
        try
        {
            await using var b = Batch().Add(Sql.UserInsert, S(username), S(email), S(hash));
            await using var rd = await b.ExecuteReaderAsync();
            await rd.ReadAsync();
            var o = Out.Rent();
            WriteUser(o, Jwt.Issue(rd.GetInt64(0)), rd.GetString(1), rd.GetString(2), Str(rd, 3), Str(rd, 4));
            Send(ctx, 201, o);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            Err(ctx, 422, "username or email is already taken");
        }
    }

    static async Task Login(HttpContext ctx)
    {
        using var doc = await ReadJson(ctx);
        if (!Wrapper(doc, "user", out var u)) { Err(ctx, 422, "invalid body"); return; }
        bool ok = ReqStr(u, "email", out string email);
        ok &= ReqStr(u, "password", out string password);
        if (!ok) { Err(ctx, 422, "email and password are required"); return; }

        long id;
        string username, hash;
        string? bio, image;
        await using (var b = Batch().Add(Sql.UserByEmail, S(email)))
        await using (var rd = await b.ExecuteReaderAsync())
        {
            if (!await rd.ReadAsync()) { Err(ctx, 401, "invalid email or password"); return; }
            id = rd.GetInt64(0);
            username = rd.GetString(1);
            email = rd.GetString(2);
            bio = Str(rd, 3);
            image = Str(rd, 4);
            hash = rd.GetString(5);
        }
        if (Pw.TooLong(password) || !await Pw.Verify(password, hash)) { Err(ctx, 401, "invalid email or password"); return; }

        var o = Out.Rent();
        WriteUser(o, Jwt.Issue(id), username, email, bio, image);
        Send(ctx, 200, o);
    }

    static async Task CurrentUser(HttpContext ctx)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        await using var b = Batch().Add(Sql.UserById, L(who.Id));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 401, "unauthorized"); return; }
        var o = Out.Rent();
        WriteUser(o, who.Token!, rd.GetString(0), rd.GetString(1), Str(rd, 2), Str(rd, 3));
        Send(ctx, 200, o);
    }

    static async Task UpdateUser(HttpContext ctx)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        using var doc = await ReadJson(ctx);
        if (!Wrapper(doc, "user", out var u)) { Err(ctx, 422, "invalid body"); return; }
        bool ok = OptStr(u, "email", true, out string? email);
        ok &= OptStr(u, "username", true, out string? username);
        ok &= OptStr(u, "password", true, out string? password);
        ok &= OptStr(u, "bio", false, out string? bio);
        ok &= OptStr(u, "image", false, out string? image);
        if (!ok) { Err(ctx, 422, "invalid user fields"); return; }
        string? hash = null;
        if (password is not null)
        {
            if (Pw.TooLong(password)) { Err(ctx, 422, "password is too long"); return; }
            hash = await Pw.Hash(password);
        }
        try
        {
            await using var b = Batch().Add(Sql.UserUpdate, L(who.Id), NS(email), NS(username), NS(hash), NS(bio), NS(image));
            await using var rd = await b.ExecuteReaderAsync();
            if (!await rd.ReadAsync()) { Err(ctx, 401, "unauthorized"); return; }
            var o = Out.Rent();
            WriteUser(o, who.Token!, rd.GetString(0), rd.GetString(1), Str(rd, 2), Str(rd, 3));
            Send(ctx, 200, o);
        }
        catch (PostgresException e) when (e.SqlState == PostgresErrorCodes.UniqueViolation)
        {
            Err(ctx, 422, "username or email is already taken");
        }
    }

    // ------------------------------------------------------------------ profiles

    static void WriteProfileFields(Utf8JsonWriter w, string username, string? bio, string? image, bool following)
    {
        w.WriteString(P.Username, username);
        w.WriteString(P.Bio, bio);
        w.WriteString(P.Image, image);
        w.WriteBoolean(P.Following, following);
    }

    static async Task Profile(HttpContext ctx, string username, bool? follow = null)
    {
        if (!Authorize(ctx, out var who, required: follow.HasValue)) return;
        await using var b = Batch();
        if (follow is bool f) b.Add(f ? Sql.FollowInsert : Sql.FollowDelete, L(who.Id), S(username)).Add(Sql.ProfileBare, S(username));
        else b.Add(Sql.Profile, L(who.Id), S(username));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 404, "profile not found"); return; }
        var o = Out.Rent();
        var w = o.W;
        w.WriteStartObject(P.Profile);
        WriteProfileFields(w, rd.GetString(0), Str(rd, 1), Str(rd, 2), follow ?? rd.GetBoolean(3));
        w.WriteEndObject();
        Send(ctx, 200, o);
    }

    // ------------------------------------------------------------------ tags

    static async Task Tags(HttpContext ctx)
    {
        await using var b = Batch().Add(Sql.Tags);
        await using var rd = await b.ExecuteReaderAsync();
        var o = Out.Rent();
        var w = o.W;
        w.WriteStartArray(P.Tags);
        while (await rd.ReadAsync()) w.WriteStringValue(rd.GetString(0));
        w.WriteEndArray();
        Send(ctx, 200, o);
    }

    // ------------------------------------------------------------------ articles

    /// <summary>Writes one article object from a row laid out as in Sql (full adds the body column).</summary>
    static void WriteArticle(Utf8JsonWriter w, NpgsqlDataReader r, bool full)
    {
        int i = 0;
        w.WriteStartObject();
        w.WriteString(P.Slug, r.GetString(i++));
        w.WriteString(P.Title, r.GetString(i++));
        w.WriteString(P.Description, r.GetString(i++));
        if (full) w.WriteString(P.Body, r.GetString(i++));
        var created = r.GetFieldValue<DateTime>(i++);
        var updated = r.GetFieldValue<DateTime>(i++);
        w.WriteStartArray(P.TagList);
        foreach (string t in r.GetFieldValue<string[]>(i++)) w.WriteStringValue(t);
        w.WriteEndArray();
        w.WriteTimestamp(P.CreatedAt, created);
        w.WriteTimestamp(P.UpdatedAt, updated);
        long favorites = r.GetInt64(i++);
        bool favorited = r.GetBoolean(i++);
        w.WriteBoolean(P.Favorited, favorited);
        w.WriteNumber(P.FavoritesCount, favorites);
        w.WriteStartObject(P.Author);
        WriteProfileFields(w, r.GetString(i), Str(r, i + 1), Str(r, i + 2), r.GetBoolean(i + 3));
        w.WriteEndObject();
        w.WriteEndObject();
    }

    static Task SendArticle(HttpContext ctx, int status, NpgsqlDataReader r)
    {
        var o = Out.Rent();
        var w = o.W;
        w.WritePropertyName(P.Article);
        WriteArticle(w, r, true);
        Send(ctx, status, o);
        return Task.CompletedTask;
    }

    static async Task ListArticles(HttpContext ctx, int feed)
    {
        bool isFeed = feed == Sql.KindFeed;
        Who who;
        if (!Authorize(ctx, out who, required: isFeed)) return;
        if (!ParseQuery(ctx, out int limit, out long offset, out int kind, out string filter, filters: !isFeed))
        {
            Err(ctx, 422, "limit must be 1-100 and offset >= 0");
            return;
        }
        if (isFeed) kind = Sql.KindFeed;

        var b = Batch();
        var listParams = kind is Sql.KindAll or Sql.KindFeed ? new[] { L(who.Id), L(offset) } : new[] { L(who.Id), L(offset), S(filter) };
        b.Add(Sql.List(kind, limit), listParams);
        switch (kind)
        {
            case Sql.KindAll: b.Add(Sql.CountAll); break;
            case Sql.KindTag: b.Add(Sql.CountTag, S(filter)); break;
            case Sql.KindAuthor: b.Add(Sql.CountAuthor, S(filter)); break;
            case Sql.KindFavorited: b.Add(Sql.CountFavorited, S(filter)); break;
            default: b.Add(Sql.CountFeed, L(who.Id)); break;
        }
        await using (b)
        await using (var rd = await b.ExecuteReaderAsync())
        {
            var o = Out.Rent();
            var w = o.W;
            w.WriteStartArray(P.Articles);
            while (await rd.ReadAsync()) WriteArticle(w, rd, false);
            w.WriteEndArray();
            await rd.NextResultAsync();
            await rd.ReadAsync();
            w.WriteNumber(P.ArticlesCount, rd.GetInt64(0));
            Send(ctx, 200, o);
        }
    }

    /// <summary>GET (favorite null, auth optional) or favorite/unfavorite (auth required): either way the response is the article as the viewer sees it.</summary>
    static async Task Article(HttpContext ctx, string slug, bool? favorite = null)
    {
        if (!Authorize(ctx, out var who, required: favorite.HasValue)) return;
        await using var b = Batch();
        if (favorite is bool f) b.Add(f ? Sql.FavoriteInsert : Sql.FavoriteDelete, L(who.Id), S(slug));
        b.Add(Sql.BySlug, L(who.Id), S(slug));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 404, "article not found"); return; }
        await SendArticle(ctx, 200, rd);
    }

    static async Task CreateArticle(HttpContext ctx)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        using var doc = await ReadJson(ctx);
        if (!Wrapper(doc, "article", out var a)) { Err(ctx, 422, "invalid body"); return; }
        bool ok = ReqStr(a, "title", out string title);
        ok &= ReqStr(a, "description", out string description);
        ok &= ReqStr(a, "body", out string body);
        if (!ok) { Err(ctx, 422, "title, description and body are required"); return; }
        string[]? tags = null;
        if (a.TryGetProperty("tagList", out var tl) && tl.ValueKind != JsonValueKind.Null)
        {
            if (tl.ValueKind != JsonValueKind.Array) { Err(ctx, 422, "tagList must be an array of non-empty strings"); return; }
            var list = new List<string>();
            foreach (var item in tl.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.String || (item.GetString() ?? "").Length == 0)
                {
                    Err(ctx, 422, "tagList must be an array of non-empty strings");
                    return;
                }
                list.Add(item.GetString()!);
            }
            if (list.Count > 0) tags = list.ToArray();
        }

        long id;
        {
            // One transaction: the batch is a single implicit transaction, committed before the response.
            var b = Batch().Add(Sql.ArticleInsert, L(who.Id), S(title), S(description), S(body));
            if (tags is not null)
            {
                b.Add(Sql.TagsInsert, TextArray(tags));
                b.Add(Sql.ArticleTagsInsert, TextArray(tags));
            }
            await using (b)
            await using (var rd = await b.ExecuteReaderAsync())
            {
                await rd.ReadAsync();
                id = rd.GetInt64(0);
                while (await rd.NextResultAsync()) { } // the tag statements: a failure there must not be swallowed on dispose
            }
        }
        await using var b2 = Batch().Add(Sql.ById, L(who.Id), L(id));
        await using var rd2 = await b2.ExecuteReaderAsync();
        if (!await rd2.ReadAsync()) { Err(ctx, 500, "internal error"); return; }
        await SendArticle(ctx, 201, rd2);
    }

    static async Task UpdateArticle(HttpContext ctx, string slug)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        using var doc = await ReadJson(ctx);
        if (!Wrapper(doc, "article", out var a)) { Err(ctx, 422, "invalid body"); return; }
        bool ok = OptStr(a, "title", true, out string? title);
        ok &= OptStr(a, "description", true, out string? description);
        ok &= OptStr(a, "body", true, out string? body);
        if (!ok) { Err(ctx, 422, "title, description and body must be non-empty strings"); return; }

        long id;
        await using (var b = Batch()
                         .Add(Sql.ArticleOwner, S(slug))
                         .Add(Sql.ArticleUpdate, S(slug), NS(title), NS(description), NS(body), L(who.Id)))
        await using (var rd = await b.ExecuteReaderAsync())
        {
            if (!await rd.ReadAsync()) { Err(ctx, 404, "article not found"); return; }
            id = rd.GetInt64(0);
            if (rd.GetInt64(1) != who.Id) { Err(ctx, 403, "not the author"); return; }
            await rd.NextResultAsync(); // finish the UPDATE here: disposing the reader would swallow a timeout
        }
        await using var b2 = Batch().Add(Sql.ById, L(who.Id), L(id));
        await using var rd2 = await b2.ExecuteReaderAsync();
        if (!await rd2.ReadAsync()) { Err(ctx, 404, "article not found"); return; }
        await SendArticle(ctx, 200, rd2);
    }

    static async Task DeleteArticle(HttpContext ctx, string slug)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        await using var b = Batch()
            .Add(Sql.ArticleOwner, S(slug))
            .Add(Sql.ArticleDelete, S(slug), L(who.Id));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 404, "article not found"); return; }
        if (rd.GetInt64(1) != who.Id) { Err(ctx, 403, "not the author"); return; }
        await rd.NextResultAsync();
        NoContent(ctx);
    }

    // ------------------------------------------------------------------ comments

    static void WriteComment(Utf8JsonWriter w, NpgsqlDataReader r, bool withFollowing)
    {
        w.WriteStartObject();
        w.WriteNumber(P.Id, r.GetInt64(0));
        w.WriteTimestamp(P.CreatedAt, r.GetFieldValue<DateTime>(2));
        w.WriteTimestamp(P.UpdatedAt, r.GetFieldValue<DateTime>(3));
        w.WriteString(P.Body, r.GetString(1));
        w.WriteStartObject(P.Author);
        WriteProfileFields(w, r.GetString(4), Str(r, 5), Str(r, 6), withFollowing && r.GetBoolean(7));
        w.WriteEndObject();
        w.WriteEndObject();
    }

    static async Task ListComments(HttpContext ctx, string slug)
    {
        if (!Authorize(ctx, out var who, required: false)) return;
        await using var b = Batch().Add(Sql.Comments, L(who.Id), S(slug));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 404, "article not found"); return; }
        var o = Out.Rent();
        var w = o.W;
        w.WriteStartArray(P.Comments);
        // A single all-NULL row means the article exists and has no comments.
        if (!rd.IsDBNull(0))
        {
            do WriteComment(w, rd, true);
            while (await rd.ReadAsync());
        }
        w.WriteEndArray();
        Send(ctx, 200, o);
    }

    static async Task CreateComment(HttpContext ctx, string slug)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        using var doc = await ReadJson(ctx);
        if (!Wrapper(doc, "comment", out var c)) { Err(ctx, 422, "invalid body"); return; }
        if (!ReqStr(c, "body", out string body)) { Err(ctx, 422, "body is required"); return; }
        await using var b = Batch().Add(Sql.CommentInsert, S(slug), L(who.Id), S(body));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 404, "article not found"); return; }
        var o = Out.Rent();
        var w = o.W;
        w.WritePropertyName(P.Comment);
        WriteComment(w, rd, false);
        Send(ctx, 201, o);
    }

    static async Task DeleteComment(HttpContext ctx, string slug, string idText)
    {
        if (!Authorize(ctx, out var who, required: true)) return;
        if (!ParseId(idText, out long id)) { Err(ctx, 404, "comment not found"); return; }
        await using var b = Batch()
            .Add(Sql.CommentOwner, L(id), S(slug))
            .Add(Sql.CommentDelete, L(id), S(slug), L(who.Id));
        await using var rd = await b.ExecuteReaderAsync();
        if (!await rd.ReadAsync()) { Err(ctx, 404, "comment not found"); return; }
        if (rd.GetInt64(0) != who.Id) { Err(ctx, 403, "not the author"); return; }
        await rd.NextResultAsync();
        NoContent(ctx);
    }
}
