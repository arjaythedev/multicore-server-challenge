using System;
using System.Buffers;
using System.Buffers.Binary;
using System.Buffers.Text;
using System.Text;
using System.Text.Json;

/// <summary>Writes the responses' JSON straight into a byte buffer. The caller makes room first (<see cref="Loop.Room"/>).</summary>
static class Json
{
    /// <summary>Microseconds from 1970 to 2000, where Postgres counts timestamps from.</summary>
    const long PgEpochMicros = 946_684_800_000_000;
    const long MicrosPerDay = 86_400_000_000;

    public static void Raw(byte[] b, ref int at, ReadOnlySpan<byte> s)
    {
        s.CopyTo(b.AsSpan(at));
        at += s.Length;
    }

    public static void Long(byte[] b, ref int at, long v)
    {
        Utf8Formatter.TryFormat(v, b.AsSpan(at), out int n);
        at += n;
    }

    /// <summary>The bytes a JSON string can't hold as they are: quotes, backslashes and control characters.</summary>
    static readonly SearchValues<byte> Escaped = SearchValues.Create(
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, (byte)'"', (byte)'\\']);

    /// <summary>A JSON string: quotes, backslashes and control characters escaped, everything else as is (runs
    /// without them copied whole).</summary>
    public static void String(byte[] b, ref int at, ReadOnlySpan<byte> s)
    {
        b[at++] = (byte)'"';
        while (true)
        {
            int clean = s.IndexOfAny(Escaped);
            if (clean < 0) break;
            s[..clean].CopyTo(b.AsSpan(at));
            at += clean;
            byte c = s[clean];
            s = s[(clean + 1)..];
            b[at++] = (byte)'\\';
            switch (c)
            {
                case (byte)'"': b[at++] = (byte)'"'; break;
                case (byte)'\\': b[at++] = (byte)'\\'; break;
                case (byte)'\n': b[at++] = (byte)'n'; break;
                case (byte)'\r': b[at++] = (byte)'r'; break;
                case (byte)'\t': b[at++] = (byte)'t'; break;
                default:
                    b[at++] = (byte)'u';
                    b[at++] = (byte)'0';
                    b[at++] = (byte)'0';
                    b[at++] = (byte)"0123456789abcdef"[c >> 4];
                    b[at++] = (byte)"0123456789abcdef"[c & 15];
                    break;
            }
        }
        s.CopyTo(b.AsSpan(at));
        at += s.Length;
        b[at++] = (byte)'"';
    }

    /// <summary>A Postgres timestamptz (microseconds since 2000, UTC) as "yyyy-MM-ddTHH:mm:ss.fffZ", cut to milliseconds.
    /// Years past 0000-9999 can't be written so; they keep their last four digits.</summary>
    public static void Timestamp(byte[] b, ref int at, long pgMicros)
    {
        long days = Math.DivRem(pgMicros + PgEpochMicros, MicrosPerDay, out long micros);
        if (micros < 0)
        {
            micros += MicrosPerDay;
            days--;
        }
        uint ofDay = (uint)(micros / 1000);
        // days since 1970 to a civil date (Howard Hinnant's algorithm and names, from year 0 on, in 32 bits)
        uint z = (uint)(days + 719_468);
        uint era = z / 146_097;
        uint doe = z - era * 146_097;
        uint yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint mp = (5 * doy + 2) / 153;
        uint day = doy - (153 * mp + 2) / 5 + 1;
        uint month = mp < 10 ? mp + 3 : mp - 9;
        uint year = (yoe + era * 400 + (month <= 2 ? 1u : 0u)) % 10_000;
        uint seconds = ofDay / 1000;

        Span<byte> o = b.AsSpan(at, 26);
        o[0] = (byte)'"';
        TwoDigits(o, 1, year / 100);
        TwoDigits(o, 3, year % 100);
        o[5] = (byte)'-';
        TwoDigits(o, 6, month);
        o[8] = (byte)'-';
        TwoDigits(o, 9, day);
        o[11] = (byte)'T';
        TwoDigits(o, 12, seconds / 3600);
        o[14] = (byte)':';
        TwoDigits(o, 15, seconds / 60 % 60);
        o[17] = (byte)':';
        TwoDigits(o, 18, seconds % 60);
        o[20] = (byte)'.';
        uint ms = ofDay % 1000;
        o[21] = (byte)('0' + ms / 100);
        TwoDigits(o, 22, ms % 100);
        o[24] = (byte)'Z';
        o[25] = (byte)'"';
        at += 26;
    }

    /// <summary>"00" to "99": two digits are one lookup, not a division each.</summary>
    static ReadOnlySpan<byte> DigitPairs => "00010203040506070809101112131415161718192021222324252627282930313233343536373839404142434445464748495051525354555657585960616263646566676869707172737475767778798081828384858687888990919293949596979899"u8;

    static void TwoDigits(Span<byte> o, int i, uint v)
    {
        o[i] = DigitPairs[(int)(v * 2)];
        o[i + 1] = DigitPairs[(int)(v * 2 + 1)];
    }
}
