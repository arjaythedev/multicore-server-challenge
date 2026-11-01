namespace Conduit.Pg;

/// <summary>Binary-encoded Bind parameters for one statement. Reusable through <see cref="Clear"/>.</summary>
public sealed class PgParams {
    /// <summary>Holds the encoded values.</summary>
    private readonly PgWriter _w = new();

    /// <summary>Number of parameters added.</summary>
    public int Count { get; private set; }

    /// <summary>The encoded values: for each parameter an int32 length (-1 for NULL) followed by the bytes.</summary>
    internal ReadOnlySpan<byte> Values => _w.Written;

    /// <summary>Removes all parameters.</summary>
    public void Clear() {
        _w.Clear();
        Count = 0;
    }

    /// <summary>Adds an int4.</summary>
    public void AddInt4(int v) {
        _w.Int32(4);
        _w.Int32(v);
        Count++;
    }

    /// <summary>Adds an int8.</summary>
    public void AddInt8(long v) {
        _w.Int32(8);
        _w.Int64(v);
        Count++;
    }

    /// <summary>Adds a bool.</summary>
    public void AddBool(bool v) {
        _w.Int32(1);
        _w.Byte(v ? (byte)1 : (byte)0);
        Count++;
    }

    /// <summary>Adds text from a string, as UTF-8.</summary>
    public void AddText(string v) {
        int slot = _w.ReserveInt32();
        _w.Utf8(v);
        _w.PatchLengthSince(slot);
        Count++;
    }

    /// <summary>Adds a SQL NULL.</summary>
    public void AddNull() {
        _w.Int32(-1);
        Count++;
    }

    /// <summary>Adds a one-dimensional text[]. An empty array is sent with zero dimensions.</summary>
    public void AddTextArray(ReadOnlySpan<string> items) {
        int slot = _w.ReserveInt32();
        ArrayHeader(PgOid.Text, items.Length);
        foreach (string s in items) {
            int elem = _w.ReserveInt32();
            _w.Utf8(s);
            _w.PatchLengthSince(elem);
        }
        _w.PatchLengthSince(slot);
        Count++;
    }

    /// <summary>Adds a one-dimensional int8[]. An empty array is sent with zero dimensions.</summary>
    public void AddInt8Array(ReadOnlySpan<long> items) {
        int slot = _w.ReserveInt32();
        ArrayHeader(PgOid.Int8, items.Length);
        foreach (long v in items) {
            _w.Int32(8);
            _w.Int64(v);
        }
        _w.PatchLengthSince(slot);
        Count++;
    }

    /// <summary>
    /// Writes the array wire header: dimensions, has-null flag, element OID, then length and lower bound per dimension.
    /// An empty array has zero dimensions, which Postgres reads as '{}'.
    /// </summary>
    private void ArrayHeader(uint elementOid, int length) {
        _w.Int32(length == 0 ? 0 : 1);
        _w.Int32(0);
        _w.Int32((int)elementOid);
        if (length == 0) {
            return;
        }

        _w.Int32(length);
        _w.Int32(1);
    }
}
