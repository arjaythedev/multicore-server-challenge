using System;
using System.Buffers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Unicode;
using System.Text.Json;

/// <summary>Request bodies: {"wrapper": {...}} with case-sensitive keys. Anything malformed is a 422.</summary>
static class Body
{
    // ---------- over the body's bytes: no document, no strings ----------

    static readonly JsonReaderOptions Options = new() { MaxDepth = 64 }; // JsonDocument's defaults

    /// <summary>
    /// Reads <paramref name="body"/> as {"wrapper": {...}} for the fields <paramref name="shape"/> names. False when
    /// the body is malformed JSON, its root isn't an object, or the wrapper is absent or not an object.
    /// <para>
    /// The outcomes are JsonDocument's: one leading UTF-8 BOM is skipped, the last of duplicate keys wins (for the
    /// wrapper too), keys match after unescaping. A value that JsonDocument couldn't turn into a string (invalid
    /// UTF-8, an escaped lone surrogate) is <see cref="FieldKind.Invalid"/>; JsonDocument threw there, a 500.
    /// </para>
    /// A value without escapes stays where it is in the body; an escaped one is unescaped into
    /// <paramref name="scratch"/> at its own offset in the body (unescaping never grows a value), so values never
    /// overlap and <see cref="Tags"/> can use the same scratch. It must hold at least body.Length bytes.
    /// </summary>
    public static bool TryRead(ReadOnlySpan<byte> body, BodyShape shape, Span<byte> scratch, out BodyFields fields)
    {
        fields = default;
        if (scratch.Length < body.Length) throw new ArgumentException("scratch must hold the body", nameof(scratch));
        int bom = body.StartsWith(Utf8Bom) ? 3 : 0; // JsonDocument.ParseAsync skips one
        try
        {
            var r = new Utf8JsonReader(body[bom..], Options);
            if (!r.Read() || r.TokenType != JsonTokenType.StartObject) return false;
            bool wrapper = false;
            while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
            {
                if (!NameEquals(ref r, shape.Wrapper))
                {
                    r.Read();
                    r.Skip();
                    continue;
                }
                // a later wrapper replaces an earlier one, fields and all
                fields = default;
                r.Read();
                if (r.TokenType != JsonTokenType.StartObject)
                {
                    wrapper = false;
                    r.Skip();
                    continue;
                }
                wrapper = true;
                while (r.Read() && r.TokenType == JsonTokenType.PropertyName)
                {
                    int f = shape.Find(ref r);
                    r.Read();
                    if (f < 0) r.Skip();
                    else if (f == shape.TagList) fields[f] = ReadTagList(ref r, bom);
                    else fields[f] = ReadString(ref r, bom, scratch);
                }
            }
            // the reader is at the root's end; anything after it but whitespace throws here, as in a full parse
            while (r.Read()) { }
            return wrapper;
        }
        catch (JsonException)
        {
            fields = default;
            return false;
        }
    }

    static ReadOnlySpan<byte> Utf8Bom => [0xEF, 0xBB, 0xBF];

    /// <summary>
    /// Whether the property name the reader is on is <paramref name="name"/> (ASCII, at most 16 bytes) once
    /// unescaped. ValueTextEquals throws on an escaped lone surrogate; JsonDocument's lookup just doesn't match it.
    /// </summary>
    internal static bool NameEquals(ref Utf8JsonReader r, ReadOnlySpan<byte> name) => TryTextEquals(ref r, name, out bool equal) && equal;

    /// <summary>
    /// Compares the string or property name the reader is on with <paramref name="text"/> (ASCII, at most 16
    /// bytes) once unescaped, without throwing: false when it is escaped and doesn't unescape (a lone surrogate).
    /// </summary>
    internal static bool TryTextEquals(ref Utf8JsonReader r, ReadOnlySpan<byte> text, out bool equal)
    {
        ReadOnlySpan<byte> raw = r.ValueSpan;
        equal = false;
        if (!r.ValueIsEscaped)
        {
            equal = raw.SequenceEqual(text);
            return true;
        }
        if (!IsValidEscaped(raw)) return false;
        // an escape takes at most 6 raw bytes per byte it stands for, so a longer raw name can't match
        if (raw.Length > 6 * text.Length) return true;
        Span<byte> buf = stackalloc byte[MaxNameBytes * 6];
        TryUnescape(raw, buf, out int n);
        equal = buf[..n].SequenceEqual(text);
        return true;
    }

    /// <summary>The longest wrapper or field name a <see cref="BodyShape"/> takes.</summary>
    internal const int MaxNameBytes = 16;

    /// <summary>Null is <see cref="FieldKind.Missing"/>; a string is its bytes; anything else is invalid.</summary>
    static BodyField ReadString(ref Utf8JsonReader r, int bom, Span<byte> scratch)
    {
        if (r.TokenType == JsonTokenType.Null) return default;
        if (r.TokenType != JsonTokenType.String)
        {
            r.Skip();
            return new BodyField(FieldKind.Invalid, 0, 0, false);
        }
        int start = bom + (int)r.TokenStartIndex + 1;
        ReadOnlySpan<byte> raw = r.ValueSpan;
        if (!r.ValueIsEscaped)
            return Utf8.IsValid(raw) ? new BodyField(FieldKind.Text, start, raw.Length, false) : new BodyField(FieldKind.Invalid, 0, 0, false);
        if (!TryUnescape(raw, scratch.Slice(start, raw.Length), out int written)) return new BodyField(FieldKind.Invalid, 0, 0, false);
        return new BodyField(FieldKind.Text, start, written, true);
    }

    /// <summary>An array of non-empty strings, kept as the array's place in the body; null is Missing.</summary>
    static BodyField ReadTagList(ref Utf8JsonReader r, int bom)
    {
        if (r.TokenType == JsonTokenType.Null) return default;
        if (r.TokenType != JsonTokenType.StartArray)
        {
            r.Skip();
            return new BodyField(FieldKind.Invalid, 0, 0, false);
        }
        int start = (int)r.TokenStartIndex;
        int count = 0;
        bool ok = true;
        while (r.Read() && r.TokenType != JsonTokenType.EndArray)
        {
            if (!ok || r.TokenType != JsonTokenType.String)
            {
                ok = false;
                r.Skip();
                continue;
            }
            // any escape unescapes to at least one byte, so non-empty is the raw length
            ok = r.ValueSpan.Length > 0 && (r.ValueIsEscaped ? IsValidEscaped(r.ValueSpan) : Utf8.IsValid(r.ValueSpan));
            count++;
        }
        if (!ok) return new BodyField(FieldKind.Invalid, 0, 0, false);
        int end = (int)r.TokenStartIndex + 1;
        return new BodyField(FieldKind.Array, bom + start, end - start, false, count);
    }

    /// <summary>Whether an escaped string is one JsonDocument could read; checked without writing it anywhere.</summary>
    static bool IsValidEscaped(ReadOnlySpan<byte> raw)
    {
        int i = 0;
        while (i < raw.Length)
        {
            int esc = raw[i..].IndexOf((byte)'\\');
            int run = esc < 0 ? raw.Length - i : esc;
            if (!Utf8.IsValid(raw.Slice(i, run))) return false;
            i += run;
            if (i < raw.Length && !TryEscape(raw, ref i, out _)) return false;
        }
        return true;
    }

    /// <summary>
    /// Unescapes a string the reader has already checked for escape syntax. False on what JsonDocument's GetString
    /// throws for: invalid UTF-8 and a \u escape of a lone surrogate.
    /// </summary>
    internal static bool TryUnescape(ReadOnlySpan<byte> raw, Span<byte> dest, out int written)
    {
        written = 0;
        int i = 0;
        while (i < raw.Length)
        {
            int esc = raw[i..].IndexOf((byte)'\\');
            int run = esc < 0 ? raw.Length - i : esc;
            // a literal run must be valid UTF-8 by itself: an escape only ever produces whole characters
            ReadOnlySpan<byte> lit = raw.Slice(i, run);
            if (!Utf8.IsValid(lit)) return false;
            lit.CopyTo(dest[written..]);
            written += run;
            i += run;
            if (i >= raw.Length) break;
            if (!TryEscape(raw, ref i, out int scalar)) return false;
            written += new Rune(scalar).EncodeToUtf8(dest[written..]);
        }
        return true;
    }

    /// <summary>The scalar of the escape at raw[i] ('\\'), advancing past it; false for a lone surrogate.</summary>
    static bool TryEscape(ReadOnlySpan<byte> raw, ref int i, out int scalar)
    {
        byte c = raw[i + 1];
        i += 2;
        switch (c)
        {
            case (byte)'"': scalar = '"'; return true;
            case (byte)'\\': scalar = '\\'; return true;
            case (byte)'/': scalar = '/'; return true;
            case (byte)'b': scalar = '\b'; return true;
            case (byte)'f': scalar = '\f'; return true;
            case (byte)'n': scalar = '\n'; return true;
            case (byte)'r': scalar = '\r'; return true;
            case (byte)'t': scalar = '\t'; return true;
        }
        // 'u': the reader guarantees four hex digits
        int u = Hex4(raw.Slice(i, 4));
        i += 4;
        scalar = u;
        if (u is < 0xD800 or > 0xDFFF) return true;
        if (u >= 0xDC00) return false; // a low surrogate first
        if (i + 6 > raw.Length || raw[i] != '\\' || raw[i + 1] != 'u') return false;
        int lo = Hex4(raw.Slice(i + 2, 4));
        if (lo is < 0xDC00 or > 0xDFFF) return false;
        i += 6;
        scalar = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00);
        return true;
    }

    static int Hex4(ReadOnlySpan<byte> h) => Hex(h[0]) << 12 | Hex(h[1]) << 8 | Hex(h[2]) << 4 | Hex(h[3]);

    static int Hex(byte c) => c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;

    /// <summary>The tags of a <see cref="FieldKind.Array"/> field, each unescaped when needed into the scratch
    /// <see cref="TryRead"/> was given (at the tag's own offset, so the other fields stay intact).</summary>
    public static TagReader Tags(ReadOnlySpan<byte> body, in BodyField tagList, Span<byte> scratch)
    {
        if (scratch.Length < body.Length) throw new ArgumentException("scratch must hold the body", nameof(scratch));
        return tagList.Kind == FieldKind.Array ? new TagReader(tagList.Value(body, default), scratch[tagList.Start..]) : default;
    }

    /// <summary>Walks a tag array that <see cref="TryRead"/> has validated: every element is a non-empty valid string.</summary>
    public ref struct TagReader
    {
        Utf8JsonReader _r;
        readonly Span<byte> _scratch;
        readonly bool _valid; // false for default

        /// <param name="scratch">The scratch from the array's offset on.</param>
        internal TagReader(ReadOnlySpan<byte> array, Span<byte> scratch)
        {
            _r = new Utf8JsonReader(array, Options);
            _r.Read(); // [
            _scratch = scratch;
            _valid = true;
        }

        /// <summary>The next tag's UTF-8 bytes, in the body or in its own place in scratch: valid as long as both are.</summary>
        public bool Next(out ReadOnlySpan<byte> tag)
        {
            tag = default;
            if (!_valid || !_r.Read() || _r.TokenType != JsonTokenType.String) return false;
            if (!_r.ValueIsEscaped) tag = _r.ValueSpan;
            else
            {
                var dest = _scratch.Slice((int)_r.TokenStartIndex + 1, _r.ValueSpan.Length);
                TryUnescape(_r.ValueSpan, dest, out int n);
                tag = dest[..n];
            }
            return true;
        }
    }
}

/// <summary>A request body's wrapper and the fields an endpoint reads from it.</summary>
sealed class BodyShape
{
    internal readonly byte[] Wrapper;
    readonly byte[][] _fields;

    /// <summary>The field read as an array of non-empty strings, or -1.</summary>
    internal readonly int TagList;

    public BodyShape(string wrapper, string[] fields, string? tagList = null)
    {
        if (fields.Length + (tagList is null ? 0 : 1) > BodyFields.Max) throw new ArgumentException("too many fields", nameof(fields));
        foreach (string name in (string[])[wrapper, .. fields, tagList ?? ""])
            if (name.Length > Body.MaxNameBytes || !System.Text.Ascii.IsValid(name)) throw new ArgumentException("names are ASCII, at most 16 bytes", nameof(fields));
        Wrapper = Encoding.UTF8.GetBytes(wrapper);
        _fields = new byte[fields.Length + (tagList is null ? 0 : 1)][];
        for (int i = 0; i < fields.Length; i++) _fields[i] = Encoding.UTF8.GetBytes(fields[i]);
        TagList = -1;
        if (tagList is not null) _fields[TagList = fields.Length] = Encoding.UTF8.GetBytes(tagList);
    }

    /// <summary>The index of the property name the reader is on, or -1. An escaped name is unescaped once.</summary>
    internal int Find(ref Utf8JsonReader r)
    {
        Span<byte> buf = stackalloc byte[Body.MaxNameBytes * 6];
        scoped ReadOnlySpan<byte> name = r.ValueSpan;
        if (r.ValueIsEscaped)
        {
            // longer than any field could be once unescaped, or not text at all: matches nothing
            if (name.Length > buf.Length || !Body.TryUnescape(name, buf, out int n)) return -1;
            name = buf[..n];
        }
        for (int i = 0; i < _fields.Length; i++)
            if (name.SequenceEqual(_fields[i])) return i;
        return -1;
    }

    // The challenge's bodies. Fields are indexed in the order given.
    public static readonly BodyShape Register = new("user", ["username", "email", "password"]);
    public static readonly BodyShape Login = new("user", ["email", "password"]);
    public static readonly BodyShape UpdateUser = new("user", ["email", "username", "password", "bio", "image"]);
    public static readonly BodyShape CreateArticle = new("article", ["title", "description", "body"], "tagList");
    public static readonly BodyShape UpdateArticle = new("article", ["title", "description", "body"]);
    public static readonly BodyShape CreateComment = new("comment", ["body"]);
}

enum FieldKind : byte
{
    /// <summary>Absent or null.</summary>
    Missing,
    Text,
    /// <summary>A tag list: an array of non-empty strings, possibly empty.</summary>
    Array,
    /// <summary>The wrong JSON type, or a string that isn't valid text; for a tag list, any bad element.</summary>
    Invalid,
}

/// <summary>Where a field's value is: in the body, or in the scratch buffer when it was escaped.</summary>
readonly struct BodyField
{
    public readonly FieldKind Kind;
    readonly bool _inScratch;
    internal readonly int Start;
    public readonly int Length;

    /// <summary>The number of tags in an <see cref="FieldKind.Array"/>.</summary>
    public readonly int Count;

    internal BodyField(FieldKind kind, int start, int length, bool inScratch, int count = 0)
    {
        Kind = kind;
        Start = start;
        Length = length;
        _inScratch = inScratch;
        Count = count;
    }

    /// <summary>The value's UTF-8 bytes (for an array, its JSON text in the body).</summary>
    public ReadOnlySpan<byte> Value(ReadOnlySpan<byte> body, ReadOnlySpan<byte> scratch) =>
        Kind is FieldKind.Missing or FieldKind.Invalid ? default
        : _inScratch ? scratch.Slice(Start, Length)
        : body.Slice(Start, Length);

    /// <summary>The same bytes as <see cref="Value"/>, as memory that can be kept across an await.</summary>
    public ReadOnlyMemory<byte> Memory(ReadOnlyMemory<byte> body, ReadOnlyMemory<byte> scratch) =>
        Kind is FieldKind.Missing or FieldKind.Invalid ? default
        : _inScratch ? scratch.Slice(Start, Length)
        : body.Slice(Start, Length);

    /// <summary>Body.TryReqString: a present, non-empty string.</summary>
    public bool IsRequired => Kind == FieldKind.Text && Length > 0;

    /// <summary>Body.TryOptString: absent, null, or a string (non-empty when <paramref name="nonEmpty"/>).</summary>
    public bool IsOptional(bool nonEmpty) => Kind == FieldKind.Missing || Kind == FieldKind.Text && (!nonEmpty || Length > 0);

    public bool IsMissing => Kind == FieldKind.Missing;
}

/// <summary>The fields of one body, by the index the <see cref="BodyShape"/> gave them.</summary>
[InlineArray(Max)]
struct BodyFields
{
    public const int Max = 6;
    BodyField _e;
}
