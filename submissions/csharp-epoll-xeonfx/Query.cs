using System;
using System.Buffers;
using System.Text;
using System.Text.Unicode;

/// <summary>Query strings, parsed the way Go's url.Values.Get does: first occurrence wins, '+' is a space.</summary>
static class Query
{
    // ---------- over the raw query's bytes (what follows the '?') ----------

    /// <summary>The most bytes <see cref="Get(ReadOnlySpan{byte}, ReadOnlySpan{byte}, Span{byte})"/> writes for a
    /// query of <paramref name="queryLength"/> bytes: each byte of a bad UTF-8 sequence can become a 3-byte U+FFFD.</summary>
    public static int MaxDecodedLength(int queryLength) => 3 * queryLength;

    /// <summary>
    /// Decodes the first <paramref name="key"/> parameter's value into <paramref name="dest"/> and returns its
    /// length, or -1 when it isn't present. <paramref name="dest"/> must hold <see cref="MaxDecodedLength"/> of
    /// query.Length. Bytes that aren't UTF-8 after decoding become U+FFFD, as Encoding.UTF8.GetString made them in
    /// the string API, so the value is always valid text. <paramref name="key"/> is ASCII, at most 32 bytes.
    /// </summary>
    public static int Get(ReadOnlySpan<byte> query, ReadOnlySpan<byte> key, Span<byte> dest)
    {
        if (dest.Length < MaxDecodedLength(query.Length)) throw new ArgumentException("dest is too small", nameof(dest));
        if (key.Length > 32) throw new ArgumentException("keys are at most 32 bytes", nameof(key)); // KeyEquals decodes on the stack
        if (!TryFind(query, key, out var raw)) return -1;
        int n = Decode(raw, dest);
        return Utf8.IsValid(dest[..n]) ? n : ReplaceInvalid(dest, n);
    }

    /// <summary>limit (default 20, 1..100) and offset (default 0, &gt;= 0). A parameter that is present, even empty, must be valid.</summary>
    public static bool TryPage(ReadOnlySpan<byte> query, out long limit, out long offset)
    {
        limit = 20;
        offset = 0;
        if (TryFind(query, "limit"u8, out var l) && (!TryParseEscapedUint(l, out limit) || limit < 1 || limit > 100)) return false;
        if (TryFind(query, "offset"u8, out var o) && !TryParseEscapedUint(o, out offset)) return false;
        return true;
    }

    /// <summary>ASCII digits only (no sign, no spaces) that fit in an Int64.</summary>
    public static bool TryParseUint(ReadOnlySpan<byte> s, out long value)
    {
        value = 0;
        if (s.IsEmpty) return false;
        foreach (byte c in s)
        {
            if (c < '0' || c > '9') return false;
            long d = c - '0';
            if (value > (long.MaxValue - d) / 10) return false;
            value = value * 10 + d;
        }
        return true;
    }

    /// <summary>The raw value of the first pair whose decoded key is <paramref name="key"/> and whose escapes are
    /// valid: Go skips pairs holding ';' and drops a pair with a bad escape, in its key or its value.</summary>
    static bool TryFind(ReadOnlySpan<byte> query, ReadOnlySpan<byte> key, out ReadOnlySpan<byte> value)
    {
        ReadOnlySpan<byte> s = query;
        while (!s.IsEmpty)
        {
            int amp = s.IndexOf((byte)'&');
            ReadOnlySpan<byte> pair = amp < 0 ? s : s[..amp];
            s = amp < 0 ? default : s[(amp + 1)..];
            if (pair.IsEmpty || pair.Contains((byte)';')) continue;
            int eq = pair.IndexOf((byte)'=');
            ReadOnlySpan<byte> k = eq < 0 ? pair : pair[..eq];
            value = eq < 0 ? default : pair[(eq + 1)..];
            if (!KeyEquals(k, key) || !ValidEscapes(value)) continue;
            return true;
        }
        value = default;
        return false;
    }

    static bool KeyEquals(ReadOnlySpan<byte> k, ReadOnlySpan<byte> key)
    {
        if (k.IndexOfAny((byte)'%', (byte)'+') < 0) return k.SequenceEqual(key);
        // each escape decodes 3 bytes to 1, so a longer raw key can't decode to this one
        if (k.Length > 3 * key.Length || !ValidEscapes(k)) return false;
        Span<byte> decoded = stackalloc byte[96];
        return decoded[..Decode(k, decoded)].SequenceEqual(key);
    }

    static bool ValidEscapes(ReadOnlySpan<byte> s)
    {
        for (int i = s.IndexOf((byte)'%'); i >= 0; i = s.IndexOf((byte)'%'))
        {
            if (i + 2 >= s.Length || Hex(s[i + 1]) < 0 || Hex(s[i + 2]) < 0) return false;
            s = s[(i + 3)..];
        }
        return true;
    }

    /// <summary>Decodes '+' and %XX (checked by <see cref="ValidEscapes"/>); never longer than the input.</summary>
    static int Decode(ReadOnlySpan<byte> s, Span<byte> dest)
    {
        int n = 0;
        for (int i = 0; i < s.Length; i++)
        {
            byte c = s[i];
            if (c == '+') c = (byte)' ';
            else if (c == '%')
            {
                c = (byte)(Hex(s[i + 1]) << 4 | Hex(s[i + 2]));
                i += 2;
            }
            dest[n++] = c;
        }
        return n;
    }

    /// <summary>
    /// Rewrites dest[..n] with each invalid UTF-8 sequence as U+FFFD, the way Encoding.UTF8.GetString replaces
    /// them, in place: the bytes move to dest[2n..3n] first, and the output (at most 3 bytes per byte read) never
    /// overtakes what is left to read.
    /// </summary>
    static int ReplaceInvalid(Span<byte> dest, int n)
    {
        dest[..n].CopyTo(dest[(2 * n)..]);
        int w = 0;
        for (int r = 2 * n; r < 3 * n;)
        {
            var status = Rune.DecodeFromUtf8(dest[r..(3 * n)], out _, out int consumed);
            if (status == OperationStatus.Done) dest.Slice(r, consumed).CopyTo(dest[w..]);
            else "\uFFFD"u8.CopyTo(dest[w..]);
            w += status == OperationStatus.Done ? consumed : 3;
            r += consumed;
        }
        return w;
    }

    /// <summary><see cref="TryParseUint(ReadOnlySpan{byte}, out long)"/> of a raw value, decoding as it goes.</summary>
    static bool TryParseEscapedUint(ReadOnlySpan<byte> s, out long value)
    {
        value = 0;
        if (s.IsEmpty) return false;
        for (int i = 0; i < s.Length; i++)
        {
            int c = s[i];
            if (c == '%')
            {
                c = Hex(s[i + 1]) << 4 | Hex(s[i + 2]);
                i += 2;
            }
            if (c < '0' || c > '9') return false; // '+' is a space
            long d = c - '0';
            if (value > (long.MaxValue - d) / 10) return false;
            value = value * 10 + d;
        }
        return true;
    }

    static int Hex(byte c) => c switch
    {
        >= (byte)'0' and <= (byte)'9' => c - '0',
        >= (byte)'a' and <= (byte)'f' => c - 'a' + 10,
        >= (byte)'A' and <= (byte)'F' => c - 'A' + 10,
        _ => -1,
    };
}
