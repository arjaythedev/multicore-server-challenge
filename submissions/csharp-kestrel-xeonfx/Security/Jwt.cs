using System;
using System.Buffers;
using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Conduit.Http;

namespace Conduit.Security;

/// <summary>HS256 JWTs: {"sub": "&lt;id&gt;", "iat", "exp": iat + 30 days}. Every request verifies signature and exp.</summary>
public static class Jwt
{
    const long Ttl = 30L * 24 * 3600;
    // {"alg":"HS256","typ":"JWT"}
    const string HeaderB64 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
    static byte[] _key = [];
    // Unpadded base64url and the two dots. .NET's decoder would also skip whitespace and accept padding; JWTs have neither.
    static readonly SearchValues<char> TokenChars = SearchValues.Create("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.");

    [ThreadStatic] static HMACSHA256? t_hmac;
    [ThreadStatic] static byte[]? t_hmacKey;

    public static void Init(string secret) => _key = Encoding.UTF8.GetBytes(secret);

    /// <summary>HMAC-SHA256 with a keyed instance kept per thread: the one-shot HashData sets the key up again on
    /// every call, which costs about as much as the MAC. Issue and Verify never await, so no other caller shares it.</summary>
    static void Sign(ReadOnlySpan<byte> input, Span<byte> mac)
    {
        var key = _key;
        if (t_hmacKey != key)
        {
            t_hmac?.Dispose();
            t_hmac = new HMACSHA256(key);
            t_hmacKey = key;
        }
        t_hmac!.TryComputeHash(input, mac, out _);
    }

    public static string Issue(long userId)
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        string payload = $"{{\"sub\":\"{userId}\",\"iat\":{now},\"exp\":{now + Ttl}}}";
        Span<byte> payloadBytes = stackalloc byte[payload.Length];
        Encoding.ASCII.GetBytes(payload, payloadBytes);

        string signingInput = HeaderB64 + "." + Base64Url.EncodeToString(payloadBytes);
        Span<byte> input = stackalloc byte[signingInput.Length];
        Encoding.ASCII.GetBytes(signingInput, input);
        Span<byte> mac = stackalloc byte[32];
        Sign(input, mac);
        return signingInput + "." + Base64Url.EncodeToString(mac);
    }

    /// <summary>The token's user id, or 0 when the token is invalid, expired, not HS256 or has no integer string sub.</summary>
    public static long Verify(ReadOnlySpan<char> token)
    {
        if (token.Length is 0 or > 4096 || token.ContainsAnyExcept(TokenChars)) return 0;
        int d1 = token.IndexOf('.');
        if (d1 <= 0) return 0;
        int d2 = token[(d1 + 1)..].IndexOf('.');
        if (d2 <= 0) return 0;
        d2 += d1 + 1;
        ReadOnlySpan<char> sig = token[(d2 + 1)..];
        if (sig.IndexOf('.') >= 0) return 0;

        // Signature first: nothing in an unauthenticated token is worth parsing.
        Span<byte> input = stackalloc byte[d2];
        Encoding.ASCII.GetBytes(token[..d2], input);
        Span<byte> mac = stackalloc byte[32];
        Sign(input, mac);
        Span<byte> given = stackalloc byte[48];
        if (!Decode(sig, given, out int sigLen) || sigLen != 32) return 0;
        if (!CryptographicOperations.FixedTimeEquals(mac, given[..32])) return 0;

        // The header this server issues is compared as text; any other is parsed.
        if (!token[..d1].SequenceEqual(HeaderB64))
        {
            Span<byte> header = stackalloc byte[d1];
            if (!Decode(token[..d1], header, out int headerLen) || !HeaderIsHs256(header[..headerLen])) return 0;
        }
        ReadOnlySpan<char> payloadB64 = token[(d1 + 1)..d2];
        Span<byte> payload = stackalloc byte[payloadB64.Length];
        if (!Decode(payloadB64, payload, out int payloadLen)) return 0;
        return Subject(payload[..payloadLen]);
    }

    /// <summary>Base64url without throwing: TryDecodeFromChars only reports a short destination and throws on bad input.</summary>
    static bool Decode(ReadOnlySpan<char> s, Span<byte> dest, out int written) =>
        Base64Url.DecodeFromChars(s, dest, out _, out written) == OperationStatus.Done;

    static bool HeaderIsHs256(ReadOnlySpan<byte> json)
    {
        try
        {
            var r = new Utf8JsonReader(json);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return false;
            bool hs256 = false;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
            {
                bool isAlg = r.ValueTextEquals("alg"u8);
                if (!r.Read()) return false;
                if (isAlg)
                {
                    if (r.TokenType != JsonTokenType.String) return false;
                    hs256 = r.ValueTextEquals("HS256"u8);
                }
                else r.Skip();
            }
            return hs256 && r.TokenType == JsonTokenType.EndObject;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    static long Subject(ReadOnlySpan<byte> json)
    {
        try
        {
            var r = new Utf8JsonReader(json);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return 0;
            long sub = 0;
            double exp = double.NaN, nbf = double.NaN;
            Span<char> buf = stackalloc char[20];
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
            {
                if (r.ValueTextEquals("sub"u8))
                {
                    if (!r.Read() || r.TokenType != JsonTokenType.String) return 0;
                    if (r.ValueSpan.Length > 20 || r.ValueIsEscaped) return 0;
                    int n = Encoding.ASCII.GetChars(r.ValueSpan, buf);
                    if (!Query.TryParseUint(buf[..n], out sub)) return 0;
                }
                else if (r.ValueTextEquals("exp"u8))
                {
                    if (!r.Read() || r.TokenType != JsonTokenType.Number || !r.TryGetDouble(out exp)) return 0;
                }
                else if (r.ValueTextEquals("nbf"u8))
                {
                    if (!r.Read() || r.TokenType != JsonTokenType.Number || !r.TryGetDouble(out nbf)) return 0;
                }
                else
                {
                    if (!r.Read()) return 0;
                    r.Skip();
                }
            }
            if (r.TokenType != JsonTokenType.EndObject) return 0;
            double now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            if (double.IsNaN(exp) || !(now < exp)) return 0; // exp is required
            if (!double.IsNaN(nbf) && now < nbf) return 0;
            return sub > 0 ? sub : 0;
        }
        catch (JsonException)
        {
            return 0;
        }
    }
}
