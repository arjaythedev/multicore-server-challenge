using System.Globalization;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace Conduit;

/// <summary>HS256 JWTs (Microsoft.IdentityModel.JsonWebTokens) and bcrypt cost 10 (BCrypt.Net-Next).</summary>
internal sealed class Auth
{
    private const int BcryptCost = 10;
    private const int BcryptMaxBytes = 72;

    private readonly JsonWebTokenHandler handler = new();
    private readonly SigningCredentials credentials;
    private readonly TokenValidationParameters parameters;

    internal Auth(string secret)
    {
        // IdentityModel refuses HS256 keys under 32 bytes, but the benchmark's secret is 26. HMAC zero-pads any key
        // shorter than its 64-byte block, so padding with zeros to 32 bytes gives the very same signatures.
        var keyBytes = Encoding.UTF8.GetBytes(secret);
        if (keyBytes.Length < 32) Array.Resize(ref keyBytes, 32);
        var key = new SymmetricSecurityKey(keyBytes);
        credentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);
        parameters = new TokenValidationParameters
        {
            IssuerSigningKey = key,
            ValidAlgorithms = [SecurityAlgorithms.HmacSha256],
            ValidateIssuer = false,
            ValidateAudience = false,
            ValidateLifetime = true,
            RequireExpirationTime = true,
            RequireSignedTokens = true,
            ClockSkew = TimeSpan.Zero,
        };
    }

    internal string IssueToken(long userId)
    {
        // A raw payload keeps the claims to exactly sub, iat and exp (the descriptor overload also adds nbf).
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var payload = string.Create(CultureInfo.InvariantCulture,
            $"{{\"sub\":\"{userId}\",\"iat\":{now},\"exp\":{now + 30 * 24 * 3600}}}");
        return handler.CreateToken(payload, credentials);
    }

    /// <summary>
    /// Inspects the Authorization header. <c>Present</c> says whether a header was sent; <c>Id</c> &gt; 0 means a valid
    /// token for that user.
    /// </summary>
    internal async Task<(long Id, string Token, bool Present)> Authenticate(HttpRequest req)
    {
        var header = req.Headers.Authorization.FirstOrDefault();
        if (string.IsNullOrEmpty(header)) return (0, "", false);
        if (!header.StartsWith("Token ", StringComparison.Ordinal)) return (0, "", true);
        var token = header[6..];
        try
        {
            var result = await handler.ValidateTokenAsync(token, parameters);
            if (!result.IsValid) return (0, "", true);
            // "sub" must be a JSON string; the claims on the result would turn a number into one.
            if (result.SecurityToken is not JsonWebToken jwt) return (0, "", true);
            using var payload = JsonDocument.Parse(Base64UrlEncoder.DecodeBytes(jwt.EncodedPayload));
            if (!payload.RootElement.TryGetProperty("sub", out var sub) || sub.ValueKind != JsonValueKind.String)
                return (0, "", true);
            var s = sub.GetString();
            if (!Http.ParseUint(s, out var id) || id <= 0) return (0, "", true);
            return (id, token, true);
        }
        catch (Exception)
        {
            return (0, "", true);
        }
    }

    /// <summary>False for passwords bcrypt cannot hash (over 72 bytes).</summary>
    internal static bool TryHash(string password, out string hash)
    {
        if (Encoding.UTF8.GetByteCount(password) > BcryptMaxBytes)
        {
            hash = "";
            return false;
        }
        hash = BCrypt.Net.BCrypt.HashPassword(password, BcryptCost);
        return true;
    }

    internal static bool Verify(string password, string hash)
    {
        if (Encoding.UTF8.GetByteCount(password) > BcryptMaxBytes) return false;
        try { return BCrypt.Net.BCrypt.Verify(password, hash); }
        catch (Exception) { return false; }
    }
}
