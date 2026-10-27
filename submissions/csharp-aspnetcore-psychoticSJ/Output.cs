using System.Buffers;
using System.Globalization;
using System.Text.Json;
using Npgsql;

namespace ConduitChallenge;

sealed class PooledBuffer : IBufferWriter<byte>, IDisposable
{
    byte[]? _buffer;
    int _written;

    public PooledBuffer(int initialCapacity = 4096)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(initialCapacity);
        _buffer = ArrayPool<byte>.Shared.Rent(initialCapacity);
    }

    public ReadOnlyMemory<byte> WrittenMemory
    {
        get
        {
            ObjectDisposedException.ThrowIf(_buffer is null, this);
            return _buffer.AsMemory(0, _written);
        }
    }

    public int WrittenCount => _written;

    public void ResetWrittenCount()
    {
        ObjectDisposedException.ThrowIf(_buffer is null, this);
        _written = 0;
    }

    public void Advance(int count)
    {
        ObjectDisposedException.ThrowIf(_buffer is null, this);
        if (count < 0 || count > _buffer.Length - _written) throw new ArgumentOutOfRangeException(nameof(count));
        _written += count;
    }

    public Memory<byte> GetMemory(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _buffer.AsMemory(_written);
    }

    public Span<byte> GetSpan(int sizeHint = 0)
    {
        Ensure(sizeHint);
        return _buffer.AsSpan(_written);
    }

    void Ensure(int sizeHint)
    {
        ObjectDisposedException.ThrowIf(_buffer is null, this);
        ArgumentOutOfRangeException.ThrowIfNegative(sizeHint);
        if (sizeHint == 0) sizeHint = 1;
        if (sizeHint <= _buffer.Length - _written) return;
        var replacement = ArrayPool<byte>.Shared.Rent(checked(_written + Math.Max(sizeHint, _buffer.Length)));
        _buffer.AsSpan(0, _written).CopyTo(replacement);
        ArrayPool<byte>.Shared.Return(_buffer);
        _buffer = replacement;
    }

    public void Dispose()
    {
        var buffer = Interlocked.Exchange(ref _buffer, null);
        if (buffer is not null) ArrayPool<byte>.Shared.Return(buffer);
        _written = 0;
    }
}

sealed class ApiResult(int statusCode, PooledBuffer? body) : IDisposable
{
    public int StatusCode { get; set; } = statusCode;
    public PooledBuffer? Body { get; } = body;
    public void Dispose() => Body?.Dispose();
}

static class Json
{
    static readonly JsonEncodedText Username = JsonEncodedText.Encode("username");
    static readonly JsonEncodedText Bio = JsonEncodedText.Encode("bio");
    static readonly JsonEncodedText Image = JsonEncodedText.Encode("image");
    static readonly JsonEncodedText Following = JsonEncodedText.Encode("following");
    static readonly JsonEncodedText CreatedAt = JsonEncodedText.Encode("createdAt");
    static readonly JsonEncodedText UpdatedAt = JsonEncodedText.Encode("updatedAt");
    static readonly JsonEncodedText Slug = JsonEncodedText.Encode("slug");
    static readonly JsonEncodedText Title = JsonEncodedText.Encode("title");
    static readonly JsonEncodedText Description = JsonEncodedText.Encode("description");
    static readonly JsonEncodedText Body = JsonEncodedText.Encode("body");
    static readonly JsonEncodedText TagList = JsonEncodedText.Encode("tagList");
    static readonly JsonEncodedText Favorited = JsonEncodedText.Encode("favorited");
    static readonly JsonEncodedText FavoritesCount = JsonEncodedText.Encode("favoritesCount");
    static readonly JsonEncodedText Author = JsonEncodedText.Encode("author");

    public static ApiResult Error(int status, string message)
    {
        var buffer = new PooledBuffer(256);
        try
        {
            using var writer = new Utf8JsonWriter(buffer);
            writer.WriteStartObject();
            writer.WriteStartObject("errors"u8);
            writer.WriteStartArray("body"u8);
            writer.WriteStringValue(message);
            writer.WriteEndArray();
            writer.WriteEndObject();
            writer.WriteEndObject();
            writer.Flush();
            return new(status, buffer);
        }
        catch { buffer.Dispose(); throw; }
    }

    public static ApiResult User(long id, string email, string username, string? bio, string? image, string token, int status = 200)
    {
        var buffer = new PooledBuffer(512);
        try
        {
            using var writer = new Utf8JsonWriter(buffer);
            writer.WriteStartObject();
            writer.WriteStartObject("user"u8);
            writer.WriteString("email"u8, email);
            writer.WriteString("token"u8, token);
            writer.WriteString(Username, username);
            writer.WriteString(Bio, bio);
            writer.WriteString(Image, image);
            writer.WriteEndObject();
            writer.WriteEndObject();
            writer.Flush();
            return new(status, buffer);
        }
        catch { buffer.Dispose(); throw; }
    }

    public static ApiResult Profile(string username, string? bio, string? image, bool following, int status = 200)
    {
        var buffer = new PooledBuffer(512);
        try
        {
            using var writer = new Utf8JsonWriter(buffer);
            writer.WriteStartObject();
            writer.WritePropertyName("profile"u8);
            Profile(writer, username, bio, image, following);
            writer.WriteEndObject();
            writer.Flush();
            return new(status, buffer);
        }
        catch { buffer.Dispose(); throw; }
    }

    public static void Profile(Utf8JsonWriter writer, string username, string? bio, string? image, bool following)
    {
        writer.WriteStartObject();
        ProfileFields(writer, username, bio, image);
        writer.WriteBoolean(Following, following);
        writer.WriteEndObject();
    }

    static void ProfileFields(Utf8JsonWriter writer, string username, string? bio, string? image)
    {
        writer.WriteString(Username, username);
        writer.WriteString(Bio, bio);
        writer.WriteString(Image, image);
    }

    public static void Article(Utf8JsonWriter writer, NpgsqlDataReader reader, int start = 0, bool full = true)
    {
        writer.WriteStartObject();
        var column = ArticleFields(writer, reader, start, full);
        writer.WriteBoolean(Favorited, reader.GetBoolean(column++));
        writer.WriteNumber(FavoritesCount, reader.GetInt64(column++));
        writer.WritePropertyName(Author);
        Profile(writer, reader.GetString(column), NullableString(reader, column + 1), NullableString(reader, column + 2), reader.GetBoolean(column + 3));
        writer.WriteEndObject();
    }

    static int ArticleFields(Utf8JsonWriter writer, NpgsqlDataReader reader, int start, bool full)
    {
        writer.WriteString(Slug, reader.GetString(start));
        writer.WriteString(Title, reader.GetString(start + 1));
        writer.WriteString(Description, reader.GetString(start + 2));
        var column = start + 3;
        if (full) writer.WriteString(Body, reader.GetString(column++));
        writer.WriteStartArray(TagList);
        foreach (var tag in reader.GetFieldValue<string[]>(column++)) writer.WriteStringValue(tag);
        writer.WriteEndArray();
        Timestamp(writer, CreatedAt, reader.GetDateTime(column++));
        Timestamp(writer, UpdatedAt, reader.GetDateTime(column++));
        return column;
    }

    public static void Comment(Utf8JsonWriter writer, NpgsqlDataReader reader, int start = 0)
    {
        writer.WriteStartObject();
        CommentFields(writer, reader, start);
        writer.WritePropertyName(Author);
        Profile(writer, reader.GetString(start + 4), NullableString(reader, start + 5), NullableString(reader, start + 6), reader.GetBoolean(start + 7));
        writer.WriteEndObject();
    }

    static void CommentFields(Utf8JsonWriter writer, NpgsqlDataReader reader, int start)
    {
        writer.WriteNumber("id"u8, reader.GetInt64(start));
        writer.WriteString(Body, reader.GetString(start + 1));
        Timestamp(writer, CreatedAt, reader.GetDateTime(start + 2));
        Timestamp(writer, UpdatedAt, reader.GetDateTime(start + 3));
    }

    internal static (int Start, int Length, int FavoriteAt, int FollowingAt) SharedArticle(
        Utf8JsonWriter writer, NpgsqlDataReader reader, int column, bool full)
    {
        writer.WriteStartObject();
        var start = Position(writer) - 1;
        column = ArticleFields(writer, reader, column, full);
        var favoriteAt = Position(writer) + Favorited.EncodedUtf8Bytes.Length + 4;
        writer.WriteBoolean(Favorited, reader.GetBoolean(column++));
        writer.WriteNumber(FavoritesCount, reader.GetInt64(column++));
        writer.WritePropertyName(Author);
        writer.WriteStartObject();
        ProfileFields(writer, reader.GetString(column), NullableString(reader, column + 1), NullableString(reader, column + 2));
        var followingAt = Position(writer) + Following.EncodedUtf8Bytes.Length + 4;
        writer.WriteBoolean(Following, reader.GetBoolean(column + 3));
        writer.WriteEndObject();
        writer.WriteEndObject();
        return (start, Position(writer) - start, favoriteAt, followingAt);
    }

    internal static (int Start, int Length, int FavoriteAt, int FollowingAt) SharedComment(
        Utf8JsonWriter writer, NpgsqlDataReader reader, int column)
    {
        writer.WriteStartObject();
        var start = Position(writer) - 1;
        CommentFields(writer, reader, column);
        writer.WritePropertyName(Author);
        writer.WriteStartObject();
        ProfileFields(writer, reader.GetString(column + 4), NullableString(reader, column + 5), NullableString(reader, column + 6));
        var followingAt = Position(writer) + Following.EncodedUtf8Bytes.Length + 4;
        writer.WriteBoolean(Following, reader.GetBoolean(column + 7));
        writer.WriteEndObject();
        writer.WriteEndObject();
        return (start, Position(writer) - start, -1, followingAt);
    }

    static int Position(Utf8JsonWriter writer) => checked((int)(writer.BytesCommitted + writer.BytesPending));

    public static string? NullableString(NpgsqlDataReader reader, int column) => reader.IsDBNull(column) ? null : reader.GetString(column);

    public static void Timestamp(Utf8JsonWriter writer, JsonEncodedText property, DateTime value)
    {
        if (value.Kind == DateTimeKind.Local) value = value.ToUniversalTime();
        Span<char> text = stackalloc char[24];
        if (!value.TryFormat(text, out var length, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture)) throw new FormatException("Invalid timestamp.");
        writer.WriteString(property, text[..length]);
    }
}
