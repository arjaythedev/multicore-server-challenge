using System.Buffers;
using System.Text;

namespace Conduit.Json;

/// <summary>
/// UTF-8 JSON writer over a growable byte buffer. It inserts commas itself and escapes strings
/// per RFC 8259; it does not check that calls form valid JSON.
/// </summary>
public sealed class JsonWriter {
    /// <summary>DateTime ticks at 2000-01-01T00:00:00Z, the Postgres epoch.</summary>
    private const long PgEpochTicks = 630_822_816_000_000_000L;

    /// <summary>The bytes RFC 8259 requires escaped in a string: control characters, quote and backslash.</summary>
    private static readonly SearchValues<byte> MustEscape = SearchValues.Create(
        "\0\u0001\u0002\u0003\u0004\u0005\u0006\u0007\b\t\n\u000b\f\r\u000e\u000f\u0010\u0011\u0012\u0013\u0014\u0015\u0016\u0017\u0018\u0019\u001a\u001b\u001c\u001d\u001e\u001f\"\\"u8);

    /// <summary>The output buffer; replaced by a larger one when it fills.</summary>
    private byte[] _buf;
    /// <summary>Number of bytes written.</summary>
    private int _len;
    /// <summary>True before the first item of the current object or array, so no comma is needed.</summary>
    private bool _first = true;
    /// <summary>True right after a property name, so the next value takes no comma.</summary>
    private bool _afterName;

    /// <summary>Creates a writer with an initial buffer of <paramref name="capacity"/> bytes.</summary>
    public JsonWriter(int capacity = 4096) => _buf = new byte[capacity];

    /// <summary>The backing buffer; valid bytes end at <see cref="Length"/>. It may be replaced as the writer grows.</summary>
    public byte[] Buffer => _buf;

    /// <summary>The end of the written bytes (an index into <see cref="Buffer"/>).</summary>
    public int Length => _len;

    /// <summary>Forgets everything written and starts writing at <paramref name="start"/>, leaving that many bytes untouched in front.</summary>
    public void Reset(int start = 0) {
        Ensure(start);
        _len = start;
        _first = true;
        _afterName = false;
    }

    /// <summary>Writes '{'.</summary>
    public void StartObject() {
        BeforeValue();
        Put((byte)'{');
        _first = true;
    }

    /// <summary>Writes '}'.</summary>
    public void EndObject() {
        Put((byte)'}');
        _first = false;
    }

    /// <summary>Writes '['.</summary>
    public void StartArray() {
        BeforeValue();
        Put((byte)'[');
        _first = true;
    }

    /// <summary>Writes ']'.</summary>
    public void EndArray() {
        Put((byte)']');
        _first = false;
    }

    /// <summary>Writes an escaped property name and the colon.</summary>
    public void PropertyName(string name) {
        if (!_first) {
            Put((byte)',');
        }

        WriteQuoted(name);
        Put((byte)':');
        _afterName = true;
    }

    /// <summary>Writes an escaped property name given as UTF-8 bytes (a u8 literal needs no transcoding) and the colon.</summary>
    public void PropertyName(ReadOnlySpan<byte> utf8Name) {
        if (!_first) {
            Put((byte)',');
        }

        Put((byte)'"');
        EscapeUtf8(utf8Name);
        Put((byte)'"');
        Put((byte)':');
        _afterName = true;
    }

    /// <summary>Writes a string value, escaped.</summary>
    public void WriteString(string value) {
        BeforeValue();
        WriteQuoted(value);
    }

    /// <summary>Writes a string value given as UTF-8 bytes (for example a Postgres text column), escaped.</summary>
    public void WriteString(ReadOnlySpan<byte> utf8) {
        BeforeValue();
        Put((byte)'"');
        EscapeUtf8(utf8);
        Put((byte)'"');
    }

    /// <summary>Writes an integer value.</summary>
    public void WriteLong(long value) {
        BeforeValue();
        Ensure(_len + 20);
        value.TryFormat(_buf.AsSpan(_len), out int n, default, System.Globalization.CultureInfo.InvariantCulture);
        _len += n;
    }

    /// <summary>Writes true or false.</summary>
    public void WriteBool(bool value) {
        BeforeValue();
        WriteRawBytes(value ? "true"u8 : "false"u8);
    }

    /// <summary>Writes null.</summary>
    public void WriteNull() {
        BeforeValue();
        WriteRawBytes("null"u8);
    }

    /// <summary>
    /// Writes a quoted RFC 3339 UTC time with exactly three fraction digits from a Postgres
    /// timestamptz value (microseconds since 2000-01-01T00:00:00Z). Sub-millisecond digits are
    /// dropped by rounding toward negative infinity, so 23:59:59.9995 reads .999.
    /// </summary>
    public void WriteTimestamp(long pgMicros) {
        BeforeValue();
        long ms = Math.DivRem(pgMicros, 1000, out long rem);
        if (rem < 0) {
            ms--;
        }

        DateTime dt = new(PgEpochTicks + ms * TimeSpan.TicksPerMillisecond, DateTimeKind.Utc);

        Ensure(_len + 26);
        byte[] b = _buf;
        int p = _len;
        b[p++] = (byte)'"';
        p = Digits(b, p, dt.Year, 4);
        b[p++] = (byte)'-';
        p = Digits(b, p, dt.Month, 2);
        b[p++] = (byte)'-';
        p = Digits(b, p, dt.Day, 2);
        b[p++] = (byte)'T';
        p = Digits(b, p, dt.Hour, 2);
        b[p++] = (byte)':';
        p = Digits(b, p, dt.Minute, 2);
        b[p++] = (byte)':';
        p = Digits(b, p, dt.Second, 2);
        b[p++] = (byte)'.';
        p = Digits(b, p, dt.Millisecond, 3);
        b[p++] = (byte)'Z';
        b[p++] = (byte)'"';
        _len = p;
    }

    /// <summary>Writes <paramref name="value"/> as exactly <paramref name="count"/> zero-padded decimal digits at <paramref name="p"/> and returns the next position.</summary>
    private static int Digits(byte[] b, int p, int value, int count) {
        for (int i = count - 1; i >= 0; i--) {
            b[p + i] = (byte)('0' + value % 10);
            value /= 10;
        }
        return p + count;
    }

    /// <summary>Writes the comma a value needs, unless it is the first item or follows a property name.</summary>
    private void BeforeValue() {
        if (_afterName) {
            _afterName = false;
        } else if (!_first) {
            Put((byte)',');
        }

        _first = false;
    }

    /// <summary>Writes a quoted, escaped string. Plain ASCII without characters to escape goes straight into the buffer.</summary>
    private void WriteQuoted(string s) {
        // Property names and most values are plain ASCII: narrow them straight into the buffer.
        Ensure(_len + s.Length + 2);
        Span<byte> into = _buf.AsSpan(_len + 1, s.Length);
        if (Ascii.FromUtf16(s, into, out _) == OperationStatus.Done && into.IndexOfAny(MustEscape) < 0) {
            _buf[_len] = (byte)'"';
            _len += s.Length + 1;
            _buf[_len++] = (byte)'"';
            return;
        }

        Put((byte)'"');
        int max = Encoding.UTF8.GetMaxByteCount(s.Length);
        if (max <= 512) {
            Span<byte> tmp = stackalloc byte[512];
            int n = Encoding.UTF8.GetBytes(s, tmp);
            EscapeUtf8(tmp[..n]);
        } else {
            EscapeUtf8(Encoding.UTF8.GetBytes(s));
        }
        Put((byte)'"');
    }

    /// <summary>Writes UTF-8 bytes with JSON escapes; bytes that need no escape are copied unchanged.</summary>
    private void EscapeUtf8(ReadOnlySpan<byte> s) {
        Ensure(_len + s.Length + 8);
        while (true) {
            int i = s.IndexOfAny(MustEscape);
            if (i < 0) {
                WriteRawBytes(s);
                return;
            }

            WriteRawBytes(s[..i]);
            byte c = s[i];
            s = s[(i + 1)..];
            switch (c) {
                case (byte)'"': WriteRawBytes("\\\""u8); break;
                case (byte)'\\': WriteRawBytes("\\\\"u8); break;
                case (byte)'\n': WriteRawBytes("\\n"u8); break;
                case (byte)'\r': WriteRawBytes("\\r"u8); break;
                case (byte)'\t': WriteRawBytes("\\t"u8); break;
                case 8: WriteRawBytes("\\b"u8); break;
                case 12: WriteRawBytes("\\f"u8); break;
                default:
                    WriteRawBytes("\\u00"u8);
                    Put((byte)"0123456789abcdef"[c >> 4]);
                    Put((byte)"0123456789abcdef"[c & 15]);
                    break;
            }
        }
    }

    /// <summary>Appends bytes as they are.</summary>
    private void WriteRawBytes(ReadOnlySpan<byte> bytes) {
        Ensure(_len + bytes.Length);
        bytes.CopyTo(_buf.AsSpan(_len));
        _len += bytes.Length;
    }

    /// <summary>Appends one byte.</summary>
    private void Put(byte b) {
        if (_len == _buf.Length) {
            Ensure(_len + 1);
        }

        _buf[_len++] = b;
    }

    /// <summary>Grows the buffer, at least doubling it, until it holds <paramref name="needed"/> bytes.</summary>
    private void Ensure(int needed) {
        if (needed <= _buf.Length) {
            return;
        }

        int size = Math.Max(needed, _buf.Length * 2);
        Array.Resize(ref _buf, size);
    }
}
