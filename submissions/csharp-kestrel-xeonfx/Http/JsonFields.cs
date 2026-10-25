using System;
using System.Text.Json;

namespace Conduit.Http;

/// <summary>Field values written the way the spec formats them.</summary>
public static class JsonFields
{
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
}
