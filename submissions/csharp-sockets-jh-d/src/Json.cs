using System.Buffers;
using System.Buffers.Binary;
using System.Buffers.Text;
using System.Text;
using System.Text.Json;

namespace Conduit;

// JSON property names, encoded once (the writer then copies them without checking them on every use)
static class N
{
    public static readonly JsonEncodedText article = JsonEncodedText.Encode("article");
    public static readonly JsonEncodedText articles = JsonEncodedText.Encode("articles");
    public static readonly JsonEncodedText articlesCount = JsonEncodedText.Encode("articlesCount");
    public static readonly JsonEncodedText author = JsonEncodedText.Encode("author");
    public static readonly JsonEncodedText bio = JsonEncodedText.Encode("bio");
    public static readonly JsonEncodedText body = JsonEncodedText.Encode("body");
    public static readonly JsonEncodedText comment = JsonEncodedText.Encode("comment");
    public static readonly JsonEncodedText comments = JsonEncodedText.Encode("comments");
    public static readonly JsonEncodedText createdAt = JsonEncodedText.Encode("createdAt");
    public static readonly JsonEncodedText description = JsonEncodedText.Encode("description");
    public static readonly JsonEncodedText email = JsonEncodedText.Encode("email");
    public static readonly JsonEncodedText errors = JsonEncodedText.Encode("errors");
    public static readonly JsonEncodedText favorited = JsonEncodedText.Encode("favorited");
    public static readonly JsonEncodedText favoritesCount = JsonEncodedText.Encode("favoritesCount");
    public static readonly JsonEncodedText following = JsonEncodedText.Encode("following");
    public static readonly JsonEncodedText id = JsonEncodedText.Encode("id");
    public static readonly JsonEncodedText image = JsonEncodedText.Encode("image");
    public static readonly JsonEncodedText profile = JsonEncodedText.Encode("profile");
    public static readonly JsonEncodedText slug = JsonEncodedText.Encode("slug");
    public static readonly JsonEncodedText tagList = JsonEncodedText.Encode("tagList");
    public static readonly JsonEncodedText tags = JsonEncodedText.Encode("tags");
    public static readonly JsonEncodedText title = JsonEncodedText.Encode("title");
    public static readonly JsonEncodedText token = JsonEncodedText.Encode("token");
    public static readonly JsonEncodedText updatedAt = JsonEncodedText.Encode("updatedAt");
    public static readonly JsonEncodedText user = JsonEncodedText.Encode("user");
    public static readonly JsonEncodedText username = JsonEncodedText.Encode("username");
}

// Response JSON, written straight from Postgres's binary rows into the request's buffer. Text columns are UTF-8 in
// the row and are copied as UTF-8 (the writer escapes as for strings): no strings, no transcoding.
static class Json
{
    public static void Text(Utf8JsonWriter w, JsonEncodedText name, ref PgRow r, int i) => w.WriteString(name, r.Bytes(i));

    public static void NullableText(Utf8JsonWriter w, JsonEncodedText name, ref PgRow r, int i)
    {
        if (r.IsNull(i)) w.WriteNull(name);
        else w.WriteString(name, r.Bytes(i));
    }

    // "tagList": a text[] column decoded from its binary form (ndim, has-null flag, element type, then per dimension
    // size and lower bound, then per element a length (-1 = NULL) and the UTF-8 bytes), names written as UTF-8.
    // Sorted here by UTF-8 bytes when the database orders text by code point (Sql.AppSortsTags), NULLs last as in
    // ORDER BY; otherwise the statement sorted it.
    public static void TagList(Utf8JsonWriter w, ref PgRow r, int i)
    {
        w.WritePropertyName(N.tagList);
        w.WriteStartArray();
        var b = r.Bytes(i);
        if (b.Length >= 12 && BinaryPrimitives.ReadInt32BigEndian(b) == 1)
        {
            int count = BinaryPrimitives.ReadInt32BigEndian(b[12..]);
            Span<(int Off, int Len)> items = count <= 64 ? stackalloc (int, int)[count] : new (int, int)[count];
            int pos = 20;
            for (int k = 0; k < count; k++)
            {
                int len = BinaryPrimitives.ReadInt32BigEndian(b[pos..]);
                pos += 4;
                items[k] = (pos, len);
                if (len > 0) pos += len;
            }
            if (Sql.AppSortsTags)
                for (int k = 1; k < count; k++) // insertion sort: a handful of tags
                    for (int j = k; j > 0 && Greater(b, items[j - 1], items[j]); j--)
                        (items[j - 1], items[j]) = (items[j], items[j - 1]);
            foreach (var (off, len) in items)
            {
                if (len < 0) w.WriteNullValue();
                else w.WriteStringValue(b.Slice(off, len));
            }
        }
        w.WriteEndArray();

        static bool Greater(ReadOnlySpan<byte> b, (int Off, int Len) x, (int Off, int Len) y)
        {
            if (x.Len < 0) return y.Len >= 0;
            if (y.Len < 0) return false;
            return b.Slice(x.Off, x.Len).SequenceCompareTo(b.Slice(y.Off, y.Len)) > 0;
        }
    }

    // a text[] in its binary form (see TagList), elements in the array's order
    public static void TextArray(Utf8JsonWriter w, ReadOnlySpan<byte> b)
    {
        w.WriteStartArray();
        if (b.Length >= 12 && BinaryPrimitives.ReadInt32BigEndian(b) == 1)
        {
            int count = BinaryPrimitives.ReadInt32BigEndian(b[12..]);
            int pos = 20;
            for (int k = 0; k < count; k++)
            {
                int len = BinaryPrimitives.ReadInt32BigEndian(b[pos..]);
                pos += 4;
                if (len < 0) { w.WriteNullValue(); continue; }
                w.WriteStringValue(b.Slice(pos, len));
                pos += len;
            }
        }
        w.WriteEndArray();
    }

    // Timestamps as RFC 3339 in UTC with exactly three fractional digits, truncated (2024-05-01T12:34:56.789Z).
    // Postgres sends microseconds since 2000-01-01 UTC. The runtime's round-trip format ("O") writes
    // yyyy-MM-ddTHH:mm:ss.fffffffZ for a UTC DateTime; its first 23 bytes are the value down to the millisecond.
    static readonly long Epoch2000 = new DateTime(2000, 1, 1, 0, 0, 0, DateTimeKind.Utc).Ticks;
    static readonly StandardFormat RoundTrip = new('O');

    public static void Time(Utf8JsonWriter writer, JsonEncodedText property, long micros)
    {
        Span<byte> iso = stackalloc byte[40];
        Utf8Formatter.TryFormat(new DateTime(Epoch2000 + micros * 10, DateTimeKind.Utc), iso, out _, RoundTrip);
        iso[23] = (byte)'Z'; // cut after the milliseconds
        writer.WriteString(property, iso[..24]);
    }

    // Profile from (username, bio, image, following) at columns i..i+3
    public static void Profile(Utf8JsonWriter w, ref PgRow r, int i, int following = -1)
    {
        w.WriteStartObject();
        Text(w, N.username, ref r, i);
        NullableText(w, N.bio, ref r, i + 1);
        NullableText(w, N.image, ref r, i + 2);
        w.WriteBoolean(N.following, following >= 0 ? following == 1 : r.Bool(i + 3));
        w.WriteEndObject();
    }

    // Article from column o: id, slug, title, description, [body], created_at, updated_at, tag_list,
    // favorites_count, favorited, username, bio, image, following
    public static void Article(Utf8JsonWriter w, ref PgRow r, int o, bool full)
    {
        w.WriteStartObject();
        Text(w, N.slug, ref r, o + 1);
        Text(w, N.title, ref r, o + 2);
        Text(w, N.description, ref r, o + 3);
        int k = o + 4;
        if (full) Text(w, N.body, ref r, k++);
        Time(w, N.createdAt, r.Micros(k));
        Time(w, N.updatedAt, r.Micros(k + 1));
        TagList(w, ref r, k + 2);
        w.WriteNumber(N.favoritesCount, r.Int8(k + 3));
        w.WriteBoolean(N.favorited, r.Bool(k + 4));
        w.WritePropertyName(N.author);
        Profile(w, ref r, k + 5);
        w.WriteEndObject();
    }

    // {"user": {...}} from (id, username, email, bio, image) at column o
    public static void User(Utf8JsonWriter w, ref PgRow r, int o, ReadOnlySpan<byte> token)
    {
        w.WriteStartObject();
        w.WritePropertyName(N.user);
        w.WriteStartObject();
        Text(w, N.email, ref r, o + 2);
        w.WriteString(N.token, token);
        Text(w, N.username, ref r, o + 1);
        NullableText(w, N.bio, ref r, o + 3);
        NullableText(w, N.image, ref r, o + 4);
        w.WriteEndObject();
        w.WriteEndObject();
    }
}

// A parsed request body {"<wrapper>": {...}}. Fields are absent, null, a string or something else (bad).
sealed class Body : IDisposable
{
    public enum Kind { Absent, Null, String, Bad }

    JsonDocument _doc;
    JsonElement _obj;

    public static Body Parse(byte[] bytes, string wrapper)
    {
        if (bytes == null) return null;
        JsonDocument doc;
        try { doc = JsonDocument.Parse(bytes); }
        catch (JsonException) { return null; }
        if (doc.RootElement.ValueKind != JsonValueKind.Object ||
            !doc.RootElement.TryGetProperty(wrapper, out var obj) || obj.ValueKind != JsonValueKind.Object)
        {
            doc.Dispose();
            return null;
        }
        return new Body { _doc = doc, _obj = obj };
    }

    public Kind Get(string name, out string value)
    {
        value = null;
        if (!_obj.TryGetProperty(name, out var e)) return Kind.Absent;
        switch (e.ValueKind)
        {
            case JsonValueKind.Null: return Kind.Null;
            case JsonValueKind.String: value = e.GetString(); return Kind.String;
            default: return Kind.Bad;
        }
    }

    // a required non-empty string
    public bool Required(string name, out string value) => Get(name, out value) == Kind.String && value.Length > 0;

    // an optional field: absent or null -> null; a string must be non-empty unless allowEmpty
    public bool Optional(string name, bool allowEmpty, out string value)
    {
        var k = Get(name, out value);
        return k switch
        {
            Kind.Absent or Kind.Null => true,
            Kind.String => allowEmpty || value.Length > 0,
            _ => false,
        };
    }

    // tagList: absent or null -> empty; otherwise an array of non-empty strings
    public bool Tags(out string[] tags)
    {
        tags = [];
        if (!_obj.TryGetProperty("tagList", out var e) || e.ValueKind == JsonValueKind.Null) return true;
        if (e.ValueKind != JsonValueKind.Array) return false;
        var list = new string[e.GetArrayLength()];
        int i = 0;
        foreach (var t in e.EnumerateArray())
        {
            if (t.ValueKind != JsonValueKind.String) return false;
            var s = t.GetString();
            if (s.Length == 0) return false;
            list[i++] = s;
        }
        tags = list;
        return true;
    }

    public void Dispose() => _doc?.Dispose();

    public static int Utf8Length(string s) => Encoding.UTF8.GetByteCount(s);
}
