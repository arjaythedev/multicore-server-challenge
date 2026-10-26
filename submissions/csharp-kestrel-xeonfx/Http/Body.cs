using System.Text.Json;
using System.Threading.Tasks;
using Microsoft.AspNetCore.Http;

namespace Conduit.Http;

/// <summary>Request bodies: {"wrapper": {...}} with case-sensitive keys. Anything malformed is a 422.</summary>
public static class Body
{
    public static async Task<JsonDocument?> ReadAsync(HttpContext ctx)
    {
        try
        {
            return await JsonDocument.ParseAsync(ctx.Request.Body, cancellationToken: ctx.RequestAborted);
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
