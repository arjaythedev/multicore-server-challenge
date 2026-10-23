using System.IO;
using System.Threading.Tasks;
using Conduit.Security;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace Conduit.Tests.Security;

/// <summary>
/// The Authorization header: absent means anonymous; present means it must be a valid "Token" header, even when
/// empty. Kestrel trims a header's surrounding whitespace, so a header of spaces arrives empty.
/// </summary>
[Collection(ServerState.Collection)]
public class AuthTests
{
    const long User = 42;

    public AuthTests() => Jwt.Init("auth-tests");

    static DefaultHttpContext With(string? header)
    {
        var ctx = new DefaultHttpContext();
        if (header is not null) ctx.Request.Headers.Authorization = header;
        return ctx;
    }

    [Fact]
    public void NoHeaderIsAnonymous() => Assert.Equal(0, Auth.Viewer(With(null)));

    [Fact]
    public void AValidTokenIsItsUser() => Assert.Equal(User, Auth.Viewer(With("Token " + Jwt.Issue(User))));

    [Theory]
    [InlineData("")]
    [InlineData(" ")]
    [InlineData("Token")]
    [InlineData("Token ")]
    [InlineData("token {0}")]
    [InlineData("Bearer {0}")]
    [InlineData("Token  {0}")]
    [InlineData("Token {0}x")]
    [InlineData("{0}")]
    public void APresentHeaderThatIsNotAValidTokenIsRejected(string header) =>
        Assert.Equal(-1, Auth.Viewer(With(string.Format(header, Jwt.Issue(User)))));

    /// <summary>Optional-auth endpoints answer 401 before touching the database; so does one that requires auth.</summary>
    [Theory]
    [InlineData("/api/articles")]
    [InlineData("/api/articles/some-slug")]
    [InlineData("/api/articles/some-slug/comments")]
    [InlineData("/api/profiles/someone")]
    [InlineData("/api/user")]
    public async Task AnEmptyHeaderIsUnauthorizedThroughTheRouter(string path)
    {
        var ctx = With("");
        ctx.Request.Method = "GET";
        ctx.Request.Path = path;
        ctx.Response.Body = new MemoryStream();
        await Router.Handle(ctx);
        Assert.Equal(401, ctx.Response.StatusCode);
    }
}
