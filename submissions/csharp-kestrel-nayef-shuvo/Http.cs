using System.Buffers;
using System.Globalization;
using System.Text.Json;

namespace Conduit;

/// <summary>Request/response helpers: JSON bodies, error shape, query-string and body parsing.</summary>
internal static class Http
{
    internal static async Task Json(HttpContext ctx, int status, Action<Utf8JsonWriter> write)
    {
        var buf = new ArrayBufferWriter<byte>(1024);
        using (var w = new Utf8JsonWriter(buf)) write(w);
        var res = ctx.Response;
        res.StatusCode = status;
        res.ContentType = "application/json";
        res.ContentLength = buf.WrittenCount;
        await res.Body.WriteAsync(buf.WrittenMemory);
    }

#if DEBUG
    /// <summary>HttpContext.Items key under which Error leaves its message, for the request log (Api.Handle).</summary>
    internal const string ErrorItem = "conduit.error";
#endif

    internal static Task Error(HttpContext ctx, int status, string message)
    {
#if DEBUG
        ctx.Items[ErrorItem] = message;
#endif
        return Json(ctx, status, w =>
        {
            w.WriteStartObject();
            w.WriteStartObject("errors");
            w.WriteStartArray("body");
            w.WriteStringValue(message);
            w.WriteEndArray();
            w.WriteEndObject();
            w.WriteEndObject();
        });
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
        if (string.IsNullOrEmpty(s)) return false;
        foreach (var c in s)
            if (c < '0' || c > '9') return false;
        return long.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out n);
    }

    // ---------- request bodies ----------

    /// <summary>Parses the body as a JSON object and returns the object under <paramref name="key"/>, or null if invalid.</summary>
    internal static async Task<JsonElement?> ReadWrapper(HttpContext ctx, string key)
    {
        try
        {
            using var doc = await JsonDocument.ParseAsync(ctx.Request.Body);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return null;
            if (!doc.RootElement.TryGetProperty(key, out var inner) || inner.ValueKind != JsonValueKind.Object) return null;
            return inner.Clone();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Absent or null gives true with a null value; a string gives its value; anything else (or "" when nonEmpty) is false.</summary>
    internal static bool OptString(JsonElement obj, string key, bool nonEmpty, out string? value)
    {
        value = null;
        if (!obj.TryGetProperty(key, out var el) || el.ValueKind == JsonValueKind.Null) return true;
        if (el.ValueKind != JsonValueKind.String) return false;
        string s;
        try { s = el.GetString()!; }
        catch (InvalidOperationException) { return false; }
        if (nonEmpty && s.Length == 0) return false;
        value = s;
        return true;
    }

    /// <summary>Must be present and a non-empty string.</summary>
    internal static bool ReqString(JsonElement obj, string key, out string value)
    {
        if (OptString(obj, key, true, out var v) && v != null)
        {
            value = v;
            return true;
        }
        value = "";
        return false;
    }
}
