package conduit.db;

import io.netty.buffer.ByteBuf;
import java.nio.charset.StandardCharsets;

/**
 * One DataRow message, read in place: every column is a slice of the connection's receive buffer, in Postgres's
 * binary format (all our statements ask for binary results). Only valid during the {@link PgQuery#onRow} call.
 *
 * <p>Binary formats: int8/int4 are big-endian integers, bool is one byte, text is UTF-8 bytes, timestamptz is an
 * int8 of microseconds since 2000-01-01 00:00:00 UTC, and arrays are described in {@link #forEachTextElement}.
 */
public final class Row {
    private ByteBuf data;
    private int[] offsets = new int[32];
    private int[] lengths = new int[32];
    private int columnCount;

    /** Reads the column table of a DataRow body: Int16 count, then per column Int32 length (-1 = NULL) and bytes. */
    void load(ByteBuf body) {
        data = body;
        int count = body.getUnsignedShort(body.readerIndex());
        if (count > offsets.length) {
            offsets = new int[count];
            lengths = new int[count];
        }
        int position = body.readerIndex() + 2;
        for (int column = 0; column < count; column++) {
            int length = body.getInt(position);
            position += 4;
            offsets[column] = position;
            lengths[column] = length;
            if (length > 0) position += length;
        }
        columnCount = count;
    }

    public int columnCount() {
        return columnCount;
    }

    public boolean isNull(int column) {
        return lengths[column] < 0;
    }

    public long getLong(int column) {
        return data.getLong(offsets[column]);
    }

    public int getInt(int column) {
        return data.getInt(offsets[column]);
    }

    public boolean getBoolean(int column) {
        return data.getByte(offsets[column]) != 0;
    }

    /** timestamptz: microseconds since 2000-01-01 00:00:00 UTC. */
    public long getTimestampMicros(int column) {
        return data.getLong(offsets[column]);
    }

    /** A text column as a Java string (null for NULL). The JSON writer copies text columns without this. */
    public String getString(int column) {
        if (lengths[column] < 0) return null;
        return data.toString(offsets[column], lengths[column], StandardCharsets.UTF_8);
    }

    public ByteBuf buffer() {
        return data;
    }

    public int offset(int column) {
        return offsets[column];
    }

    public int length(int column) {
        return lengths[column];
    }

    /** An int8[] column without NULL elements (binary array format: see {@link #forEachTextElement}). */
    public long[] getLongArray(int column) {
        int position = offsets[column];
        if (data.getInt(position) == 0) return new long[0];
        int count = data.getInt(position + 12);
        long[] values = new long[count];
        position += 20;
        for (int i = 0; i < count; i++) {
            values[i] = data.getLong(position + 4);          // each element: Int32 length (8), then the value
            position += 12;
        }
        return values;
    }

    /** Receives the elements of a text[] column as slices of the row: (buffer, offset, length; length -1 = NULL). */
    public interface TextElementConsumer {
        void accept(ByteBuf buffer, int offset, int length);
    }

    /**
     * Walks a one-dimensional text[] column. Binary array format: Int32 number of dimensions, Int32 has-nulls flag,
     * Int32 element type, then per dimension Int32 size and Int32 lower bound, then per element Int32 length
     * (-1 = NULL) and the bytes. An empty array has zero dimensions.
     */
    public void forEachTextElement(int column, TextElementConsumer consumer) {
        int position = offsets[column];
        int dimensions = data.getInt(position);
        if (dimensions == 0) return;
        int count = data.getInt(position + 12);
        position += 20;
        for (int element = 0; element < count; element++) {
            int length = data.getInt(position);
            position += 4;
            consumer.accept(data, position, length);
            if (length > 0) position += length;
        }
    }
}
