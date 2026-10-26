using System;
using System.Buffers;
using System.Text;
using Microsoft.AspNetCore.Http;

namespace Conduit.Http;

/// <summary>Query strings, parsed the way Go's url.Values.Get does: first occurrence wins, '+' is a space.</summary>
public static class Query
{
    /// <summary>The decoded value of the first <paramref name="key"/> parameter, or null when it isn't present.</summary>
    public static string? Get(QueryString query, string key)
    {
        string? qs = query.Value;
        if (string.IsNullOrEmpty(qs)) return null;
        ReadOnlySpan<char> s = qs.AsSpan(qs[0] == '?' ? 1 : 0);
        while (!s.IsEmpty)
        {
            int amp = s.IndexOf('&');
            ReadOnlySpan<char> pair = amp < 0 ? s : s[..amp];
            s = amp < 0 ? default : s[(amp + 1)..];
            if (pair.IsEmpty || pair.Contains(';')) continue; // Go rejects (skips) pairs with a semicolon
            int eq = pair.IndexOf('=');
            ReadOnlySpan<char> k = eq < 0 ? pair : pair[..eq];
            ReadOnlySpan<char> v = eq < 0 ? default : pair[(eq + 1)..];
            if (k.IndexOfAny('%', '+') < 0 ? !k.SequenceEqual(key) : !TryDecode(k, out string? dk) || dk != key) continue;
            if (!TryDecode(v, out string? dv)) continue; // an invalid escape drops the pair, as in Go
            return dv;
        }
        return null;
    }

    static bool TryDecode(ReadOnlySpan<char> s, out string? result)
    {
        if (s.IndexOfAny('%', '+') < 0)
        {
            result = s.ToString();
            return true;
        }
        byte[] rented = ArrayPool<byte>.Shared.Rent(s.Length * 3);
        try
        {
            int n = 0;
            for (int i = 0; i < s.Length; i++)
            {
                char c = s[i];
                if (c == '+') rented[n++] = (byte)' ';
                else if (c == '%')
                {
                    if (i + 2 >= s.Length) { result = null; return false; }
                    int hi = Hex(s[i + 1]), lo = Hex(s[i + 2]);
                    if (hi < 0 || lo < 0) { result = null; return false; }
                    rented[n++] = (byte)(hi << 4 | lo);
                    i += 2;
                }
                else if (c < 0x80) rented[n++] = (byte)c;
                else
                {
                    int len = char.IsHighSurrogate(c) && i + 1 < s.Length ? 2 : 1;
                    n += Encoding.UTF8.GetBytes(s.Slice(i, len), rented.AsSpan(n));
                    i += len - 1;
                }
            }
            result = Encoding.UTF8.GetString(rented, 0, n);
            return true;
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(rented);
        }
    }

    static int Hex(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'a' and <= 'f' => c - 'a' + 10,
        >= 'A' and <= 'F' => c - 'A' + 10,
        _ => -1,
    };

    /// <summary>ASCII digits only (no sign, no spaces) that fit in an Int64.</summary>
    public static bool TryParseUint(ReadOnlySpan<char> s, out long value)
    {
        value = 0;
        if (s.IsEmpty) return false;
        foreach (char c in s)
        {
            if (c < '0' || c > '9') return false;
            long d = c - '0';
            if (value > (long.MaxValue - d) / 10) return false;
            value = value * 10 + d;
        }
        return true;
    }

    /// <summary>limit (default 20, 1..100) and offset (default 0, &gt;= 0). A parameter that is present, even empty, must be valid.</summary>
    public static bool TryPage(QueryString query, out long limit, out long offset)
    {
        limit = 20;
        offset = 0;
        string? l = Get(query, "limit");
        if (l is not null && (!TryParseUint(l, out limit) || limit < 1 || limit > 100)) return false;
        string? o = Get(query, "offset");
        if (o is not null && !TryParseUint(o, out offset)) return false;
        return true;
    }
}
