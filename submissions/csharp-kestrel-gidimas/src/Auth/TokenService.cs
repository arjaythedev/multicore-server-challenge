using System.Buffers.Text;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Conduit.Auth;

/// <summary>
/// Issues and verifies the HS256 tokens SPEC.md describes: {"sub": "&lt;id&gt;", "iat", "exp": iat + 30 days}.
/// Hand-rolled on purpose: Microsoft.IdentityModel rejects HMAC keys shorter than 256 bits, and the
/// challenge secret is 208 bits. Every call verifies the signature, the algorithm and the expiry; nothing is cached.
/// </summary>
public sealed class TokenService(string secret)
{
    private static readonly TimeSpan Lifetime = TimeSpan.FromDays(30);
    private static readonly string EncodedHeader = Base64Url.EncodeToString("""{"alg":"HS256","typ":"JWT"}"""u8);

    private readonly byte[] _key = Encoding.UTF8.GetBytes(secret);

    public string Issue(long userId)
    {
        var now = DateTimeOffset.UtcNow;
        var payload = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["sub"] = userId.ToString(CultureInfo.InvariantCulture),
            ["iat"] = now.ToUnixTimeSeconds(),
            ["exp"] = now.Add(Lifetime).ToUnixTimeSeconds(),
        });

        var signingInput = EncodedHeader + "." + Base64Url.EncodeToString(payload);
        var signature = HMACSHA256.HashData(_key, Encoding.ASCII.GetBytes(signingInput));
        return signingInput + "." + Base64Url.EncodeToString(signature);
    }

    /// <summary>Returns the user id when the token is a valid, unexpired HS256 token signed with our secret.</summary>
    public bool TryValidate(string token, out long userId)
    {
        userId = 0;
        var parts = token.Split('.');
        if (parts.Length != 3)
        {
            return false;
        }

        try
        {
            using (var header = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[0])))
            {
                if (!header.RootElement.TryGetProperty("alg", out var alg) || alg.GetString() != "HS256")
                {
                    return false;
                }
            }

            var expected = HMACSHA256.HashData(_key, Encoding.ASCII.GetBytes(parts[0] + "." + parts[1]));
            if (!CryptographicOperations.FixedTimeEquals(expected, Base64Url.DecodeFromChars(parts[2])))
            {
                return false;
            }

            using var payload = JsonDocument.Parse(Base64Url.DecodeFromChars(parts[1]));
            var claims = payload.RootElement;
            if (!claims.TryGetProperty("exp", out var exp) || exp.ValueKind != JsonValueKind.Number
                || exp.GetInt64() <= DateTimeOffset.UtcNow.ToUnixTimeSeconds())
            {
                return false;
            }

            return claims.TryGetProperty("sub", out var sub) && sub.ValueKind == JsonValueKind.String
                && long.TryParse(sub.GetString(), NumberStyles.None, CultureInfo.InvariantCulture, out userId);
        }
        catch (Exception e) when (e is FormatException or JsonException)
        {
            return false;
        }
    }
}
