using System.Buffers;
using System.Buffers.Text;
using System.Collections.Concurrent;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace Conduit;

/// <summary>A reusable response buffer with a JSON writer on it (pooled, so a request allocates no new buffers).</summary>
sealed class Out
{
    static readonly ConcurrentQueue<Out> pool = new();
    static readonly JsonWriterOptions options = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, SkipValidation = true };

    public readonly ArrayBufferWriter<byte> Buf = new(4096);
    public readonly Utf8JsonWriter W;

    Out() => W = new Utf8JsonWriter(Buf, options);

    /// <summary>Every response body is a JSON object: Rent opens it and Finish closes it.</summary>
    public static Out Rent()
    {
        var o = pool.TryDequeue(out var cached) ? cached : new Out();
        o.W.WriteStartObject();
        return o;
    }

    public ReadOnlySpan<byte> Finish()
    {
        W.WriteEndObject();
        W.Flush();
        return Buf.WrittenSpan;
    }

    public void Return()
    {
        if (Buf.Capacity > (1 << 18) || pool.Count > 1024) return;
        Buf.ResetWrittenCount();
        W.Reset(Buf);
        pool.Enqueue(this);
    }
}

/// <summary>Pre-encoded property names.</summary>
static class P
{
    static JsonEncodedText E(string s) => JsonEncodedText.Encode(s);

    public static readonly JsonEncodedText User = E("user"), Email = E("email"), Token = E("token"), Username = E("username"), Bio = E("bio"), Image = E("image"),
        Following = E("following"), Profile = E("profile"), Article = E("article"), Articles = E("articles"), ArticlesCount = E("articlesCount"),
        Slug = E("slug"), Title = E("title"), Description = E("description"), Body = E("body"), TagList = E("tagList"), CreatedAt = E("createdAt"),
        UpdatedAt = E("updatedAt"), Favorited = E("favorited"), FavoritesCount = E("favoritesCount"), Author = E("author"), Id = E("id"),
        Comment = E("comment"), Comments = E("comments"), Tags = E("tags");
}

static class JsonExt
{
    /// <summary>RFC 3339 UTC with exactly three fractional digits, truncated (not rounded).</summary>
    public static void WriteTimestamp(this Utf8JsonWriter w, JsonEncodedText name, DateTime dt)
    {
        w.WritePropertyName(name);
        w.WriteTimestampValue(dt);
    }

    public static void WriteTimestampValue(this Utf8JsonWriter w, DateTime dt)
    {
        if (dt.Kind != DateTimeKind.Utc) dt = dt.ToUniversalTime();
        // "O" gives 7 fractional digits; keep the first 3 (truncating, like the spec's millisecond format) and close with Z".
        Span<byte> b = stackalloc byte[29];
        b[0] = (byte)'"';
        Utf8Formatter.TryFormat(dt, b[1..], out _, new StandardFormat('O'));
        b[24] = (byte)'Z';
        b[25] = (byte)'"';
        w.WriteRawValue(b[..26], skipInputValidation: true);
    }
}
