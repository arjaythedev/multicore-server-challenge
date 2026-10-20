using System.Buffers;
using System.Buffers.Text;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Conduit;

// HS256 JWTs: {"sub": "<id>", "iat": now, "exp": now + 30 d}. Every request verifies the signature, the alg and exp.
static class Jwt
{
    static byte[] _key;
    static readonly byte[] HeaderB64 = Encoding.ASCII.GetBytes(Base64Url.EncodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"u8));
    const long Ttl = 30L * 24 * 3600;

    public static void Init(string secret) => _key = Encoding.UTF8.GetBytes(secret);

    // one keyed HMAC per thread: half the cost of the one-shot HashData, which sets up a new keyed context every call.
    // Every call still hashes the whole signing input; only the key setup is reused.
    [ThreadStatic] static HMACSHA256 _hmac;

    static void Mac(ReadOnlySpan<byte> data, Span<byte> mac) => (_hmac ??= new HMACSHA256(_key)).TryComputeHash(data, mac, out _);

    public static string Issue(long userId)
    {
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        Span<byte> payload = stackalloc byte[96];
        int n = 0;
        Append(payload, ref n, "{\"sub\":\""u8);
        userId.TryFormat(payload[n..], out int w, provider: CultureInfo.InvariantCulture); n += w;
        Append(payload, ref n, "\",\"iat\":"u8);
        now.TryFormat(payload[n..], out w, provider: CultureInfo.InvariantCulture); n += w;
        Append(payload, ref n, ",\"exp\":"u8);
        (now + Ttl).TryFormat(payload[n..], out w, provider: CultureInfo.InvariantCulture); n += w;
        Append(payload, ref n, "}"u8);

        Span<byte> tok = stackalloc byte[256];
        int t = 0;
        Append(tok, ref t, HeaderB64);
        tok[t++] = (byte)'.';
        t += Base64Url.EncodeToUtf8(payload[..n], tok[t..]);
        Span<byte> mac = stackalloc byte[32];
        Mac(tok[..t], mac);
        tok[t++] = (byte)'.';
        t += Base64Url.EncodeToUtf8(mac, tok[t..]);
        return Encoding.ASCII.GetString(tok[..t]);
    }

    static void Append(Span<byte> dst, ref int n, ReadOnlySpan<byte> s)
    {
        s.CopyTo(dst[n..]);
        n += s.Length;
    }

    // The token as sent after "Token " (ASCII). Returns the user id, or 0 for any invalid token.
    public static long Verify(ReadOnlySpan<byte> token)
    {
        if (token.Length is < 5 or > 2048 || token.IndexOfAnyExceptInRange((byte)'!', (byte)'~') >= 0) return 0;
        // header.payload.signature: the first and the last dot must differ, and the payload holds no dot
        int firstDot = token.IndexOf((byte)'.'), lastDot = token.LastIndexOf((byte)'.');
        if (firstDot < 1 || lastDot <= firstDot + 1 || token.Slice(firstDot + 1, lastDot - firstDot - 1).Contains((byte)'.'))
            return 0;

        // nothing in the token is looked at before its signature checks out
        Span<byte> sigBytes = stackalloc byte[64];
        if (Base64Url.DecodeFromUtf8(token[(lastDot + 1)..], sigBytes, out _, out int sigCount) != OperationStatus.Done ||
            sigCount != 32)
            return 0;
        Span<byte> ours = stackalloc byte[32];
        Mac(token[..lastDot], ours);
        if (!CryptographicOperations.FixedTimeEquals(ours, sigBytes[..32])) return 0;

        Span<byte> scratch = stackalloc byte[1536];
        var fields = new TokenFields();
        if (!Segment(token[..firstDot], scratch, out int hdrCount) || !Read(scratch[..hdrCount], header: true, ref fields) ||
            !fields.AlgOk)
            return 0;
        if (!Segment(token.Slice(firstDot + 1, lastDot - firstDot - 1), scratch, out int claimCount) ||
            !Read(scratch[..claimCount], header: false, ref fields) || fields.Sub == 0 || !fields.HasExp)
            return 0;
        return fields.Exp > DateTimeOffset.UtcNow.ToUnixTimeSeconds() ? fields.Sub : 0;
    }

    static bool Segment(ReadOnlySpan<byte> base64, Span<byte> into, out int length)
    {
        length = 0;
        return Base64Url.GetMaxDecodedLength(base64.Length) <= into.Length &&
               Base64Url.DecodeFromUtf8(base64, into, out _, out length) == OperationStatus.Done;
    }

    // What the server reads from a token: the header's alg, the payload's sub and exp.
    struct TokenFields
    {
        public bool AlgOk, HasExp;
        public long Sub;
        public double Exp;
    }

    // One pass over the top-level members of a JSON object segment. Members this server doesn't use are skipped;
    // a member it uses with the wrong type (or an alg other than HS256) makes the token invalid.
    static bool Read(ReadOnlySpan<byte> json, bool header, ref TokenFields fields)
    {
        var reader = new Utf8JsonReader(json);
        try
        {
            if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return false;
            while (reader.Read())
            {
                if (reader.TokenType == JsonTokenType.EndObject) return true;
                int member = header
                    ? (reader.ValueTextEquals("alg"u8) ? 1 : 0)
                    : reader.ValueTextEquals("sub"u8) ? 2 : reader.ValueTextEquals("exp"u8) ? 3 : 0;
                if (!reader.Read()) return false;
                switch (member)
                {
                    case 1:
                        if (reader.TokenType != JsonTokenType.String || !reader.ValueTextEquals("HS256"u8)) return false;
                        fields.AlgOk = true;
                        break;
                    case 2:
                        if (reader.TokenType != JsonTokenType.String || reader.ValueIsEscaped) return false;
                        fields.Sub = DecimalId(reader.ValueSpan);
                        if (fields.Sub == 0) return false;
                        break;
                    case 3:
                        if (reader.TokenType != JsonTokenType.Number || !reader.TryGetDouble(out fields.Exp)) return false;
                        fields.HasExp = true;
                        break;
                    default:
                        reader.Skip();
                        break;
                }
            }
            return false;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    // a positive user id written in decimal digits only (at most 18, so it can't overflow); 0 otherwise
    static long DecimalId(ReadOnlySpan<byte> digits)
    {
        if (digits.Length is 0 or > 18) return 0;
        long id = 0;
        foreach (byte c in digits)
        {
            uint d = (uint)(c - '0');
            if (d > 9) return 0;
            id = id * 10 + d;
        }
        return id;
    }
}
