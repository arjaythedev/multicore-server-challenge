using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Conduit.Data;
using Conduit.Http;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Npgsql;
using Xunit;

namespace Conduit.Tests.Endpoints;

/// <summary>
/// The article lists through the router against a real Postgres (CONDUIT_TEST_DB, see <see cref="Conduit.Tests.Data.WriterTests"/>).
/// The class builds one schema from the repository's schema.sql: author "nK" has K articles, each tagged "tK";
/// the viewer follows n3 and favorites n5's articles. Ids grow with insertion, so the newest article has the largest id.
/// Author "esc" has the two oldest articles: esc-1 with five tags that need escaping or are not ASCII, esc-2 with none.
/// </summary>
[Collection(ServerState.Collection)]
public sealed class ListTests : IClassFixture<ListTests.Data>
{
    static readonly int[] Sizes = [0, 1, 3, 5, 999, 1000, 1001];

    public sealed class Data : TestSchema
    {
        public long Viewer;

        protected override async Task Seed()
        {
            string sizes = string.Join(",", Sizes);
            await Exec($"""
                INSERT INTO users (username, email, password_hash) VALUES ('viewer', 'viewer@x', 'h'), ('esc', 'esc@x', 'h');
                INSERT INTO articles (slug, author_id, title, description, body)
                    SELECT 'esc-' || i, u.id, 'title', 'description', 'body' FROM users u, generate_series(1, 2) i WHERE u.username = 'esc' ORDER BY i;
                INSERT INTO tags (name) VALUES ('e😀'), ('dé'), (E'c\nd'), ('b\c'), ('a"b');
                INSERT INTO article_tags (article_id, tag_id) SELECT a.id, t.id FROM articles a, tags t WHERE a.slug = 'esc-1';
                INSERT INTO users (username, email, password_hash) SELECT 'n' || k, 'n' || k || '@x', 'h' FROM unnest(ARRAY[{sizes}]) k;
                INSERT INTO tags (name) SELECT 't' || k FROM unnest(ARRAY[{sizes}]) k;
                INSERT INTO articles (slug, author_id, title, description, body)
                    SELECT 'n' || k || '-' || i, u.id, 'title', 'description', 'body'
                    FROM unnest(ARRAY[{sizes}]) k JOIN users u ON u.username = 'n' || k CROSS JOIN generate_series(1, k) i
                    ORDER BY k, i;
                INSERT INTO article_tags (article_id, tag_id)
                    SELECT a.id, t.id FROM articles a JOIN users u ON u.id = a.author_id JOIN tags t ON t.name = 't' || substr(u.username, 2);
                INSERT INTO follows (follower_id, followee_id) SELECT v.id, u.id FROM users v, users u WHERE v.username = 'viewer' AND u.username = 'n3';
                INSERT INTO favorites (user_id, article_id)
                    SELECT v.id, a.id FROM users v, articles a JOIN users u ON u.id = a.author_id WHERE v.username = 'viewer' AND u.username = 'n5';
                """);
            Viewer = await Scalar<long>("SELECT id FROM users WHERE username = 'viewer'");
        }
    }

    readonly Data _data;

    public ListTests(Data data) => _data = data;

    sealed record Article(string Slug, bool Following, bool Favorited, string[] TagList);

    async Task<(int Status, Article[] Articles, long Count)> Get(string path, string query, bool signedIn = true)
    {
        TestSchema.Require();
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = "GET";
        ctx.Request.Path = path;
        ctx.Request.QueryString = new QueryString(query);
        if (signedIn) ctx.Request.Headers.Authorization = "Token " + Jwt.Issue(_data.Viewer);
        var body = new MemoryStream();
        ctx.Response.Body = body;
        await Router.Handle(ctx);
        await ctx.Response.BodyWriter.FlushAsync();
        if (ctx.Response.StatusCode != 200) return (ctx.Response.StatusCode, [], -1);
        using var doc = JsonDocument.Parse(body.ToArray());
        var articles = doc.RootElement.GetProperty("articles").EnumerateArray().Select(a => new Article(
            a.GetProperty("slug").GetString()!,
            a.GetProperty("author").GetProperty("following").GetBoolean(),
            a.GetProperty("favorited").GetBoolean(),
            [.. a.GetProperty("tagList").EnumerateArray().Select(t => t.GetString()!)])).ToArray();
        return (200, articles, doc.RootElement.GetProperty("articlesCount").GetInt64());
    }

    /// <summary>The slugs of author nK's newest articles, newest first.</summary>
    static string[] Newest(int k, int offset, int limit) =>
        [.. Enumerable.Range(1, k).Reverse().Skip(offset).Take(limit).Select(i => $"n{k}-{i}")];

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(999)]
    [InlineData(1000)]
    [InlineData(1001)]
    public async Task TagCountIsCappedAtAThousandAndPagesAreNewestFirst(int k)
    {
        var (status, articles, count) = await Get("/api/articles", $"?tag=t{k}&limit=20");
        Assert.Equal(200, status);
        Assert.Equal(Math.Min(k, 1000), count);
        Assert.Equal(Newest(k, 0, 20), articles.Select(a => a.Slug));
        Assert.All(articles, a => Assert.Equal([$"t{k}"], a.TagList));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(999)]
    [InlineData(1000)]
    [InlineData(1001)]
    public async Task AuthorCountIsCappedAtAThousand(int k)
    {
        var (_, articles, count) = await Get("/api/articles", $"?author=n{k}&limit=3&offset=1");
        Assert.Equal(Math.Min(k, 1000), count);
        Assert.Equal(Newest(k, 1, 3), articles.Select(a => a.Slug));
    }

    [Theory]
    [InlineData("?tag=t5&limit=10&offset=5")]
    [InlineData("?tag=t5&limit=10&offset=500")]
    [InlineData("?author=n1001&limit=10&offset=1001")]
    [InlineData("?favorited=viewer&limit=1&offset=5")]
    public async Task APagePastTheEndIsEmptyButKeepsTheCount(string query)
    {
        var (status, articles, count) = await Get("/api/articles", query);
        Assert.Equal(200, status);
        Assert.Empty(articles);
        Assert.Equal(query.Contains("n1001") ? 1000 : 5, count);
    }

    [Theory]
    [InlineData("?tag=nope")]
    [InlineData("?author=nobody")]
    [InlineData("?favorited=nobody")]
    [InlineData("?author=%27%3B%20DROP%20TABLE%20articles%3B--")]
    [InlineData("?tag=%F0%9F%A6%80")]
    public async Task AnUnknownFilterIsAnEmptyListNotAnError(string query)
    {
        var (status, articles, count) = await Get("/api/articles", query);
        Assert.Equal(200, status);
        Assert.Empty(articles);
        Assert.Equal(0, count);
    }

    [Theory]
    [InlineData("?limit=2")]
    [InlineData("?tag=&author=&limit=2")]
    public async Task TheGlobalListIsCappedAndNewestFirst(string query)
    {
        var (_, articles, count) = await Get("/api/articles", query);
        Assert.Equal(1000, count);
        Assert.Equal(["n1001-1001", "n1001-1000"], articles.Select(a => a.Slug));
    }

    [Fact]
    public async Task TheFeedHoldsOnlyFollowedAuthorsAndMarksThemFollowed()
    {
        var (_, articles, count) = await Get("/api/articles/feed", "?limit=20");
        Assert.Equal(3, count);
        Assert.Equal(Newest(3, 0, 20), articles.Select(a => a.Slug));
        Assert.All(articles, a => Assert.True(a.Following));
    }

    [Fact]
    public async Task AFeedPagePastTheEndIsEmptyButKeepsTheCount()
    {
        var (_, articles, count) = await Get("/api/articles/feed", "?limit=2&offset=3");
        Assert.Empty(articles);
        Assert.Equal(3, count);
    }

    [Fact]
    public async Task AHugeFeedOffsetIsAnEmptyPage()
    {
        var (status, articles, count) = await Get("/api/articles/feed", $"?limit=100&offset={long.MaxValue}");
        Assert.Equal(200, status);
        Assert.Empty(articles);
        Assert.Equal(3, count);
    }

    [Fact]
    public async Task FollowingAndFavoritedFollowTheViewer()
    {
        var (_, followed, _) = await Get("/api/articles", "?author=n3");
        Assert.All(followed, a => Assert.True(a.Following));
        var (_, other, _) = await Get("/api/articles", "?author=n5");
        Assert.All(other, a => Assert.False(a.Following));
        Assert.All(other, a => Assert.True(a.Favorited));
        var (_, anonymous, _) = await Get("/api/articles", "?author=n3", signedIn: false);
        Assert.All(anonymous, a => Assert.False(a.Following));
        Assert.Equal(3, anonymous.Length);
    }

    [Fact]
    public async Task TagsAreOneSortedArrayWrittenAsTheOtherResponsesAre()
    {
        TestSchema.Require();
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = "GET";
        ctx.Request.Path = "/api/tags";
        var body = new MemoryStream();
        ctx.Response.Body = body;
        await Router.Handle(ctx);
        await ctx.Response.BodyWriter.FlushAsync(TestContext.Current.CancellationToken);

        Assert.Equal(200, ctx.Response.StatusCode);
        Assert.Equal("""{"tags":["a\"b","b\\c","c\nd","dé","e😀","t0","t1","t1000","t1001","t3","t5","t999"]}""", System.Text.Encoding.UTF8.GetString(body.ToArray()));
    }

    [Fact]
    public async Task AnArticlesTagListIsItsSortedEscapedTagsOrEmpty()
    {
        TestSchema.Require();
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = "GET";
        ctx.Request.Path = "/api/articles";
        ctx.Request.QueryString = new QueryString("?author=esc");
        var body = new MemoryStream();
        ctx.Response.Body = body;
        await Router.Handle(ctx);
        await ctx.Response.BodyWriter.FlushAsync(TestContext.Current.CancellationToken);

        Assert.Equal(200, ctx.Response.StatusCode);
        string json = System.Text.Encoding.UTF8.GetString(body.ToArray());
        int esc2 = json.IndexOf("\"slug\":\"esc-2\"", StringComparison.Ordinal), esc1 = json.IndexOf("\"slug\":\"esc-1\"", StringComparison.Ordinal);
        Assert.True(esc2 >= 0 && esc1 > esc2, json);
        Assert.Contains("\"tagList\":[]", json[esc2..esc1]);
        Assert.Contains(""" "tagList":["a\"b","b\\c","c\nd","dé","e😀"]""".TrimStart(), json[esc1..]);
    }

    [Fact]
    public async Task FavoritedListsTheUsersFavoritesNewestFirst()
    {
        var (_, articles, count) = await Get("/api/articles", "?favorited=viewer&limit=2");
        Assert.Equal(5, count);
        Assert.Equal(Newest(5, 0, 2), articles.Select(a => a.Slug));
    }

    [Theory]
    [InlineData("/api/articles", "")]
    [InlineData("/api/articles", "?tag=t1")]
    [InlineData("/api/articles/feed", "")]
    [InlineData("/api/tags", "")]
    public async Task AFailingQueryAnswers500AndLosesNoPooledBuffer(string path, string query)
    {
        TestSchema.Require();
        // two buffers wait in the pool, so the error response takes one from it rather than a new one
        JsonOut a = JsonOut.Rent(), b = JsonOut.Rent();
        a.Dispose();
        b.Dispose();
        long pooled = JsonOut.PooledBytes;
        var reader = Db.Reader;
        // no tables on this search path: every statement fails
        var failing = new Reader(NpgsqlDataSource.Create(
            new NpgsqlConnectionStringBuilder(Environment.GetEnvironmentVariable("CONDUIT_TEST_DB")) { SearchPath = "pg_catalog", Multiplexing = false }.ConnectionString));
        failing.Start(1);
        Db.Reader = failing;
        try
        {
            var ctx = new DefaultHttpContext();
            ctx.Request.Method = "GET";
            ctx.Request.Path = path;
            ctx.Request.QueryString = new QueryString(query);
            ctx.Request.Headers.Authorization = "Token " + Jwt.Issue(_data.Viewer);
            ctx.Response.Body = new MemoryStream();
            await Router.Handle(ctx);

            Assert.Equal(500, ctx.Response.StatusCode);
            Assert.Equal(pooled, JsonOut.PooledBytes);
        }
        finally
        {
            Db.Reader = reader;
            failing.Complete();
        }
    }
}
