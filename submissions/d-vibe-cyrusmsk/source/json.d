/**
 * A growable byte buffer used to build response bodies, plus the small JSON
 * building blocks the Conduit responses need.
 *
 * Writing JSON by hand (instead of through a serializer) is what makes the read
 * path cheap: article rows are copied into the response almost byte for byte,
 * and only fields that can contain escapes go through putJsonString().
 */
module conduit.json;

/// One response body, usually 1-64 KB.
struct JsonBuf
{
    private char[] data_;
    private size_t len;

    @property size_t length() const pure nothrow @safe @nogc
    {
        return len;
    }

    @property const(char)[] opSlice() const pure nothrow @safe @nogc
    {
        return data_[0 .. len];
    }

    /// Reserves room for at least n more bytes.
    void reserve(size_t n) @safe
    {
        immutable want = len + n;
        if (want <= data_.length) return;
        size_t cap = data_.length ? data_.length : 512;
        while (cap < want) cap *= 2;
        auto next = new char[](cap);
        if (len) next[0 .. len] = data_[0 .. len];
        data_ = next;
    }

    void put(const(char)[] s) @safe
    {
        reserve(s.length);
        data_[len .. len + s.length] = s[];
        len += s.length;
    }

    void putByte(char c) @safe
    {
        reserve(1);
        data_[len++] = c;
    }

    void putInt(long v) @safe
    {
        if (v == 0) {
            putByte('0');
            return;
        }
        char[20] buf;
        size_t i = buf.length;
        ulong u = v < 0 ? cast(ulong)(-v) : cast(ulong) v;
        while (u) {
            buf[--i] = cast(char)('0' + u % 10);
            u /= 10;
        }
        reserve(buf.length - i + 1);
        if (v < 0) data_[len++] = '-';
        immutable n = buf.length - i;
        data_[len .. len + n] = buf[i .. $];
        len += n;
    }

    void putBool(bool b) @safe
    {
        put(b ? cast(const(char)[]) "true" : cast(const(char)[]) "false");
    }

    void putNull() @safe
    {
        put("null");
    }

    /// Writes a JSON string, escaping only what RFC 8259 requires; UTF-8 passes
    /// through untouched.
    void putJsonString(const(char)[] s) @safe
    {
        putByte('"');
        size_t plain = 0;
        foreach (i, c; s) {
            if (c == '"' || c == '\\' || c < 0x20) {
                if (i > plain) put(s[plain .. i]);
                putByte('\\');
                switch (c) {
                    case '"': putByte('"'); break;
                    case '\\': putByte('\\'); break;
                    case '\n': putByte('n'); break;
                    case '\r': putByte('r'); break;
                    case '\t': putByte('t'); break;
                    case '\b': putByte('b'); break;
                    case '\f': putByte('f'); break;
                    default:
                        // other control characters become \u00XX
                        put("u00");
                        putByte(hexDigit(cast(ubyte) c >> 4));
                        putByte(hexDigit(cast(ubyte) c & 0x0f));
                        break;
                }
                plain = i + 1;
            }
        }
        if (s.length > plain) put(s[plain .. $]);
        putByte('"');
    }

    /// Writes the text rendering of a timestamptz in a UTC session:
    /// "YYYY-MM-DD HH:MM:SS[.ffffff][+00]" becomes "YYYY-MM-DDTHH:MM:SS.mmmZ"
    /// (SPEC.md: RFC 3339 UTC, exactly 3 fractional digits, truncated).
    void putTimestamp(const(char)[] pgTimestamp) @safe
    {
        if (pgTimestamp.length < 19 || pgTimestamp[10] != ' ') {
            // Should not happen; keep the response well-formed regardless.
            putJsonString(pgTimestamp);
            return;
        }
        reserve(24);
        data_[len .. len + 10] = pgTimestamp[0 .. 10];
        len += 10;
        data_[len++] = 'T';
        data_[len .. len + 8] = pgTimestamp[11 .. 19];
        len += 8;

        data_[len++] = '.';
        // "SS.ffffff" - index 19 is the dot, the digits follow it
        size_t frac = 0;
        while (frac < 3 && 20 + frac < pgTimestamp.length && isDigit(pgTimestamp[20 + frac]))
            frac++;
        foreach (i; 0 .. 3)
            data_[len++] = i < frac ? pgTimestamp[20 + i] : '0';
        data_[len++] = 'Z';
    }

    /// Writes a Postgres text[] as a JSON array of strings: `{ab,cd}`.
    void putStringArray(const(char)[] pgArray) @safe
    {
        putByte('[');
        if (pgArray.length >= 2) {
            const(char)[] body = pgArray[1 .. $ - 1]; // drop the surrounding braces
            bool first = true;
            size_t i = 0;
            while (i < body.length) {
                if (body[i] == ',') {
                    i++;
                    continue;
                }
                if (body[i] == '"') {
                    // A quoted element: find its end, then undo the doubled quotes.
                    size_t j = i + 1;
                    while (j < body.length && !(body[j] == '"' && (j + 1 == body.length || body[j + 1] == ',')))
                        j++;
                    if (!first) putByte(',');
                    putUnquotedElement(body[i + 1 .. j]);
                    first = false;
                    i = j + 1;
                } else {
                    size_t j = i;
                    while (j < body.length && body[j] != ',')
                        j++;
                    if (!first) putByte(',');
                    putJsonString(body[i .. j]);
                    first = false;
                    i = j;
                }
            }
        }
        putByte(']');
    }

    /// Writes an element taken from a quoted Postgres array, unescaping `""`.
    private void putUnquotedElement(const(char)[] s) @safe
    {
        putByte('"');
        size_t plain = 0;
        foreach (i, c; s) {
            if (c == '"') {
                if (i > plain) put(s[plain .. i]);
                putByte('"');
                plain = i + 1;
            } else if (c == '\\' || c < 0x20) {
                if (i > plain) put(s[plain .. i]);
                putByte('\\');
                switch (c) {
                    case '/': putByte('/'); break;
                    case '\\': putByte('\\'); break;
                    case '\n': putByte('n'); break;
                    case '\r': putByte('r'); break;
                    case '\t': putByte('t'); break;
                    default:
                        put("u00");
                        putByte(hexDigit(cast(ubyte) c >> 4));
                        putByte(hexDigit(cast(ubyte) c & 0x0f));
                        break;
                }
                plain = i + 1;
            }
        }
        if (s.length > plain) put(s[plain .. $]);
        putByte('"');
    }
}

private char hexDigit(ubyte v) pure nothrow @safe @nogc
{
    return cast(char)(v < 10 ? '0' + v : 'a' + v - 10);
}

private bool isDigit(char c) pure nothrow @safe @nogc
{
    return c >= '0' && c <= '9';
}

@safe unittest
{
    import std.algorithm.searching : countUntil;

    static string build()
    {
        auto b = JsonBuf.init;
        b.putByte('{');
        b.putJsonString("a\"b\\c\nd\t");
        b.putByte(',');
        b.putInt(-12345);
        b.putByte(',');
        b.putInt(0);
        b.putByte(',');
        b.putBool(true);
        b.putBool(false);
        b.putNull();
        b.putByte(',');
        b.putTimestamp("2026-09-01 12:34:56.789012+00");
        b.putTimestamp("2026-09-01 12:34:56+00");
        b.putByte(',');
        b.putStringArray("{alpha,beta}");
        b.putStringArray("{}");
        b.putStringArray("");
        b.putStringArray("{\"a b\",\"c,d\"}");
        b.putByte('}');
        return b[].idup;
    }

    immutable got = build();
    assert(got.length > 0);
    // Timestamps are written as raw JSON values (no quotes).
    assert(got.countUntil(`2026-09-01T12:34:56.789Z`) > 0);
    assert(got.countUntil(`2026-09-01T12:34:56.000Z`) > 0);
    assert(got.countUntil(`-12345`) > 0);
    assert(got.countUntil(`["alpha","beta"]`) > 0);
    assert(got.countUntil(`["a b","c,d"]`) > 0);
    {
        auto b = JsonBuf.init;
        b.putJsonString("plain ascii");
        b.putJsonString("");
        assert(b[] == `"plain ascii"""`, b[]);
    }
    {
        auto b = JsonBuf.init;
        b.putInt(9223372036854775807L);
        b.putInt(-9223372036854775807L);
        b.putJsonString("ünïcode ✓");
        assert(b[] == `9223372036854775807-9223372036854775807"ünïcode ✓"`, b[]);
    }
}
