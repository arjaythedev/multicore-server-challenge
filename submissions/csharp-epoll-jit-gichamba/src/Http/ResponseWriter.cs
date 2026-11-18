using System.Collections.Concurrent;
using Conduit.Json;

namespace Conduit.Http;

/// <summary>
/// Builds one HTTP response in a single buffer. The JSON body is written after a reserved
/// headroom, and <see cref="Finish"/> writes the headers into the space just in front of it,
/// so the whole response is contiguous and goes out in one send.
/// </summary>
public sealed class ResponseWriter {
    /// <summary>Bytes reserved in front of the body; larger than the longest header block.</summary>
    public const int Headroom = 192;

    /// <summary>Writers whose buffer has grown past this many bytes are dropped, not pooled.</summary>
    private const int MaxPooledBytes = 1 << 20;
    /// <summary>Most idle writers kept in the pool.</summary>
    private const int MaxPooled = 1024;
    /// <summary>Idle writers waiting for reuse.</summary>
    private static readonly ConcurrentQueue<ResponseWriter> Pool = new();
    /// <summary>Writers in <see cref="Pool"/>. Counted here because ConcurrentQueue.Count walks the segments.</summary>
    private static int s_pooled;

    /// <summary>Creates a writer with a body ready to write.</summary>
    public ResponseWriter() {
        Body = new JsonWriter(4096);
        Body.Reset(Headroom);
    }

    /// <summary>The JSON body writer. Write the body here before calling <see cref="Finish"/>.</summary>
    public JsonWriter Body { get; }

    /// <summary>Takes a reset writer from the pool, or makes one.</summary>
    public static ResponseWriter Rent() {
        if (Pool.TryDequeue(out ResponseWriter? w)) {
            Interlocked.Decrement(ref s_pooled);
            w.Body.Reset(Headroom);
            return w;
        }
        return new ResponseWriter();
    }

    /// <summary>Returns a writer to the pool. Do not touch it or its Finish result afterwards.</summary>
    public static void Return(ResponseWriter w) {
        if (w.Body.Buffer.Length > MaxPooledBytes) {
            return;
        }

        if (Interlocked.Increment(ref s_pooled) <= MaxPooled) {
            Pool.Enqueue(w);
        } else {
            Interlocked.Decrement(ref s_pooled);
        }
    }

    /// <summary>Writes this writer's own body as {"errors":{"body":["message"]}}.</summary>
    public void WriteError(string message) {
        Body.Reset(Headroom);
        Body.StartObject();
        Body.PropertyName("errors"u8);
        Body.StartObject();
        Body.PropertyName("body"u8);
        Body.StartArray();
        Body.WriteString(message);
        Body.EndArray();
        Body.EndObject();
        Body.EndObject();
    }

    /// <summary>
    /// Writes the status line and headers in front of the body and returns the whole response.
    /// A 204 has no body and no Content-Type; any other status carries Content-Type: application/json
    /// and an exact Content-Length. The span is valid until the writer is reset or returned.
    /// </summary>
    public ReadOnlySpan<byte> Finish(int status) {
        byte[] buf = Body.Buffer;
        int end = Body.Length;
        int bodyLen = end - Headroom;

        Span<byte> head = stackalloc byte[Headroom];
        int n = 0;
        Append(head, ref n, StatusLine(status));
        if (status == 204) {
            Append(head, ref n, "\r\n"u8);
            bodyLen = 0;
            end = Headroom;
        } else {
            Append(head, ref n, "Content-Type: application/json\r\nContent-Length: "u8);
            bodyLen.TryFormat(head[n..], out int w, default, System.Globalization.CultureInfo.InvariantCulture);
            n += w;
            Append(head, ref n, "\r\n\r\n"u8);
        }

        int start = Headroom - n;
        head[..n].CopyTo(buf.AsSpan(start));
        return new ReadOnlySpan<byte>(buf, start, end - start);
    }

    /// <summary>Copies <paramref name="src"/> into <paramref name="dst"/> at offset <paramref name="n"/> and advances <paramref name="n"/>.</summary>
    private static void Append(Span<byte> dst, ref int n, ReadOnlySpan<byte> src) {
        src.CopyTo(dst[n..]);
        n += src.Length;
    }

    /// <summary>The HTTP/1.1 status line for a code; a code not listed gets the 500 line.</summary>
    private static ReadOnlySpan<byte> StatusLine(int status) => status switch {
        200 => "HTTP/1.1 200 OK\r\n"u8,
        201 => "HTTP/1.1 201 Created\r\n"u8,
        204 => "HTTP/1.1 204 No Content\r\n"u8,
        400 => "HTTP/1.1 400 Bad Request\r\n"u8,
        401 => "HTTP/1.1 401 Unauthorized\r\n"u8,
        403 => "HTTP/1.1 403 Forbidden\r\n"u8,
        404 => "HTTP/1.1 404 Not Found\r\n"u8,
        422 => "HTTP/1.1 422 Unprocessable Entity\r\n"u8,
        _ => "HTTP/1.1 500 Internal Server Error\r\n"u8,
    };
}
