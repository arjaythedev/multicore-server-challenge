using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Conduit;

/// <summary>HS256 JWTs, verified from scratch on every request (no cache): signature, alg, exp, nbf, sub.</summary>
static class Jwt
{
    const long TtlSeconds = 30L * 24 * 3600;
    static byte[] key = [];
    static readonly string HeaderB64 = Base64Url.EncodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"u8);

    public static void Init(string secret) => key = Encoding.UTF8.GetBytes(secret);

    public static string Issue(long userId)
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        string claims = $"{{\"sub\":\"{userId}\",\"iat\":{now},\"exp\":{now + TtlSeconds}}}";
        string msg = HeaderB64 + "." + Base64Url.EncodeToString(Encoding.ASCII.GetBytes(claims));
        Span<byte> mac = stackalloc byte[32];
        HMACSHA256.HashData(key, Encoding.ASCII.GetBytes(msg), mac);
        return msg + "." + Base64Url.EncodeToString(mac);
    }

    /// <summary>Returns the user id of a valid token, or 0. Anything undecodable (bad base64url, bad JSON, bad escapes in a signed payload) is just an invalid token.</summary>
    public static long Verify(string token)
    {
        try { return Check(token); }
        catch (Exception e) when (e is FormatException or JsonException or InvalidOperationException) { return 0; }
    }

    static long Check(string token)
    {
        if (token.Length < 16 || token.Length > 1024) return 0;
        int d1 = token.IndexOf('.');
        if (d1 <= 0) return 0;
        int d2 = token.IndexOf('.', d1 + 1);
        if (d2 < 0 || d2 == token.Length - 1 || d2 == d1 + 1) return 0;
        if (token.IndexOf('.', d2 + 1) >= 0) return 0;

        Span<byte> msg = stackalloc byte[d2];
        if (Ascii.FromUtf16(token.AsSpan(0, d2), msg, out int msgLen) != System.Buffers.OperationStatus.Done || msgLen != d2) return 0;
        Span<byte> mac = stackalloc byte[32];
        HMACSHA256.HashData(key, msg, mac);
        Span<byte> sig = stackalloc byte[32];
        if (!Base64Url.TryDecodeFromChars(token.AsSpan(d2 + 1), sig, out int sigLen) || sigLen != 32) return 0;
        if (!CryptographicOperations.FixedTimeEquals(mac, sig)) return 0;

        // The signature is valid: now the claims. Only this server's own tokens (or ones minted with the secret) get here.
        if (!token.AsSpan(0, d1).SequenceEqual(HeaderB64) && !HeaderIsHs256(token.AsSpan(0, d1))) return 0;

        Span<byte> payload = stackalloc byte[512];
        if (!Base64Url.TryDecodeFromChars(token.AsSpan(d1 + 1, d2 - d1 - 1), payload, out int plen)) return 0;
        var r = new Utf8JsonReader(payload[..plen]);
        if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return 0;
        long sub = 0;
        bool hasExp = false;
        double exp = 0, nbf = double.NegativeInfinity;
        while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
        {
            if (r.ValueTextEquals("sub"u8))
            {
                if (!r.Read() || r.TokenType != JsonTokenType.String) return 0;
                if (!long.TryParse(r.GetString(), System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out sub)) return 0;
            }
            else if (r.ValueTextEquals("exp"u8))
            {
                if (!r.Read() || r.TokenType != JsonTokenType.Number || !r.TryGetDouble(out exp)) return 0;
                hasExp = true;
            }
            else if (r.ValueTextEquals("nbf"u8))
            {
                if (!r.Read() || r.TokenType != JsonTokenType.Number || !r.TryGetDouble(out nbf)) return 0;
            }
            else
            {
                r.Read();
                r.Skip();
            }
        }
        if (!hasExp || sub <= 0) return 0;
        double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
        if (!(now < exp) || now < nbf) return 0;
        return sub;
    }

    static bool HeaderIsHs256(ReadOnlySpan<char> headerB64)
    {
        Span<byte> h = stackalloc byte[256];
        if (!Base64Url.TryDecodeFromChars(headerB64, h, out int n)) return false;
        var r = new Utf8JsonReader(h[..n]);
        if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return false;
        while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
        {
            if (r.ValueTextEquals("alg"u8))
                return r.Read() && r.TokenType == JsonTokenType.String && r.ValueTextEquals("HS256"u8);
            r.Read();
            r.Skip();
        }
        return false;
    }
}
