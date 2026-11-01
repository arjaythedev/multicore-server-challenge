using System.Globalization;
using System.Security.Claims;
using System.Text.Encodings.Web;
using Conduit.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Conduit.Auth;

/// <summary>Authenticates "Authorization: Token &lt;jwt&gt;" (RealWorld's scheme) and answers challenges with a JSON 401.</summary>
public sealed class TokenAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    TokenService tokens)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    public const string SchemeName = "Token";
    private const string Prefix = "Token ";

    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var header = Request.Headers.Authorization.ToString();
        if (header.Length == 0)
        {
            return Task.FromResult(AuthenticateResult.NoResult());
        }

        if (!header.StartsWith(Prefix, StringComparison.Ordinal) || !tokens.TryValidate(header[Prefix.Length..], out var userId))
        {
            return Task.FromResult(AuthenticateResult.Fail("invalid token"));
        }

        var identity = new ClaimsIdentity([new Claim(CurrentUser.IdClaim, userId.ToString(CultureInfo.InvariantCulture))], SchemeName);
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identity), SchemeName)));
    }

    protected override Task HandleChallengeAsync(AuthenticationProperties properties)
    {
        Response.StatusCode = StatusCodes.Status401Unauthorized;
        return Response.WriteAsJsonAsync(ApiErrors.Body("unauthorized"), AppJsonContext.Default.ErrorResponse);
    }
}

/// <summary>Reads the authenticated user from the request.</summary>
public static class CurrentUser
{
    public const string IdClaim = "sub";

    /// <summary>The user id from the token, or 0 when anonymous (no user has id 0).</summary>
    public static long Id(this ClaimsPrincipal user) =>
        long.TryParse(user.FindFirstValue(IdClaim), NumberStyles.None, CultureInfo.InvariantCulture, out var id) ? id : 0;

    /// <summary>The token the request presented; responses for the current user echo it back.</summary>
    public static string PresentedToken(this HttpRequest request) =>
        request.Headers.Authorization.ToString()["Token ".Length..];
}

/// <summary>
/// For endpoints where auth is optional: no header means anonymous, but a header that fails to authenticate is a 401.
/// </summary>
public sealed class RejectInvalidTokenFilter : IEndpointFilter
{
    public async ValueTask<object?> InvokeAsync(EndpointFilterInvocationContext context, EndpointFilterDelegate next)
    {
        var result = await context.HttpContext.AuthenticateAsync(TokenAuthenticationHandler.SchemeName);
        return result.Failure is not null ? ApiErrors.Unauthorized() : await next(context);
    }
}
