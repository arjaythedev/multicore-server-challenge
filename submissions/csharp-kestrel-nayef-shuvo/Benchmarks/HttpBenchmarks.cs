using System.Text;
using System.Text.Json;
using BenchmarkDotNet.Attributes;

namespace Conduit.Benchmarks;

/// <summary>Http.cs: reading request bodies, writing responses, parsing numbers.</summary>
[MemoryDiagnoser]
public class HttpBenchmarks
{
    private static readonly byte[] RegisterBody = Encoding.UTF8.GetBytes(
        """{"user":{"username":"someone_1234","email":"someone_1234@example.com","password":"correct horse"}}""");

    private static readonly byte[] ArticleBody = Encoding.UTF8.GetBytes(
        """{"article":{"title":"How to train your dragon, part 2","description":"Ever wonder how a dragon is trained, and by whom?","body":"It takes a Jacobian to train a dragon. Start early, and be patient. Feed it well. Never stand behind it. Repeat for several weeks until it follows the commands without hesitation.","tagList":["dragons","training","fantasy"]}}""");

    private DefaultHttpContext _register = null!;
    private DefaultHttpContext _article = null!;
    private DefaultHttpContext _response = null!;
    private Row[] _rows = null!;
    private string[] _tags = null!;

    private sealed record Row(string Slug, string Title, string Description, string[] Tags, DateTime Created, long Favorites, string Author);

    [GlobalSetup]
    public void Setup()
    {
        _register = Fixtures.NewContext(RegisterBody);
        _article = Fixtures.NewContext(ArticleBody);
        _response = Fixtures.NewContext();
        var created = new DateTime(2026, 3, 1, 12, 30, 45, DateTimeKind.Utc);
        _rows = Enumerable.Range(0, 20).Select(i => new Row(
            $"how-to-train-your-dragon-{100000 - i}", $"How to train your dragon {i}", "Ever wonder how a dragon is trained, and by whom?",
            ["dragons", "training", "fantasy"], created.AddMinutes(i), i * 3, $"someone_{i}")).ToArray();
        _tags = Enumerable.Range(0, 200).Select(i => $"tag-{i:D3}").ToArray();
    }

    // ---------- request bodies (the cost on every register, login, article and comment write) ----------

    [Benchmark]
    public int ReadWrapper_Register()
    {
        Fixtures.Rewind(_register);
        using var body = Http.ReadWrapper(_register, "user").GetAwaiter().GetResult();
        Http.ReqString(body.Element, "username"u8, out var username);
        Http.ReqString(body.Element, "email"u8, out var email);
        Http.ReqString(body.Element, "password"u8, out var password);
        return username.Length + email.Length + password.Length;
    }

    [Benchmark]
    public int ReadWrapper_CreateArticle()
    {
        Fixtures.Rewind(_article);
        using var body = Http.ReadWrapper(_article, "article").GetAwaiter().GetResult();
        Http.ReqString(body.Element, "title"u8, out var title);
        Http.ReqString(body.Element, "description"u8, out var description);
        Http.ReqString(body.Element, "body"u8, out var text);
        return title.Length + description.Length + text.Length;
    }

    // ---------- responses (the cost on every request) ----------

    /// <summary>A 20-article page like GET /api/articles: about 8 KB of JSON, built with a capturing lambda as the handlers do.</summary>
    [Benchmark]
    public void Json_ArticleList20()
    {
        var rows = _rows;
        Http.Json(_response, 200, w =>
        {
            w.WriteStartObject();
            w.WriteStartArray("articles");
            foreach (var r in rows)
            {
                w.WriteStartObject();
                w.WriteString("slug", r.Slug);
                w.WriteString("title", r.Title);
                w.WriteString("description", r.Description);
                w.WriteStartArray("tagList");
                foreach (var t in r.Tags) w.WriteStringValue(t);
                w.WriteEndArray();
                w.WriteString("createdAt", r.Created.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture));
                w.WriteString("updatedAt", r.Created.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture));
                w.WriteBoolean("favorited", false);
                w.WriteNumber("favoritesCount", r.Favorites);
                w.WriteStartObject("author");
                w.WriteString("username", r.Author);
                w.WriteNull("bio");
                w.WriteNull("image");
                w.WriteBoolean("following", false);
                w.WriteEndObject();
                w.WriteEndObject();
            }
            w.WriteEndArray();
            w.WriteNumber("articlesCount", 1000);
            w.WriteEndObject();
        }).GetAwaiter().GetResult();
    }

    /// <summary>GET /api/tags: 200 short strings.</summary>
    [Benchmark]
    public void Json_Tags200()
    {
        var tags = _tags;
        Http.Json(_response, 200, w =>
        {
            w.WriteStartObject();
            w.WriteStartArray("tags");
            foreach (var t in tags) w.WriteStringValue(t);
            w.WriteEndArray();
            w.WriteEndObject();
        }).GetAwaiter().GetResult();
    }

    [Benchmark]
    public void Error_Unauthorized() => Http.Error(_response, 401, "unauthorized").GetAwaiter().GetResult();

    // ---------- numbers ----------

    [Benchmark]
    public long ParseUint_Limit()
    {
        Http.ParseUint("20", out var n);
        return n;
    }

    [Benchmark]
    public long ParseUint_MaxInt64()
    {
        Http.ParseUint("9223372036854775807", out var n);
        return n;
    }
}
