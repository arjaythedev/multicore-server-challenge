using System.Buffers.Binary;
using System.Text;

namespace Conduit.Pg;

/// <summary>Growable big-endian byte buffer used to build protocol messages.</summary>
internal sealed class PgWriter {
    /// <summary>The buffer. It doubles when full.</summary>
    private byte[] _buf = new byte[1024];
    /// <summary>Bytes written so far.</summary>
    private int _len;

    /// <summary>Number of bytes written.</summary>
    public int Length => _len;

    /// <summary>The bytes written so far.</summary>
    public ReadOnlySpan<byte> Written => new(_buf, 0, _len);

    /// <summary>Forgets the content but keeps the buffer.</summary>
    public void Clear() => _len = 0;

    /// <summary>Makes room for <paramref name="n"/> more bytes.</summary>
    private void Ensure(int n) {
        if (_len + n > _buf.Length) {
            Array.Resize(ref _buf, Math.Max(_buf.Length * 2, _len + n));
        }
    }

    /// <summary>Writes one byte.</summary>
    public void Byte(byte b) {
        Ensure(1);
        _buf[_len++] = b;
    }

    /// <summary>Writes a big-endian int16.</summary>
    public void Int16(short v) {
        Ensure(2);
        BinaryPrimitives.WriteInt16BigEndian(_buf.AsSpan(_len), v);
        _len += 2;
    }

    /// <summary>Writes a big-endian int32.</summary>
    public void Int32(int v) {
        Ensure(4);
        BinaryPrimitives.WriteInt32BigEndian(_buf.AsSpan(_len), v);
        _len += 4;
    }

    /// <summary>Writes a big-endian int64.</summary>
    public void Int64(long v) {
        Ensure(8);
        BinaryPrimitives.WriteInt64BigEndian(_buf.AsSpan(_len), v);
        _len += 8;
    }

    /// <summary>Writes raw bytes.</summary>
    public void Bytes(ReadOnlySpan<byte> data) {
        Ensure(data.Length);
        data.CopyTo(_buf.AsSpan(_len));
        _len += data.Length;
    }

    /// <summary>Writes the UTF-8 bytes of a string with no terminator and returns their count.</summary>
    public int Utf8(string s) {
        Ensure(Encoding.UTF8.GetMaxByteCount(s.Length));
        int n = Encoding.UTF8.GetBytes(s, _buf.AsSpan(_len));
        _len += n;
        return n;
    }

    /// <summary>Writes a string as UTF-8 followed by a NUL.</summary>
    public void CString(string s) {
        Utf8(s);
        Byte(0);
    }

    /// <summary>Starts a message: writes the type byte and a length placeholder. Returns the token for <see cref="EndMessage"/>.</summary>
    public int BeginMessage(byte type) {
        Byte(type);
        int at = _len;
        Int32(0);
        return at;
    }

    /// <summary>Starts an untyped message (the startup packet).</summary>
    public int BeginUntyped() {
        int at = _len;
        Int32(0);
        return at;
    }

    /// <summary>Fills in the length of the message started at <paramref name="at"/>.</summary>
    public void EndMessage(int at) => BinaryPrimitives.WriteInt32BigEndian(_buf.AsSpan(at), _len - at);

    /// <summary>Reserves four bytes for a length and returns their position.</summary>
    public int ReserveInt32() {
        int at = _len;
        Int32(0);
        return at;
    }

    /// <summary>Writes the number of bytes written after the reserved slot as that slot's value.</summary>
    public void PatchLengthSince(int slot) => BinaryPrimitives.WriteInt32BigEndian(_buf.AsSpan(slot), _len - slot - 4);
}
