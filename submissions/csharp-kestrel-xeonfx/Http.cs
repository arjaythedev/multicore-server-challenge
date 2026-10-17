using System;
using System.Buffers;
using System.Collections.Concurrent;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;
using Npgsql;

namespace Conduit;

/// <summary>A pooled response buffer with its JSON writer. Responses are buffered so they carry a Content-Length.</summary>
public sealed class JsonOut
{
    static readonly ConcurrentQueue<JsonOut> Pool = new();
    static readonly JsonWriterOptions Options = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, // escapes only what JSON requires; UTF-8 passes through
        SkipValidation = true,
    };

    readonly ArrayBufferWriter<byte> _buf = new(16 * 1024);
    public readonly Utf8JsonWriter W;

    JsonOut() => W = new Utf8JsonWriter(_buf, Options);

    public static JsonOut Rent() => Pool.TryDequeue(out var j) ? j : new JsonOut();

    public ReadOnlySpan<byte> Written
    {
        get { W.Flush(); return _buf.WrittenSpan; }
    }

    public void Return()
    {
        W.Reset(_buf);
        _buf.ResetWrittenCount();
        if (_buf.Capacity <= 1 << 20) Pool.Enqueue(this); // let a rare huge response's buffer go
    }
}

/// <summary>Property names, encoded once.</summary>
public static class Names
{
    public static readonly JsonEncodedText User = JsonEncodedText.Encode("user");
    public static readonly JsonEncodedText Profile = JsonEncodedText.Encode("profile");
    public static readonly JsonEncodedText Article = JsonEncodedText.Encode("article");
    public static readonly JsonEncodedText Articles = JsonEncodedText.Encode("articles");
    public static readonly JsonEncodedText ArticlesCount = JsonEncodedText.Encode("articlesCount");
    public static readonly JsonEncodedText Comment = JsonEncodedText.Encode("comment");
    public static readonly JsonEncodedText Comments = JsonEncodedText.Encode("comments");
    public static readonly JsonEncodedText Tags = JsonEncodedText.Encode("tags");
    public static readonly JsonEncodedText Email = JsonEncodedText.Encode("email");
    public static readonly JsonEncodedText Token = JsonEncodedText.Encode("token");
    public static readonly JsonEncodedText Username = JsonEncodedText.Encode("username");
    public static readonly JsonEncodedText Bio = JsonEncodedText.Encode("bio");
    public static readonly JsonEncodedText Image = JsonEncodedText.Encode("image");
    public static readonly JsonEncodedText Following = JsonEncodedText.Encode("following");
    public static readonly JsonEncodedText Slug = JsonEncodedText.Encode("slug");
    public static readonly JsonEncodedText Title = JsonEncodedText.Encode("title");
    public static readonly JsonEncodedText Description = JsonEncodedText.Encode("description");
    public static readonly JsonEncodedText Body = JsonEncodedText.Encode("body");
    public static readonly JsonEncodedText TagList = JsonEncodedText.Encode("tagList");
    public static readonly JsonEncodedText CreatedAt = JsonEncodedText.Encode("createdAt");
    public static readonly JsonEncodedText UpdatedAt = JsonEncodedText.Encode("updatedAt");
    public static readonly JsonEncodedText Favorited = JsonEncodedText.Encode("favorited");
    public static readonly JsonEncodedText FavoritesCount = JsonEncodedText.Encode("favoritesCount");
    public static readonly JsonEncodedText Author = JsonEncodedText.Encode("author");
    public static readonly JsonEncodedText Id = JsonEncodedText.Encode("id");
    public static readonly JsonEncodedText Errors = JsonEncodedText.Encode("errors");
}

public static class Http
{
    const string ContentType = "application/json";

    /// <summary>Writes the buffered JSON as the whole response and returns the buffer to the pool. Kestrel sends it
    /// when the handler returns.</summary>
    public static Task Send(HttpContext ctx, int status, JsonOut j)
    {
        var res = ctx.Response;
        res.StatusCode = status;
        res.ContentType = ContentType;
        var body = j.Written;
        res.ContentLength = body.Length;
        res.BodyWriter.Write(body);
        j.Return();
        return Task.CompletedTask;
    }

    public static Task NoContent(HttpContext ctx)
    {
        ctx.Response.StatusCode = StatusCodes.Status204NoContent;
        return Task.CompletedTask;
    }

    public static Task Error(HttpContext ctx, int status, string message)
    {
        var j = JsonOut.Rent();
        var w = j.W;
        w.WriteStartObject();
        w.WriteStartObject(Names.Errors);
        w.WriteStartArray(Names.Body);
        w.WriteStringValue(message);
        w.WriteEndArray();
        w.WriteEndObject();
        w.WriteEndObject();
        return Send(ctx, status, j);
    }

    public static Task NotFound(HttpContext ctx) => Error(ctx, 404, "not found");
    public static Task Unauthorized(HttpContext ctx) => Error(ctx, 401, "unauthorized");
    public static Task Unprocessable(HttpContext ctx, string message) => Error(ctx, 422, message);

    /// <summary>RFC 3339 UTC with exactly 3 fractional digits, truncated: 2025-04-01T12:00:00.000Z.</summary>
    public static void WriteTimestamp(Utf8JsonWriter w, JsonEncodedText name, DateTime t)
    {
        Span<byte> b = stackalloc byte[24];
        int y = t.Year, mo = t.Month, d = t.Day, h = t.Hour, mi = t.Minute, s = t.Second, ms = t.Millisecond;
        b[0] = (byte)('0' + y / 1000); b[1] = (byte)('0' + y / 100 % 10); b[2] = (byte)('0' + y / 10 % 10); b[3] = (byte)('0' + y % 10);
        b[4] = (byte)'-'; b[5] = (byte)('0' + mo / 10); b[6] = (byte)('0' + mo % 10);
        b[7] = (byte)'-'; b[8] = (byte)('0' + d / 10); b[9] = (byte)('0' + d % 10);
        b[10] = (byte)'T'; b[11] = (byte)('0' + h / 10); b[12] = (byte)('0' + h % 10);
        b[13] = (byte)':'; b[14] = (byte)('0' + mi / 10); b[15] = (byte)('0' + mi % 10);
        b[16] = (byte)':'; b[17] = (byte)('0' + s / 10); b[18] = (byte)('0' + s % 10);
        b[19] = (byte)'.'; b[20] = (byte)('0' + ms / 100); b[21] = (byte)('0' + ms / 10 % 10); b[22] = (byte)('0' + ms % 10);
        b[23] = (byte)'Z';
        w.WriteString(name, b);
    }

    public static void WriteNullableString(Utf8JsonWriter w, JsonEncodedText name, string? value)
    {
        if (value is null) w.WriteNull(name);
        else w.WriteString(name, value);
    }

    public static void WriteNullableString(Utf8JsonWriter w, JsonEncodedText name, NpgsqlDataReader r, int c)
    {
        if (r.IsDBNull(c)) w.WriteNull(name);
        else w.WriteString(name, r.GetString(c));
    }

    /// <summary>A profile's username, bio and image from columns <paramref name="c"/> to c + 2, in order.</summary>
    public static void WritePerson(Utf8JsonWriter w, NpgsqlDataReader r, int c)
    {
        w.WriteString(Names.Username, r.GetString(c));
        WriteNullableString(w, Names.Bio, r, c + 1);
        WriteNullableString(w, Names.Image, r, c + 2);
    }
}

/// <summary>Query strings, parsed the way Go's url.Values.Get does: first occurrence wins, '+' is a space.</summary>
public static class Query
{
    /// <summary>The decoded value of the first <paramref name="key"/> parameter, or null when it isn't present.</summary>
    public static string? Get(QueryString query, string key)
    {
        string? qs = query.Value;
        if (string.IsNullOrEmpty(qs)) return null;
        ReadOnlySpan<char> s = qs.AsSpan(qs[0] == '?' ? 1 : 0);
        while (!s.IsEmpty)
        {
            int amp = s.IndexOf('&');
            ReadOnlySpan<char> pair = amp < 0 ? s : s[..amp];
            s = amp < 0 ? default : s[(amp + 1)..];
            if (pair.IsEmpty || pair.Contains(';')) continue; // Go rejects (skips) pairs with a semicolon
            int eq = pair.IndexOf('=');
            ReadOnlySpan<char> k = eq < 0 ? pair : pair[..eq];
            ReadOnlySpan<char> v = eq < 0 ? default : pair[(eq + 1)..];
            if (k.IndexOfAny('%', '+') < 0 ? !k.SequenceEqual(key) : !TryDecode(k, out string? dk) || dk != key) continue;
            if (!TryDecode(v, out string? dv)) continue; // an invalid escape drops the pair, as in Go
            return dv;
        }
        return null;
    }

    static bool TryDecode(ReadOnlySpan<char> s, out string? result)
    {
        if (s.IndexOfAny('%', '+') < 0)
        {
            result = s.ToString();
            return true;
        }
        byte[] rented = ArrayPool<byte>.Shared.Rent(s.Length * 3);
        try
        {
            int n = 0;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '+') rented[n++] = (byte)' ';
                else if (c == '%')
                {
                    if (i + 2 >= s.Length) { result = null; return false; }
                    int hi = Hex(s[i + 1]), lo = Hex(s[i + 2]);
                    if (hi < 0 || lo < 0) { result = null; return false; }
                    rented[n++] = (byte)(hi << 4 | lo);
                    i += 2;
                }
                else if (c < 0x80) rented[n++] = (byte)c;
                else
                {
                    int len = char.IsHighSurrogate(c) && i + 1 < s.Length ? 2 : 1;
                    n += Encoding.UTF8.GetBytes(s.Slice(i, len), rented.AsSpan(n));
                    i += len - 1;
                }
            }
            result = Encoding.UTF8.GetString(rented, 0, n);
            return true;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(rented);
        }
    }

    static int Hex(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };

    /// <summary>ASCII digits only (no sign, no spaces) that fit in an Int64.</summary>
    public static bool TryParseUint(ReadOnlySpan<char> s, out long value)
    {
        value = 0;
        if (s.IsEmpty) return false;
        foreach (char c in s)
        {
            if (c < '0' || c > '9') return false;
            long d = c - '0';
            if (value > (long.MaxValue - d) / 10) return false;
            value = value * 10 + d;
        }
        return true;
    }

    /// <summary>limit (default 20, 1..100) and offset (default 0, &gt;= 0). A parameter that is present, even empty, must be valid.</summary>
    public static bool TryPage(QueryString query, out long limit, out long offset)
    {
        limit = 20;
        offset = 0;
        string? l = Get(query, "limit");
        if (l is not null && (!TryParseUint(l, out limit) || limit < 1 || limit > 100)) return false;
        string? o = Get(query, "offset");
        if (o is not null && !TryParseUint(o, out offset)) return false;
        return true;
    }
}

/// <summary>Request bodies: {"wrapper": {...}} with case-sensitive keys. Anything malformed is a 422.</summary>
public static class Body
{
    public static async Task<JsonDocument?> ReadAsync(HttpContext ctx)
    {
        try
        {
            return await JsonDocument.ParseAsync(ctx.Request.Body);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The object under <paramref name="key"/>, if the body is an object holding one.</summary>
    public static bool TryWrapper(JsonDocument? doc, string key, out JsonElement obj)
    {
        obj = default;
        return doc is not null
            && doc.RootElement.ValueKind == JsonValueKind.Object
            && doc.RootElement.TryGetProperty(key, out obj)
            && obj.ValueKind == JsonValueKind.Object;
    }

    /// <summary>Absent or null gives null; a string gives the string; anything else (or "" when nonEmpty) is invalid.</summary>
    public static bool TryOptString(JsonElement obj, string key, bool nonEmpty, out string? value)
    {
        value = null;
        if (!obj.TryGetProperty(key, out var e) || e.ValueKind == JsonValueKind.Null) return true;
        if (e.ValueKind != JsonValueKind.String) return false;
        value = e.GetString()!;
        return !(nonEmpty && value.Length == 0);
    }

    /// <summary>A present, non-empty string.</summary>
    public static bool TryReqString(JsonElement obj, string key, out string value)
    {
        bool ok = TryOptString(obj, key, true, out string? v) && v is not null;
        value = v ?? "";
        return ok;
    }
}
