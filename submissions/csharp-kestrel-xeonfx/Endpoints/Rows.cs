using System;
using System.Buffers;
using System.Text.Json;
using Conduit.Http;
using Npgsql;

namespace Conduit.Endpoints;

/// <summary>
/// JSON fields written straight from result columns. A text column arrives as UTF-8, and its bytes go into the
/// response as they are (escaped where JSON needs it): no string per column, no UTF-16 round trip.
/// </summary>
static class Rows
{
    /// <summary>Columns up to this size are copied through a buffer kept per thread; larger ones through a pooled one.</summary>
    const int ScratchBytes = 64 << 10;

    [ThreadStatic] static byte[]? t_scratch;

    /// <summary>
    /// Copies column <paramref name="c"/>'s bytes out of the row and hands them to <paramref name="write"/>. Nothing
    /// awaits in between, so the per-thread buffer serves one column at a time.
    /// </summary>
    static void WithBytes<TState>(NpgsqlDataReader r, int c, TState state, SpanAction<byte, TState> write)
    {
        int length = (int)r.GetBytes(c, 0, null, 0, 0);
        if (length > ScratchBytes)
        {
            byte[] rented = ArrayPool<byte>.Shared.Rent(length);
            try
            {
                r.GetBytes(c, 0, rented, 0, length);
                write(rented.AsSpan(0, length), state);
            }
            finally
            {
                ArrayPool<byte>.Shared.Return(rented);
            }
            return;
        }
        byte[] buf = t_scratch ??= new byte[ScratchBytes];
        r.GetBytes(c, 0, buf, 0, length);
        write(buf.AsSpan(0, length), state);
    }

    /// <summary>A text column as a JSON string property.</summary>
    public static void WriteText(Utf8JsonWriter w, JsonEncodedText name, NpgsqlDataReader r, int c) =>
        WithBytes(r, c, (w, name), static (bytes, s) => s.w.WriteString(s.name, bytes));

    /// <summary>A text column as a JSON string property, or null.</summary>
    public static void WriteNullableText(Utf8JsonWriter w, JsonEncodedText name, NpgsqlDataReader r, int c)
    {
        if (r.IsDBNull(c)) w.WriteNull(name);
        else WriteText(w, name, r, c);
    }

    /// <summary>A JSON value Postgres built (a bytea column), copied into the response as is.</summary>
    public static void WriteRaw(Utf8JsonWriter w, NpgsqlDataReader r, int c) =>
        WithBytes(r, c, w, static (bytes, w) => w.WriteRawValue(bytes, skipInputValidation: true));

    /// <summary>A profile's username, bio and image from columns <paramref name="c"/> to c + 2, in order.</summary>
    public static void WritePerson(Utf8JsonWriter w, NpgsqlDataReader r, int c)
    {
        WriteText(w, Names.Username, r, c);
        WriteNullableText(w, Names.Bio, r, c + 1);
        WriteNullableText(w, Names.Image, r, c + 2);
    }
}
