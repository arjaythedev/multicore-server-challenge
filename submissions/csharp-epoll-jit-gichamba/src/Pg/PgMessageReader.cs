using System.Buffers.Binary;

namespace Conduit.Pg;

/// <summary>Splits the transport's byte stream into backend messages without copying them.</summary>
internal sealed class PgMessageReader {
    /// <summary>The source of bytes.</summary>
    private readonly IPgTransport _transport;
    /// <summary>Receive buffer. It grows for a message larger than itself.</summary>
    private byte[] _buf = new byte[64 * 1024];
    /// <summary>Offset where the current message starts.</summary>
    private int _start;
    /// <summary>Offset just past the last received byte.</summary>
    private int _end;
    /// <summary>Size of the message the last <see cref="Next"/> returned. The next call skips it.</summary>
    private int _consumed;

    /// <summary>Reads from <paramref name="transport"/>.</summary>
    public PgMessageReader(IPgTransport transport) => _transport = transport;

    /// <summary>
    /// Blocks until a whole message is buffered. Returns its type byte; <paramref name="body"/> is the payload after the length.
    /// The body is valid until the next call. Transport errors propagate.
    /// </summary>
    public byte Next(out ReadOnlySpan<byte> body) {
        _start += _consumed;
        _consumed = 0;
        int need = 5;
        while (true) {
            int avail = _end - _start;
            if (avail >= 5) {
                int len = BinaryPrimitives.ReadInt32BigEndian(_buf.AsSpan(_start + 1));
                if (len < 4) {
                    throw new PgException("bad message length " + len);
                }

                need = len + 1;
                if (avail >= need) {
                    _consumed = need;
                    body = _buf.AsSpan(_start + 5, len - 4);
                    return _buf[_start];
                }
            }
            if (_start > 0) {
                Buffer.BlockCopy(_buf, _start, _buf, 0, avail);
                _start = 0;
                _end = avail;
            }
            if (_buf.Length < need) {
                Array.Resize(ref _buf, Math.Max(need, _buf.Length * 2));
            }

            _end += _transport.Read(_buf.AsSpan(_end));
        }
    }
}
