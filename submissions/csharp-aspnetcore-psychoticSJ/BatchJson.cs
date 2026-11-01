using System.Text.Json;
using Npgsql;

namespace ConduitChallenge;

sealed class BatchJson : IDisposable
{
    const int Capacity = 256;
    readonly Dictionary<long, Fragment> _fragments = new();
    PooledBuffer? _scratch;

    readonly record struct Fragment(int Response, int Start, int Length, int FavoriteAt, int FollowingAt, bool Favorited, bool Following);

    public void Article(Utf8JsonWriter writer, NpgsqlDataReader reader, int column, bool full, long id,
        int response, PooledBuffer?[] bodies, Utf8JsonWriter?[] writers)
    {
        var flag = column + (full ? 7 : 6);
        var favorited = reader.GetBoolean(flag);
        var following = reader.GetBoolean(flag + 5);
        if (TryWrite(writer, id, response, favorited, following, bodies, writers))
            return;
        if (_fragments.Count >= Capacity)
        {
            Json.Article(writer, reader, column, full);
            return;
        }
        var part = Json.SharedArticle(writer, reader, column, full);
        _fragments.TryAdd(id, new Fragment(response, part.Start, part.Length, part.FavoriteAt, part.FollowingAt, favorited, following));
    }

    public void Comment(Utf8JsonWriter writer, NpgsqlDataReader reader, int column,
        int response, PooledBuffer?[] bodies, Utf8JsonWriter?[] writers)
    {
        var id = reader.GetInt64(column);
        var following = reader.GetBoolean(column + 7);
        if (TryWrite(writer, id, response, false, following, bodies, writers))
            return;
        if (_fragments.Count >= Capacity)
        {
            Json.Comment(writer, reader, column);
            return;
        }
        var part = Json.SharedComment(writer, reader, column);
        _fragments.TryAdd(id, new Fragment(response, part.Start, part.Length, -1, part.FollowingAt, false, following));
    }

    bool TryWrite(Utf8JsonWriter writer, long id, int response, bool favorited, bool following,
        PooledBuffer?[] bodies, Utf8JsonWriter?[] writers)
    {
        if (!_fragments.TryGetValue(id, out var part) || part.Response == response)
            return false;
        var source = bodies[part.Response]!;
        if (source.WrittenCount < part.Start + part.Length)
            writers[part.Response]!.Flush();
        var encoded = source.WrittenMemory.Span.Slice(part.Start, part.Length);
        if (favorited == part.Favorited && following == part.Following)
        {
            writer.WriteRawValue(encoded, skipInputValidation: true);
            return true;
        }
        var scratch = _scratch ??= new PooledBuffer(encoded.Length + 2);
        scratch.ResetWrittenCount();
        var position = 0;
        if (part.FavoriteAt >= 0)
            Replace(scratch, encoded, ref position, part.FavoriteAt - part.Start, part.Favorited, favorited);
        Replace(scratch, encoded, ref position, part.FollowingAt - part.Start, part.Following, following);
        Append(scratch, encoded[position..]);
        writer.WriteRawValue(scratch.WrittenMemory.Span, skipInputValidation: true);
        scratch.ResetWrittenCount();
        return true;
    }

    static void Replace(PooledBuffer scratch, ReadOnlySpan<byte> encoded, ref int position, int offset, bool previous, bool current)
    {
        Append(scratch, encoded[position..offset]);
        Append(scratch, current ? "true"u8 : "false"u8);
        position = offset + (previous ? 4 : 5);
    }

    static void Append(PooledBuffer buffer, ReadOnlySpan<byte> value)
    {
        value.CopyTo(buffer.GetSpan(value.Length));
        buffer.Advance(value.Length);
    }

    public void Clear()
    {
        _fragments.Clear();
        _scratch?.ResetWrittenCount();
    }

    public void Dispose()
    {
        _fragments.Clear();
        _scratch?.Dispose();
        _scratch = null;
    }
}
