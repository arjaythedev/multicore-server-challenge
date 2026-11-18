using System.Globalization;

namespace Conduit.Endpoints;

/// <summary>The limit (1-100, default 20) and offset (>= 0, default 0) query parameters.</summary>
public static class Paging
{
    /// <summary>
    /// False when either value is present but invalid. Digits only: SPEC.md rejects "+5", " 5" and "1.5",
    /// which int.Parse with default styles would accept or which the framework's binder would answer with 400.
    /// </summary>
    public static bool TryRead(HttpRequest request, out int limit, out int offset)
    {
        limit = 20;
        offset = 0;
        return TryReadOne(request, "limit", ref limit, min: 1, max: 100)
            && TryReadOne(request, "offset", ref offset, min: 0, max: int.MaxValue);
    }

    private static bool TryReadOne(HttpRequest request, string name, ref int value, int min, int max)
    {
        if (!request.Query.TryGetValue(name, out var raw))
        {
            return true;
        }

        if (!int.TryParse(raw.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) || parsed < min || parsed > max)
        {
            return false;
        }

        value = parsed;
        return true;
    }
}
