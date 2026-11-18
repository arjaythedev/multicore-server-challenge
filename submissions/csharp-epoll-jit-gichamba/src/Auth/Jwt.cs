using System.Buffers;
using System.Buffers.Text;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Conduit.Auth;

/// <summary>Result of checking a JWT.</summary>
public enum JwtStatus {
    /// <summary>Signature, algorithm and claims are good and the token has not expired.</summary>
    Ok,
    /// <summary>The token is malformed, signed wrongly, uses another algorithm or lacks a usable claim.</summary>
    Invalid,
    /// <summary>The signature is good but <c>exp</c> is not in the future.</summary>
    Expired,
}

/// <summary>
/// HS256 JSON Web Tokens as SPEC.md describes them: claims <c>sub</c> (decimal user id as a string),
/// <c>iat</c> and <c>exp</c> (30 days after <c>iat</c>). Nothing about a token is cached between calls; each thread
/// keeps only the HMAC state keyed with the secret, so a check does not hash the key again.
/// </summary>
public static class Jwt {
    /// <summary>Token lifetime in seconds (30 days).</summary>
    public const long LifetimeSeconds = 30L * 24 * 3600;

    /// <summary>Longest token accepted. It also sizes the decode buffer.</summary>
    private const int MaxTokenLength = 1024;
    /// <summary>Length of an HMAC-SHA256 signature in bytes.</summary>
    private const int MacLength = 32;
    /// <summary>The fixed header <c>{"alg":"HS256","typ":"JWT"}</c> in base64url, as ASCII.</summary>
    private static readonly byte[] HeaderB64 = Encoding.ASCII.GetBytes(
        Base64Url.EncodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"u8));

    /// <summary>
    /// Checks <paramref name="token"/> (the JWT text as ASCII bytes): the HMAC-SHA256 signature in constant
    /// time, an <c>alg</c> of exactly HS256, a positive decimal <c>sub</c> and an <c>exp</c> after
    /// <paramref name="nowUnix"/>. On <see cref="JwtStatus.Ok"/>, <paramref name="userId"/> is the subject.
    /// </summary>
    public static JwtStatus Verify(ReadOnlySpan<byte> token, ReadOnlySpan<byte> key, long nowUnix, out long userId) {
        userId = 0;
        // Base64Url decoding tolerates '=' padding; JWTs do not carry any.
        if (token.Length == 0 || token.Length > MaxTokenLength || token.IndexOf((byte)'=') >= 0) {
            return JwtStatus.Invalid;
        }

        int dot1 = token.IndexOf((byte)'.');
        if (dot1 <= 0) {
            return JwtStatus.Invalid;
        }

        int dot2 = dot1 + 1 + token[(dot1 + 1)..].IndexOf((byte)'.');
        if (dot2 <= dot1 + 1 || dot2 == token.Length - 1 || token[(dot2 + 1)..].IndexOf((byte)'.') >= 0) {
            return JwtStatus.Invalid;
        }

        Span<byte> mac = stackalloc byte[MacLength];
        if (Base64Url.DecodeFromUtf8(token[(dot2 + 1)..], mac, out _, out int macLen) != OperationStatus.Done
            || macLen != MacLength) {
            return JwtStatus.Invalid;
        }

        Span<byte> expected = stackalloc byte[MacLength];
        Mac(key, token[..dot2], expected);
        if (!CryptographicOperations.FixedTimeEquals(mac, expected)) {
            return JwtStatus.Invalid;
        }

        Span<byte> json = stackalloc byte[MaxTokenLength];
        if (Base64Url.DecodeFromUtf8(token[..dot1], json, out _, out int headerLen) != OperationStatus.Done
            || !HeaderIsHs256(json[..headerLen])) {
            return JwtStatus.Invalid;
        }

        if (Base64Url.DecodeFromUtf8(token[(dot1 + 1)..dot2], json, out _, out int payloadLen) != OperationStatus.Done
            || !ReadClaims(json[..payloadLen], out long sub, out long exp)) {
            return JwtStatus.Invalid;
        }

        if (exp <= nowUnix) {
            return JwtStatus.Expired;
        }

        userId = sub;
        return JwtStatus.Ok;
    }

    /// <summary>
    /// Returns a token for <paramref name="userId"/> with <c>iat</c> = <paramref name="nowUnix"/> and
    /// <c>exp</c> 30 days later, as ASCII bytes.
    /// </summary>
    public static byte[] Sign(long userId, long nowUnix, ReadOnlySpan<byte> key) {
        string claims = string.Create(System.Globalization.CultureInfo.InvariantCulture,
            $"{{\"sub\":\"{userId}\",\"iat\":{nowUnix},\"exp\":{nowUnix + LifetimeSeconds}}}");
        string payload = Base64Url.EncodeToString(Encoding.UTF8.GetBytes(claims));

        byte[] token = new byte[HeaderB64.Length + 1 + payload.Length + 1 + Base64Url.GetEncodedLength(MacLength)];
        HeaderB64.CopyTo(token, 0);
        int at = HeaderB64.Length;
        token[at++] = (byte)'.';
        at += Encoding.ASCII.GetBytes(payload, token.AsSpan(at));

        Span<byte> mac = stackalloc byte[MacLength];
        Mac(key, token.AsSpan(0, at), mac);
        token[at++] = (byte)'.';
        Base64Url.EncodeToUtf8(mac, token.AsSpan(at), out _, out int written);
        return token.AsSpan(0, at + written).ToArray();
    }

    /// <summary>This thread's keyed HMAC state, rebuilt when the key changes.</summary>
    [ThreadStatic]
    private static KeyedMac? t_mac;

    /// <summary>Writes the HMAC-SHA256 of <paramref name="data"/> under <paramref name="key"/> into <paramref name="into"/>. Each thread keeps one keyed state and resets it after each use.</summary>
    private static void Mac(ReadOnlySpan<byte> key, ReadOnlySpan<byte> data, Span<byte> into) {
        KeyedMac? m = t_mac;
        if (m is null || !key.SequenceEqual(m.Key)) {
            m?.Hmac.Dispose();
            t_mac = m = new KeyedMac(key.ToArray());
        }

        m.Hmac.AppendData(data);
        m.Hmac.GetHashAndReset(into);
    }

    /// <summary>An HMAC-SHA256 state bound to one key.</summary>
    private sealed class KeyedMac {
        /// <summary>The key this state was made for.</summary>
        public readonly byte[] Key;
        /// <summary>The reusable HMAC state.</summary>
        public readonly IncrementalHash Hmac;

        /// <summary>Keeps <paramref name="key"/> and creates an HMAC keyed with it.</summary>
        public KeyedMac(byte[] key) {
            Key = key;
            Hmac = IncrementalHash.CreateHMAC(HashAlgorithmName.SHA256, key);
        }
    }

    /// <summary>True when the header is a JSON object with an <c>alg</c> of the string HS256. A repeated <c>alg</c> must also be HS256.</summary>
    private static bool HeaderIsHs256(ReadOnlySpan<byte> json) {
        try {
            Utf8JsonReader r = new(json);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) {
                return false;
            }

            bool seen = false;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName) {
                bool isAlg = r.ValueTextEquals("alg"u8);
                r.Read();
                if (isAlg) {
                    if (r.TokenType != JsonTokenType.String || !r.ValueTextEquals("HS256"u8)) {
                        return false;
                    }

                    seen = true;
                } else {
                    r.Skip();
                }
            }
            return seen && r.TokenType == JsonTokenType.EndObject && !r.Read();
        } catch (JsonException) {
            return false;
        }
    }

    /// <summary>Reads the top-level <c>sub</c> (decimal string, 1 to 18 digits, above zero) and <c>exp</c> (integer).</summary>
    private static bool ReadClaims(ReadOnlySpan<byte> json, out long sub, out long exp) {
        sub = exp = 0;
        try {
            Utf8JsonReader r = new(json);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) {
                return false;
            }

            bool haveSub = false, haveExp = false;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName) {
                bool isSub = r.ValueTextEquals("sub"u8);
                bool isExp = !isSub && r.ValueTextEquals("exp"u8);
                r.Read();
                if (isSub) {
                    if (haveSub || r.TokenType != JsonTokenType.String || !ParseId(r.ValueSpan, r.ValueIsEscaped, out sub)) {
                        return false;
                    }

                    haveSub = true;
                } else if (isExp) {
                    if (haveExp || r.TokenType != JsonTokenType.Number || !r.TryGetInt64(out exp)) {
                        return false;
                    }

                    haveExp = true;
                } else {
                    r.Skip();
                }
            }
            return haveSub && haveExp && r.TokenType == JsonTokenType.EndObject && !r.Read();
        } catch (JsonException) {
            return false;
        }
    }

    /// <summary>Reads 1 to 18 plain digits as a positive id. Escaped text and zero are refused.</summary>
    private static bool ParseId(ReadOnlySpan<byte> digits, bool escaped, out long id) {
        id = 0;
        if (escaped || digits.Length is 0 or > 18) {
            return false;
        }

        foreach (byte b in digits) {
            if (b < '0' || b > '9') {
                return false;
            }

            id = id * 10 + (b - '0');
        }
        return id > 0;
    }
}
