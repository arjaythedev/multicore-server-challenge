using System;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Primitives;

namespace Conduit.Security;

public static class Auth
{
    /// <summary>
    /// The viewer's user id; 0 when no Authorization header was sent; -1 when one was sent but isn't a valid token.
    /// A header sent empty (or only whitespace, which Kestrel trims away) is present and invalid, not anonymous.
    /// </summary>
    public static long Viewer(HttpContext ctx)
    {
        string? value = Header(ctx);
        if (value is null) return 0;
        if (!value.StartsWith(Scheme, StringComparison.Ordinal)) return -1;
        long id = Jwt.Verify(value.AsSpan(Scheme.Length));
        return id > 0 ? id : -1;
    }

    /// <summary>The token the request presented (call after Viewer accepted it).</summary>
    public static ReadOnlySpan<char> Token(HttpContext ctx) => Header(ctx).AsSpan(Scheme.Length);

    const string Scheme = "Token ";

    static string? Header(HttpContext ctx)
    {
        StringValues h = ctx.Request.Headers.Authorization;
        return h.Count > 0 ? h[0] ?? "" : null;
    }
}
