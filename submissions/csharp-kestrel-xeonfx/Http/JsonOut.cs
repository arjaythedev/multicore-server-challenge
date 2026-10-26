using System;
using System.Buffers;
using System.Collections.Concurrent;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading;

namespace Conduit.Http;

/// <summary>
/// A pooled response buffer with its JSON writer. Responses are buffered so they carry a Content-Length.
/// Disposing it returns it to the pool.
/// </summary>
public sealed class JsonOut : IDisposable
{
    static readonly ConcurrentQueue<JsonOut> Pool = new();
    static long _pooledBytes;

    /// <summary>The most the pool keeps (2,048 buffers of the usual size); buffers returned beyond it are dropped,
    /// so a burst doesn't keep its memory for good.</summary>
    public const long MaxPooledBytes = 32 << 20;
    static readonly JsonWriterOptions Options = new()
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, // escapes only what JSON requires; UTF-8 passes through
        SkipValidation = true,
    };

    readonly ArrayBufferWriter<byte> _buf = new(16 * 1024);
    public readonly Utf8JsonWriter W;

    JsonOut() => W = new Utf8JsonWriter(_buf, Options);

    /// <summary>The capacity of the buffers waiting in the pool.</summary>
    public static long PooledBytes => Volatile.Read(ref _pooledBytes);

    public static JsonOut Rent()
    {
        if (!Pool.TryDequeue(out var j)) return new JsonOut();
        Interlocked.Add(ref _pooledBytes, -j._buf.Capacity);
        return j;
    }

    public ReadOnlySpan<byte> Written
    {
        get { W.Flush(); return _buf.WrittenSpan; }
    }

    public void Dispose()
    {
        W.Reset(_buf);
        _buf.ResetWrittenCount();
        int capacity = _buf.Capacity;
        if (capacity > 1 << 20) return; // let a rare huge response's buffer go
        if (Interlocked.Add(ref _pooledBytes, capacity) > MaxPooledBytes) Interlocked.Add(ref _pooledBytes, -capacity);
        else Pool.Enqueue(this);
    }
}
