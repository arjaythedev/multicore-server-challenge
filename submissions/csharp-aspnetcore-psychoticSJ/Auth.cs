using System.Buffers;
using System.Buffers.Text;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ConduitChallenge;

static class Auth
{
    const string Header = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";
    static byte[] _key = [];

    public static void Configure(string secret)
    {
        ArgumentException.ThrowIfNullOrEmpty(secret);
        _key = Encoding.UTF8.GetBytes(secret);
    }

    public static bool TryRead(HttpContext context, bool required, out long viewer, out string? token, bool captureToken = true)
    {
        viewer = 0;
        token = null;
        var headers = context.Request.Headers.Authorization;
        if (headers.Count == 0) return !required;
        if (headers.Count != 1 || headers[0] is not { } header || !header.StartsWith("Token ", StringComparison.Ordinal)) return false;

        var encoded = header.AsSpan(6);
        var first = encoded.IndexOf('.');
        if (first <= 0) return false;
        var second = encoded[(first + 1)..].IndexOf('.');
        if (second <= 0) return false;
        second += first + 1;
        var signature = encoded[(second + 1)..];
        if (signature.Length != 43 || !IsBase64Url(encoded[..first]) || !IsBase64Url(encoded[(first + 1)..second]) || !IsBase64Url(signature)) return false;

        byte[]? rentedInput = null;
        byte[]? rentedHeader = null;
        byte[]? rentedPayload = null;
        var inputSize = second;
        var headerSize = first * 3 / 4 + 3;
        var payloadSize = (second - first - 1) * 3 / 4 + 3;
        Span<byte> input = inputSize <= 1024 ? stackalloc byte[1024] : rentedInput = ArrayPool<byte>.Shared.Rent(inputSize);
        Span<byte> decodedHeader = headerSize <= 256 ? stackalloc byte[256] : rentedHeader = ArrayPool<byte>.Shared.Rent(headerSize);
        Span<byte> decodedPayload = payloadSize <= 512 ? stackalloc byte[512] : rentedPayload = ArrayPool<byte>.Shared.Rent(payloadSize);
        Span<byte> actualSignature = stackalloc byte[32];
        Span<byte> expectedSignature = stackalloc byte[32];
        try
        {
            if (!Base64Url.TryDecodeFromChars(signature, actualSignature, out var signatureBytes) || signatureBytes != 32) return false;
            var inputBytes = Encoding.ASCII.GetBytes(encoded[..second], input);
            if (!HMACSHA256.TryHashData(_key, input[..inputBytes], expectedSignature, out var hashBytes) || hashBytes != 32 || !CryptographicOperations.FixedTimeEquals(actualSignature, expectedSignature)) return false;
            if (!Base64Url.TryDecodeFromChars(encoded[..first], decodedHeader, out var headerBytes) || !ReadHeader(decodedHeader[..headerBytes])) return false;
            if (!Base64Url.TryDecodeFromChars(encoded[(first + 1)..second], decodedPayload, out var payloadBytes) || !ReadPayload(decodedPayload[..payloadBytes], out var id)) return false;
            viewer = id;
            token = captureToken ? header[6..] : null;
            return true;
        }
        catch (JsonException) { return false; }
        catch (FormatException) { return false; }
        catch (InvalidOperationException) { return false; }
        finally
        {
            if (rentedInput is not null) ArrayPool<byte>.Shared.Return(rentedInput);
            if (rentedHeader is not null) ArrayPool<byte>.Shared.Return(rentedHeader);
            if (rentedPayload is not null) ArrayPool<byte>.Shared.Return(rentedPayload);
        }
    }

    public static string Issue(long id)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(id);
        var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var payload = Encoding.UTF8.GetBytes(string.Create(CultureInfo.InvariantCulture, $"{{\"sub\":\"{id}\",\"iat\":{now},\"exp\":{now + 30L * 24 * 60 * 60}}}"));
        var input = Header + "." + Base64Url.EncodeToString(payload);
        Span<byte> bytes = stackalloc byte[256];
        var length = Encoding.ASCII.GetBytes(input, bytes);
        Span<byte> signature = stackalloc byte[32];
        HMACSHA256.TryHashData(_key, bytes[..length], signature, out _);
        return input + "." + Base64Url.EncodeToString(signature);
    }

    static bool IsBase64Url(ReadOnlySpan<char> text)
    {
        if (text.IsEmpty) return false;
        foreach (var value in text)
            if (value is not (>= 'A' and <= 'Z') and not (>= 'a' and <= 'z') and not (>= '0' and <= '9') and not '-' and not '_') return false;
        return true;
    }

    static bool ReadHeader(ReadOnlySpan<byte> json)
    {
        var reader = new Utf8JsonReader(json, new JsonReaderOptions { MaxDepth = 16 });
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return false;
        var seen = 0;
        HashSet<string>? other = null;
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            if (reader.TokenType != JsonTokenType.PropertyName) return false;
            if (reader.ValueTextEquals("crit"u8)) return false;
            var field = reader.ValueTextEquals("alg"u8) ? 1 : reader.ValueTextEquals("typ"u8) ? 2 : 0;
            if (field != 0)
            {
                if ((seen & field) != 0) return false;
                seen |= field;
            }
            else if (!(other ??= new(StringComparer.Ordinal)).Add(reader.GetString()!)) return false;
            if (!reader.Read()) return false;
            if (field == 1 && (reader.TokenType != JsonTokenType.String || !reader.ValueTextEquals("HS256"u8))) return false;
            if (field == 2 && reader.TokenType != JsonTokenType.String) return false;
            if (!reader.TrySkip()) return false;
        }
        return (seen & 1) != 0 && reader.TokenType == JsonTokenType.EndObject && !reader.Read();
    }

    static bool ReadPayload(ReadOnlySpan<byte> json, out long id)
    {
        id = 0;
        var reader = new Utf8JsonReader(json, new JsonReaderOptions { MaxDepth = 16 });
        if (!reader.Read() || reader.TokenType != JsonTokenType.StartObject) return false;
        var seen = 0;
        long expires = 0;
        HashSet<string>? other = null;
        Span<byte> subject = stackalloc byte[128];
        while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
        {
            if (reader.TokenType != JsonTokenType.PropertyName) return false;
            var field = reader.ValueTextEquals("sub"u8) ? 1 : reader.ValueTextEquals("exp"u8) ? 2 : reader.ValueTextEquals("iat"u8) ? 4 : 0;
            if (field != 0)
            {
                if ((seen & field) != 0) return false;
                seen |= field;
            }
            else if (!(other ??= new(StringComparer.Ordinal)).Add(reader.GetString()!)) return false;
            if (!reader.Read()) return false;
            if (field == 1)
            {
                if (reader.TokenType != JsonTokenType.String) return false;
                if (reader.ValueSpan.Length > 114) return false;
                var length = reader.CopyString(subject);
                if (length == 0) return false;
                foreach (var value in subject[..length]) if (value is < (byte)'0' or > (byte)'9') return false;
                if (!Utf8Parser.TryParse(subject[..length], out id, out var consumed) || consumed != length || id <= 0) return false;
            }
            else if (field == 2)
            {
                if (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt64(out expires)) return false;
            }
            else if (field == 4)
            {
                if (reader.TokenType != JsonTokenType.Number || !reader.TryGetInt64(out var issued) || issued < 0) return false;
            }
            if (!reader.TrySkip()) return false;
        }
        return (seen & 3) == 3 && expires > DateTimeOffset.UtcNow.ToUnixTimeSeconds() && reader.TokenType == JsonTokenType.EndObject && !reader.Read();
    }
}
