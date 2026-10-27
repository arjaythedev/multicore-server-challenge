using System.Buffers.Binary;
using System.Text;

namespace Conduit.Pg;

/// <summary>Decoders for values in binary result format. Callers check <see cref="PgRow.IsNull"/> first.</summary>
public static class PgBinary {
    /// <summary>Reads an int2.</summary>
    public static short ReadInt2(ReadOnlySpan<byte> v) => BinaryPrimitives.ReadInt16BigEndian(v);

    /// <summary>Reads an int4.</summary>
    public static int ReadInt4(ReadOnlySpan<byte> v) => BinaryPrimitives.ReadInt32BigEndian(v);

    /// <summary>Reads an int8.</summary>
    public static long ReadInt8(ReadOnlySpan<byte> v) => BinaryPrimitives.ReadInt64BigEndian(v);

    /// <summary>Reads a bool.</summary>
    public static bool ReadBool(ReadOnlySpan<byte> v) => v[0] != 0;

    /// <summary>Reads text as a UTF-8 string.</summary>
    public static string ReadText(ReadOnlySpan<byte> v) => Encoding.UTF8.GetString(v);

    /// <summary>Reads a timestamptz as microseconds since 2000-01-01T00:00:00Z.</summary>
    public static long ReadTimestamptz(ReadOnlySpan<byte> v) => ReadInt8(v);

    /// <summary>Reads a one-dimensional text[]. NULL elements become null. Zero dimensions give an empty array.</summary>
    public static string?[] ReadTextArray(ReadOnlySpan<byte> v) => ReadArray(v, static item => Encoding.UTF8.GetString(item));

    /// <summary>Reads a one-dimensional text[] as the UTF-8 bytes of each element, for writing straight into JSON. NULL elements become null.</summary>
    public static byte[]?[] ReadTextArrayBytes(ReadOnlySpan<byte> v) => ReadArray(v, static item => item.ToArray());

    /// <summary>Converts one array element from its bytes.</summary>
    private delegate T ItemReader<T>(ReadOnlySpan<byte> item);

    /// <summary>
    /// Reads a one-dimensional binary array: dims, has-nulls flag, element oid, then length and lower bound, then the items.
    /// <paramref name="read"/> converts each non-NULL item; NULL items stay null. Zero dimensions give an empty array.
    /// </summary>
    /// <exception cref="PgException">The array has more than one dimension.</exception>
    private static T?[] ReadArray<T>(ReadOnlySpan<byte> v, ItemReader<T> read) where T : class {
        int dims = ReadInt4(v);
        if (dims == 0) {
            return [];
        }

        if (dims != 1) {
            throw new PgException("only one-dimensional arrays are supported");
        }

        int count = ReadInt4(v[12..]);
        T?[] result = new T?[count];
        int at = 20;
        for (int i = 0; i < count; i++) {
            int len = ReadInt4(v[at..]);
            at += 4;
            if (len < 0) {
                continue;
            }

            result[i] = read(v.Slice(at, len));
            at += len;
        }
        return result;
    }
}
