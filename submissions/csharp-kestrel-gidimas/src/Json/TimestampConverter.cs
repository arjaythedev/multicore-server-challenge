using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Conduit.Json;

/// <summary>
/// SPEC.md timestamps: RFC 3339 in UTC with exactly three fractional digits, truncated rather than rounded
/// ("2025-04-01T12:00:00.000Z"). The default converter writes up to seven digits.
/// </summary>
public sealed class TimestampConverter : JsonConverter<DateTime>
{
    private const string Format = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'";

    public override DateTime Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        DateTime.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal);

    public override void Write(Utf8JsonWriter writer, DateTime value, JsonSerializerOptions options)
    {
        var utc = value.Kind == DateTimeKind.Utc ? value : value.ToUniversalTime();
        // The "fff" specifier truncates, so no rounding into the next millisecond.
        writer.WriteStringValue(utc.ToString(Format, CultureInfo.InvariantCulture));
    }
}
