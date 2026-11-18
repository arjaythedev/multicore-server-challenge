using System.Buffers;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;

namespace Conduit;

/// <summary>Request/response helpers: JSON bodies, error shape, query-string and body parsing.</summary>
internal static class Http
{
    private static readonly JsonWriterOptions WriterOptions = new()
    {
        SkipValidation = true,
        Indented = false,
    };

    // One response buffer and one JSON writer per thread, reused by every response that thread writes. This is safe
    // because Json() fills and copies the buffer in one synchronous call: nothing awaits while the buffer is in use.
    [ThreadStatic]
    private static ArrayBufferWriter<byte>? t_buffer;

    [ThreadStatic]
    private static Utf8JsonWriter? t_writer;
    private const int InitialBufferBytes = 8 * 1024;
    private const int MaxRetainedBufferBytes = 256 * 1024; // a thread that wrote a huge response gives its buffer back

    private static readonly ConcurrentDictionary<string, byte[]> ErrorBodies = new();

    /// <summary>
    /// Writes <paramref name="write"/>'s JSON as the response. It is built in a reused buffer first, so the response
    /// has a Content-Length, then copied into Kestrel's output pipe, which sends it when the request ends.
    /// </summary>
    internal static async Task Json(HttpContext ctx, int status, Action<Utf8JsonWriter> write)
    {
        var buf = t_buffer ??= new ArrayBufferWriter<byte>(InitialBufferBytes);
        buf.ResetWrittenCount();
        var writer = t_writer ??= new Utf8JsonWriter(buf, WriterOptions);
        writer.Reset(buf);
        write(writer);
        writer.Flush();

        var res = ctx.Response;
        res.StatusCode = status;
        res.ContentType = "application/json";
        res.ContentLength = buf.WrittenCount;
        res.BodyWriter.Write(buf.WrittenSpan);

        if (buf.Capacity > MaxRetainedBufferBytes)
        {
            t_buffer = null;
            t_writer = null;
        }

        await res.BodyWriter.FlushAsync(ctx.RequestAborted);
    }

#if DEBUG
    /// <summary>HttpContext.Items key under which Error leaves its message, for the request log (Api.Handle).</summary>
    internal const string ErrorItem = "conduit.error";
#endif

    internal static async Task Error(HttpContext ctx, int status, string message)
    {
#if DEBUG
        ctx.Items[ErrorItem] = message;
#endif
        // The messages are our own fixed strings, so after the first use of each one this is a lookup, no JSON.
        if (!ErrorBodies.TryGetValue(message, out var body))
        {
            body = BuildErrorBody(message);
            if (ErrorBodies.Count < 256)
                ErrorBodies.TryAdd(message, body); // only a guard against a message that varies
        }

        var res = ctx.Response;
        res.StatusCode = status;
        res.ContentType = "application/json";
        res.ContentLength = body.Length;
        res.BodyWriter.Write(body);

        await res.BodyWriter.FlushAsync(ctx.RequestAborted);
    }

    internal static Task NoContent(HttpContext ctx)
    {
        ctx.Response.StatusCode = 204;
        return Task.CompletedTask;
    }

    // ---------- parsing ----------

    /// <summary>Only ASCII digits (no sign, no spaces) that fit in an int64.</summary>
    internal static bool ParseUint(string? s, out long n)
    {
        n = 0;

        if (string.IsNullOrEmpty(s) || s.AsSpan().IndexOfAnyExceptInRange('0', '9') >= 0)
            return false;

        return long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n);
    }

    // ---------- request bodies ----------

    /// <summary>Parses the body as a JSON object and returns the object under <paramref name="key"/>; invalid if it is not one.</summary>
    internal static async ValueTask<JsonBody> ReadWrapper(HttpContext ctx, string key)
    {
        JsonDocument doc;
        try
        {
            doc = await JsonDocument
                .ParseAsync(ctx.Request.Body, cancellationToken: ctx.RequestAborted)
                .ConfigureAwait(false);
        }
        catch (JsonException)
        {
            return default;
        }

        if (
            doc.RootElement.ValueKind == JsonValueKind.Object
            && doc.RootElement.TryGetProperty(key, out var inner)
            && inner.ValueKind == JsonValueKind.Object
        )
        {
            return new JsonBody(doc, inner);
        }

        doc.Dispose();
        return default;
    }

    /// <summary>Absent or null gives true with a null value; a string gives its value; anything else (or "" when nonEmpty) is false.</summary>
    internal static bool OptString(
        JsonElement obj,
        ReadOnlySpan<byte> key,
        bool nonEmpty,
        out string? value
    )
    {
        value = null;

        if (!obj.TryGetProperty(key, out var el) || el.ValueKind == JsonValueKind.Null)
        {
            return true;
        }

        if (el.ValueKind != JsonValueKind.String)
            return false;

        string s;
        try
        {
            s = el.GetString()!;
        }
        catch (InvalidOperationException)
        {
            return false; // text GetString cannot decode, such as an unpaired surrogate escape ("\ud800")
        }

        if (nonEmpty && s.Length == 0)
            return false;

        value = s;
        return true;
    }

    /// <summary>Must be present and a non-empty string.</summary>
    internal static bool ReqString(JsonElement obj, ReadOnlySpan<byte> key, out string value)
    {
        if (OptString(obj, key, true, out var v) && v != null)
        {
            value = v;
            return true;
        }
        value = "";
        return false;
    }

    private static byte[] BuildErrorBody(string message)
    {
        var buf = new ArrayBufferWriter<byte>(64 + message.Length);
        using (var w = new Utf8JsonWriter(buf))
        {
            w.WriteStartObject();
            w.WriteStartObject("errors");
            w.WriteStartArray("body");
            w.WriteStringValue(message);
            w.WriteEndArray();
            w.WriteEndObject();
            w.WriteEndObject();
        }
        return buf.WrittenSpan.ToArray();
    }

    /// <summary>
    /// A parsed request body: <see cref="Element"/> is the object under the wrapper key. It lives in the JSON document
    /// this struct owns, so dispose it (<c>using var</c>) once you have read what you need; strings you took from it
    /// stay valid. Copying the element out instead (JsonElement.Clone) would allocate a second copy of the JSON.
    /// </summary>
    internal readonly struct JsonBody : IDisposable
    {
        private readonly JsonDocument? _doc;

        internal JsonBody(JsonDocument doc, JsonElement element)
        {
            _doc = doc;
            Element = element;
        }

        internal JsonElement Element { get; }

        /// <summary>False if the body was not a JSON object holding an object under the wrapper key.</summary>
        internal bool IsValid => _doc is not null;

        public void Dispose() => _doc?.Dispose();
    }
}
