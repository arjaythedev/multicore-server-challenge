using System.Buffers.Binary;

namespace Conduit.Pg;

/// <summary>One DataRow. Valid only inside the callback that receives it; the buffer is reused afterwards.</summary>
public readonly ref struct PgRow {
    /// <summary>The DataRow body.</summary>
    private readonly ReadOnlySpan<byte> _data;
    /// <summary>Per column: offset in <see cref="_data"/> and length (-1 for NULL).</summary>
    private readonly ReadOnlySpan<int> _layout;

    /// <summary>Wraps a body and its column layout. <see cref="Parse"/> is the way in.</summary>
    private PgRow(ReadOnlySpan<byte> data, ReadOnlySpan<int> layout) {
        _data = data;
        _layout = layout;
    }

    /// <summary>Number of columns.</summary>
    public int ColumnCount => _layout.Length / 2;

    /// <summary>True when column <paramref name="i"/> is SQL NULL.</summary>
    public bool IsNull(int i) => _layout[2 * i + 1] < 0;

    /// <summary>The binary bytes of column <paramref name="i"/>; empty for NULL.</summary>
    public ReadOnlySpan<byte> this[int i] => IsNull(i) ? default : _data.Slice(_layout[2 * i], _layout[2 * i + 1]);

    /// <summary>Indexes a DataRow body. <paramref name="scratch"/> holds the offsets and grows when needed.</summary>
    internal static PgRow Parse(ReadOnlySpan<byte> body, ref int[] scratch) {
        int n = BinaryPrimitives.ReadInt16BigEndian(body);
        if (scratch.Length < 2 * n) {
            scratch = new int[Math.Max(2 * n, scratch.Length * 2)];
        }

        int at = 2;
        for (int c = 0; c < n; c++) {
            if (at + 4 > body.Length) {
                throw new PgException("truncated DataRow");
            }

            int len = BinaryPrimitives.ReadInt32BigEndian(body[at..]);
            at += 4;
            scratch[2 * c] = at;
            scratch[2 * c + 1] = len;
            if (len > 0) {
                if (at + len > body.Length) {
                    throw new PgException("truncated DataRow");
                }

                at += len;
            }
        }
        return new PgRow(body, scratch.AsSpan(0, 2 * n));
    }
}
