using System;
using System.Buffers;
using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

/// <summary>HS256 JWTs: {"sub": "&lt;id&gt;", "iat", "exp": iat + 30 days}. Every request verifies signature and exp.</summary>
static class Jwt
{
    const long Ttl = 30L * 24 * 3600;

    /// <summary>The longest token this server accepts.</summary>
    public const int MaxTokenBytes = 4096;

    /// <summary>The most bytes <see cref="Issue(long, Span{byte})"/> writes: header, payload with three 20-digit
    /// numbers, signature.</summary>
    public const int MaxIssuedBytes = 36 + 1 + (MaxPayloadBytes + 2) / 3 * 4 + 1 + 43;

    const int MaxPayloadBytes = 24 + 3 * 20; // {"sub":"","iat":,"exp":} and the numbers

    // {"alg":"HS256","typ":"JWT"}
    static ReadOnlySpan<byte> HeaderB64 => "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"u8;
    static byte[] _key = [];
    // Unpadded base64url and the two dots. .NET's decoder would also skip whitespace and accept padding; JWTs have neither.
    static readonly SearchValues<byte> TokenChars = SearchValues.Create("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."u8);

    [ThreadStatic] static HMACSHA256? t_hmac;
    [ThreadStatic] static byte[]? t_hmacKey;

    public static void Init(string secret) => _key = Encoding.UTF8.GetBytes(secret);

    /// <summary>HMAC-SHA256 with a keyed instance kept per thread: the one-shot HashData sets the key up again on
    /// every call, which costs about as much as the MAC. Issue and Verify never await, so no other caller shares it.
    /// TryComputeHash on a kept instance allocates nothing (JwtAllocationTests).</summary>
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

    /// <summary>Writes a token for <paramref name="userId"/> into <paramref name="dest"/> (at least
    /// <see cref="MaxIssuedBytes"/>) and returns its length.</summary>
    public static int Issue(long userId, Span<byte> dest) => Issue(userId, DateTimeOffset.UtcNow.ToUnixTimeSeconds(), dest);

    /// <summary><see cref="Issue(long, Span{byte})"/> as issued at <paramref name="now"/> (Unix seconds).</summary>
    public static int Issue(long userId, long now, Span<byte> dest)
    {
        if (dest.Length < MaxIssuedBytes) throw new ArgumentException("dest is too small", nameof(dest));
        Span<byte> payload = stackalloc byte[MaxPayloadBytes];
        int p = 0;
        "{\"sub\":\""u8.CopyTo(payload);
        p += 8;
        p += Number(userId, payload[p..]);
        "\",\"iat\":"u8.CopyTo(payload[p..]);
        p += 8;
        p += Number(now, payload[p..]);
        ",\"exp\":"u8.CopyTo(payload[p..]);
        p += 7;
        p += Number(now + Ttl, payload[p..]);
        payload[p++] = (byte)'}';

        HeaderB64.CopyTo(dest);
        int n = HeaderB64.Length;
        dest[n++] = (byte)'.';
        n += Base64Url.EncodeToUtf8(payload[..p], dest[n..]);
        Span<byte> mac = stackalloc byte[32];
        Sign(dest[..n], mac);
        dest[n++] = (byte)'.';
        n += Base64Url.EncodeToUtf8(mac, dest[n..]);
        return n;
    }

    static int Number(long v, Span<byte> dest)
    {
        v.TryFormat(dest, out int n, default, System.Globalization.CultureInfo.InvariantCulture);
        return n;
    }

    /// <summary>The token's user id, or 0 when the token is invalid, expired, not HS256 or has no integer string sub.</summary>
    public static long Verify(ReadOnlySpan<byte> token) => Verify(token, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    /// <summary><see cref="Verify(ReadOnlySpan{byte})"/> with exp and nbf checked against <paramref name="nowMilliseconds"/>
    /// (Unix time).</summary>
    public static long Verify(ReadOnlySpan<byte> token, long nowMilliseconds)
    {
        if (token.Length is 0 or > MaxTokenBytes || token.ContainsAnyExcept(TokenChars)) return 0;
        int d1 = token.IndexOf((byte)'.');
        if (d1 <= 0) return 0;
        int d2 = token[(d1 + 1)..].IndexOf((byte)'.');
        if (d2 <= 0) return 0;
        d2 += d1 + 1;
        ReadOnlySpan<byte> sig = token[(d2 + 1)..];
        if (sig.IndexOf((byte)'.') >= 0) return 0;

        // Signature first: nothing in an unauthenticated token is worth parsing.
        Span<byte> mac = stackalloc byte[32];
        Sign(token[..d2], mac);
        Span<byte> given = stackalloc byte[48];
        if (!Decode(sig, given, out int sigLen) || sigLen != 32) return 0;
        if (!CryptographicOperations.FixedTimeEquals(mac, given[..32])) return 0;

        // The header this server issues is compared as text; any other is parsed.
        if (!token[..d1].SequenceEqual(HeaderB64))
        {
            Span<byte> header = stackalloc byte[d1];
            if (!Decode(token[..d1], header, out int headerLen) || !HeaderIsHs256(header[..headerLen])) return 0;
        }
        ReadOnlySpan<byte> payloadB64 = token[(d1 + 1)..d2];
        Span<byte> payload = stackalloc byte[payloadB64.Length];
        if (!Decode(payloadB64, payload, out int payloadLen)) return 0;
        return Subject(payload[..payloadLen], nowMilliseconds / 1000.0);
    }

    /// <summary>Base64url without throwing: the Try forms only report a short destination and throw on bad input.</summary>
    static bool Decode(ReadOnlySpan<byte> s, Span<byte> dest, out int written) =>
        Base64Url.DecodeFromUtf8(s, dest, out _, out written) == OperationStatus.Done;

    static bool HeaderIsHs256(ReadOnlySpan<byte> json)
    {
        try
        {
            var r = new Utf8JsonReader(json);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return false;
            bool hs256 = false;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
            {
                // a key or value that doesn't unescape (ValueTextEquals would throw) rejects the token
                if (!Body.TryTextEquals(ref r, "alg"u8, out bool isAlg) || !r.Read()) return false;
                if (isAlg)
                {
                    if (r.TokenType != JsonTokenType.String || !Body.TryTextEquals(ref r, "HS256"u8, out hs256)) return false;
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

    const int Other = 0, Sub = 1, Exp = 2, Nbf = 3;

    /// <summary>Which claim the property name the reader is on names; false when it doesn't unescape, which rejects
    /// the token (ValueTextEquals would throw).</summary>
    static bool Claim(ref Utf8JsonReader r, out int claim)
    {
        claim = Other;
        if (!Body.TryTextEquals(ref r, "sub"u8, out bool sub)) return false;
        if (sub) claim = Sub;
        else if (Body.TryTextEquals(ref r, "exp"u8, out bool exp) && exp) claim = Exp;
        else if (Body.TryTextEquals(ref r, "nbf"u8, out bool nbf) && nbf) claim = Nbf;
        return true;
    }

    static long Subject(ReadOnlySpan<byte> json, double now)
    {
        try
        {
            var r = new Utf8JsonReader(json);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return 0;
            long sub = 0;
            double exp = double.NaN, nbf = double.NaN;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
            {
                if (!Claim(ref r, out int claim)) return 0;
                if (claim == Sub)
                {
                    if (!r.Read() || r.TokenType != JsonTokenType.String) return 0;
                    if (r.ValueSpan.Length > 20 || r.ValueIsEscaped) return 0;
                    if (!Query.TryParseUint(r.ValueSpan, out sub)) return 0;
                }
                else if (claim == Exp)
                {
                    if (!r.Read() || r.TokenType != JsonTokenType.Number || !r.TryGetDouble(out exp)) return 0;
                }
                else if (claim == Nbf)
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
            if (double.IsNaN(exp) || !(now < exp)) return 0; // exp is required
            if (!double.IsNaN(nbf) && now < nbf) return 0;
            return sub > 0 ? sub : 0;
        }
        catch (JsonException)
        {
            return 0;
        }
    }

    /// <summary>
    /// The viewer's user id from the Authorization header: 0 when none was sent (<paramref name="present"/> false),
    /// -1 when one was sent but isn't "Token &lt;valid jwt&gt;". A header sent empty is present and invalid, not
    /// anonymous.
    /// </summary>
    public static long Viewer(bool present, ReadOnlySpan<byte> header)
    {
        if (!present) return 0;
        header = header.Trim(" \t"u8);
        if (!header.StartsWith(Scheme)) return -1;
        long id = Verify(header[Scheme.Length..]);
        return id > 0 ? id : -1;
    }

    /// <summary>The token the request presented, once <see cref="Viewer"/> accepted the header.</summary>
    public static ReadOnlySpan<byte> Presented(ReadOnlySpan<byte> header) => header.Trim(" \t"u8)[Scheme.Length..];

    static ReadOnlySpan<byte> Scheme => "Token "u8;
}
