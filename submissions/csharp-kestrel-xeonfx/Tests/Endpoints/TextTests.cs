using System.IO;
using System.Text.Json;
using System.Threading.Tasks;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace Conduit.Tests.Endpoints;

/// <summary>
/// Text columns go from Postgres's UTF-8 bytes into the JSON: every endpoint that writes them returns exactly what
/// was stored, quotes, backslashes, controls, non-ASCII and emoji included.
/// </summary>
[Collection(ServerState.Collection)]
public sealed class TextTests(TextTests.Data data) : IClassFixture<TextTests.Data>
{
    public const string Username = "n\"a\\me é😀";
    public const string Bio = "line1\nline2\t\"quoted\" \\ <b>&</b> \u0001 ünï 日本 🙂";
    public const string Image = "https://x/ä.png?a=1&b=\"2\"";
    public const string Title = "Tïtle \"with\" \\ 🚀";
    public const string Description = "déscription\r\n\u001f end";
    public const string Body = "body ✓ \u2028 \u2029 </script> 💡";
    public const string Comment = "comment \"🙂\" \\n";

    public sealed class Data : TestSchema
    {
        public long Author;

        protected override async Task Seed()
        {
            await using (var cmd = Admin.CreateCommand(
                "INSERT INTO users (username, email, password_hash, bio, image) VALUES ($1, 'e\"@x', 'h', $2, $3) RETURNING id"))
            {
                cmd.Parameters.AddWithValue(Username);
                cmd.Parameters.AddWithValue(Bio);
                cmd.Parameters.AddWithValue(Image);
                Author = (long)(await cmd.ExecuteScalarAsync())!;
            }
            await using (var cmd = Admin.CreateCommand(
                "WITH a AS (INSERT INTO articles (slug, author_id, title, description, body) VALUES ('text-1', $1, $2, $3, $4) RETURNING id) " +
                "INSERT INTO comments (article_id, author_id, body) SELECT id, $1, $5 FROM a"))
            {
                cmd.Parameters.AddWithValue(Author);
                cmd.Parameters.AddWithValue(Title);
                cmd.Parameters.AddWithValue(Description);
                cmd.Parameters.AddWithValue(Body);
                cmd.Parameters.AddWithValue(Comment);
                await cmd.ExecuteNonQueryAsync();
            }
        }
    }

    async Task<JsonElement> Get(string path)
    {
        TestSchema.Require();
        var ctx = new DefaultHttpContext();
        ctx.Request.Method = "GET";
        ctx.Request.Path = path;
        ctx.Request.Headers.Authorization = "Token " + Jwt.Issue(data.Author);
        var body = new MemoryStream();
        ctx.Response.Body = body;
        await Router.Handle(ctx);
        await ctx.Response.BodyWriter.FlushAsync();
        Assert.Equal(200, ctx.Response.StatusCode);
        return JsonDocument.Parse(body.ToArray()).RootElement.Clone();
    }

    static void IsAuthor(JsonElement p)
    {
        Assert.Equal(Username, p.GetProperty("username").GetString());
        Assert.Equal(Bio, p.GetProperty("bio").GetString());
        Assert.Equal(Image, p.GetProperty("image").GetString());
    }

    [Fact]
    public async Task AnArticleComesBackAsStored()
    {
        var a = (await Get("/api/articles/text-1")).GetProperty("article");
        Assert.Equal("text-1", a.GetProperty("slug").GetString());
        Assert.Equal(Title, a.GetProperty("title").GetString());
        Assert.Equal(Description, a.GetProperty("description").GetString());
        Assert.Equal(Body, a.GetProperty("body").GetString());
        IsAuthor(a.GetProperty("author"));
    }

    [Fact]
    public async Task AListComesBackAsStored()
    {
        var a = (await Get("/api/articles")).GetProperty("articles")[0];
        Assert.Equal(Title, a.GetProperty("title").GetString());
        Assert.Equal(Description, a.GetProperty("description").GetString());
        IsAuthor(a.GetProperty("author"));
    }

    [Fact]
    public async Task ACommentComesBackAsStored()
    {
        var c = (await Get("/api/articles/text-1/comments")).GetProperty("comments")[0];
        Assert.Equal(Comment, c.GetProperty("body").GetString());
        IsAuthor(c.GetProperty("author"));
    }

    [Fact]
    public async Task AProfileAndTheCurrentUserComeBackAsStored()
    {
        // Kestrel hands the router the decoded path
        IsAuthor((await Get("/api/profiles/" + Username)).GetProperty("profile"));
        var u = (await Get("/api/user")).GetProperty("user");
        Assert.Equal(Username, u.GetProperty("username").GetString());
        Assert.Equal("e\"@x", u.GetProperty("email").GetString());
        Assert.Equal(Bio, u.GetProperty("bio").GetString());
        Assert.Equal(Image, u.GetProperty("image").GetString());
    }
}
