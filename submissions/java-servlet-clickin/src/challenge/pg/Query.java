package challenge.pg;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Arrays;

/**
 * Reusable query parameters and PostgreSQL DataRow storage. Owned by one
 * caller.
 */
public final class Query {
    public int statementId;
    public boolean write;
    public String sqlState;
    public String errorMessage;
    public long commandRowCount = -1;
    private static final int MAX_RETAINED_BYTES = 64 * 1024;
    private final int initialColumns;
    private byte[] params = new byte[256];
    private byte[] rows;
    private int paramLength;
    private int paramCount;
    private int rowLength;
    private int rowCount;
    private int columnCount;
    private int[] rowOffsets;
    private int[] columnOffsets;
    private int[] columnLengths;

    public Query(int statementId, boolean write) {
        this.statementId = statementId;
        this.write = write;
        boolean page = Stmt.page(statementId);
        rows = new byte[1024];
        rowOffsets = new int[16];
        initialColumns = page ? 224 : 64;
        columnOffsets = new int[initialColumns];
        columnLengths = new int[initialColumns];
    }

    public void prepare(int statementId, boolean write) {
        reset();
        this.statementId = statementId;
        this.write = write;
    }

    public void reset() {
        clearResults();
        paramLength = paramCount = 0;
        if (params.length > MAX_RETAINED_BYTES) {
            params = new byte[256];
        }
        if (rows.length > MAX_RETAINED_BYTES) {
            rows = new byte[1024];
        }
        if (rowOffsets.length > MAX_RETAINED_BYTES / Integer.BYTES) {
            rowOffsets = new int[16];
        }
        if (columnOffsets.length > MAX_RETAINED_BYTES / Integer.BYTES) {
            columnOffsets = new int[initialColumns];
            columnLengths = new int[initialColumns];
        }
    }

    void clearResults() {
        sqlState = errorMessage = null;
        commandRowCount = -1;
        rowLength = rowCount = columnCount = 0;
    }

    public int parameterCount() {
        return paramCount;
    }

    public byte[] parameterBytes() {
        return params;
    }

    public int parameterLength() {
        return paramLength;
    }

    private void reserveParam(int n) {
        if (n > params.length - paramLength) {
            params = Arrays.copyOf(params,
                    Math.max(Math.addExact(paramLength, n), params.length * 2));
        }
    }

    private void putInt(int value) {
        reserveParam(4);
        for (int i = 3; i >= 0; i--) {
            params[paramLength++] = (byte) (value >>> (i * 8));
        }
    }

    private void putLong(long value) {
        reserveParam(8);
        for (int i = 7; i >= 0; i--) {
            params[paramLength++] = (byte) (value >>> (i * 8));
        }
    }

    public Query nullParam() {
        putInt(-1);
        paramCount++;
        return this;
    }

    public Query int4(int value) {
        putInt(4);
        putInt(value);
        paramCount++;
        return this;
    }

    public Query int8(long value) {
        putInt(8);
        putLong(value);
        paramCount++;
        return this;
    }

    public Query bool(boolean value) {
        putInt(1);
        reserveParam(1);
        params[paramLength++] = (byte) (value ? 1 : 0);
        paramCount++;
        return this;
    }

    public Query text(String value) {
        if (value == null) {
            return nullParam();
        }
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        return text(bytes, 0, bytes.length);
    }

    public Query text(byte[] bytes, int offset, int length) {
        if (offset < 0 || length < 0 || offset > bytes.length - length) {
            throw new IndexOutOfBoundsException();
        }
        putInt(length);
        reserveParam(length);
        System.arraycopy(bytes, offset, params, paramLength, length);
        paramLength += length;
        paramCount++;
        return this;
    }

    public Query textArray(String[] values) {
        if (values == null) {
            return nullParam();
        }
        int lenAt = paramLength;
        putInt(0);
        int start = paramLength;
        putInt(1);
        putInt(0);
        putInt(25);
        putInt(values.length);
        putInt(1);
        for (String value : values) {
            if (value == null) {
                throw new IllegalArgumentException("null array element");
            }
            byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
            putInt(bytes.length);
            reserveParam(bytes.length);
            System.arraycopy(bytes, 0, params, paramLength, bytes.length);
            paramLength += bytes.length;
        }
        int len = paramLength - start;
        for (int i = 0; i < 4; i++) {
            params[lenAt + i] = (byte) (len >>> (24 - i * 8));
        }
        paramCount++;
        return this;
    }

    public Query int8Array(long[] values) {
        if (values == null) {
            return nullParam();
        }
        putInt(Math.addExact(20, Math.multiplyExact(values.length, 12)));
        putInt(1);
        putInt(0);
        putInt(20);
        putInt(values.length);
        putInt(1);
        for (long value : values) {
            putInt(8);
            putLong(value);
        }
        paramCount++;
        return this;
    }

    void reserveBatch(int max) {
        params = new byte[Math.max(256, Math.multiplyExact(max, 64))];
    }

    void batchParams(Unit[] units, int[] indexes, int count,
                     int[] sourceParams, int[] elementTypes) {
        reset();
        for (int col = 0; col < sourceParams.length; col++) {
            int lenAt = paramLength;
            putInt(0);
            int start = paramLength;
            putInt(1);
            putInt(1);
            putInt(elementTypes[col]);
            putInt(count);
            putInt(1);
            for (int i = 0; i < count; i++) {
                Query q = units[indexes[i]].queries[0];
                byte[] b = q.params;
                int p = 0;
                for (int j = 0; j < sourceParams[col]; j++) {
                    int n = readInt(b, p);
                    p += 4 + Math.max(n, 0);
                }
                int n = readInt(b, p);
                putInt(n);
                if (n >= 0) {
                    reserveParam(n);
                    System.arraycopy(b, p + 4, params, paramLength, n);
                    paramLength += n;
                }
            }
            int len = paramLength - start;
            for (int i = 0; i < 4; i++) {
                params[lenAt + i] = (byte) (len >>> (24 - i * 8));
            }
            paramCount++;
        }
    }

    void appendTaggedRow(byte[] data, int offset, int length) {
        if (length < 10 || readInt(data, offset + 2) != 4) {
            throw new IllegalArgumentException("invalid row tag");
        }
        int cols = ((data[offset] & 255) << 8 | data[offset + 1] & 255) - 1;
        data[offset + 8] = (byte) (cols >>> 8);
        data[offset + 9] = (byte) cols;
        appendRow(data, offset + 8, length - 8);
    }

    /** Append the body of a DataRow message, including its column count. */
    public void appendRow(byte[] data, int offset, int length) {
        if (offset < 0 || length < 2 || offset > data.length - length) {
            throw new IllegalArgumentException("DataRow bounds");
        }
        int end = offset + length;
        int cols = (data[offset] & 255) << 8 | data[offset + 1] & 255;
        int p = offset + 2;
        for (int i = 0; i < cols; i++) {
            if (end - p < 4) {
                throw new IllegalArgumentException("short DataRow");
            }
            int n = readInt(data, p);
            p += 4;
            if (n < -1 || n > end - p) {
                throw new IllegalArgumentException("invalid column length");
            }
            if (n >= 0) {
                p += n;
            }
        }
        if (p != end) {
            throw new IllegalArgumentException("extra DataRow bytes");
        }
        if (rowLength + length > rows.length) {
            rows = Arrays.copyOf(rows,
                    Math.max(rowLength + length, rows.length * 2));
        }
        if (rowCount == rowOffsets.length) {
            rowOffsets = Arrays.copyOf(rowOffsets, rowOffsets.length * 2);
        }
        if (columnCount + cols > columnOffsets.length) {
            int size = Math.max(columnCount + cols, columnOffsets.length * 2);
            columnOffsets = Arrays.copyOf(columnOffsets, size);
            columnLengths = Arrays.copyOf(columnLengths, size);
        }
        rowOffsets[rowCount++] = columnCount;
        System.arraycopy(data, offset, rows, rowLength, length);
        p = offset + 2;
        for (int i = 0; i < cols; i++) {
            int n = readInt(data, p);
            p += 4;
            columnOffsets[columnCount] = rowLength + p - offset;
            columnLengths[columnCount++] = n;
            if (n >= 0) {
                p += n;
            }
        }
        rowLength += length;
    }

    public int rowCount() {
        return rowCount;
    }

    public int columns(int row) {
        checkRow(row);
        return (row + 1 == rowCount ? columnCount : rowOffsets[row + 1]) - rowOffsets[row];
    }

    private void checkRow(int row) {
        if (row < 0 || row >= rowCount) {
            throw new IndexOutOfBoundsException();
        }
    }

    private int col(int row, int column) {
        if (column < 0 || column >= columns(row)) {
            throw new IndexOutOfBoundsException();
        }
        return rowOffsets[row] + column;
    }

    public int length(int row, int column) {
        return columnLengths[col(row, column)];
    }

    public int offset(int row, int column) {
        return columnOffsets[col(row, column)];
    }

    public byte[] bytes() {
        return rows;
    }

    public boolean isNull(int row, int column) {
        return length(row, column) < 0;
    }

    private int require(int row, int column, int len) {
        int c = col(row, column);
        if (columnLengths[c] != len) {
            throw new IllegalStateException("unexpected column length");
        }
        return columnOffsets[c];
    }

    public int int4At(int row, int column) {
        return readInt(rows, require(row, column, 4));
    }

    public long int8At(int row, int column) {
        int p = require(row, column, 8);
        return (long) readInt(rows, p) << 32 | readInt(rows, p + 4) & 0xffffffffL;
    }

    public boolean boolAt(int row, int column) {
        int p = require(row, column, 1);
        if (rows[p] != 0 && rows[p] != 1) {
            throw new IllegalStateException("invalid boolean");
        }
        return rows[p] == 1;
    }

    public String timestampAt(int row, int column) {
        long micros = int8At(row, column);
        long seconds = Math.floorDiv(micros, 1_000_000) + 946684800L;
        return DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'")
                .withZone(ZoneOffset.UTC)
                .format(Instant.ofEpochSecond(seconds, Math.floorMod(micros, 1_000_000) * 1000));
    }

    public int arrayCount(int row, int column) {
        int p = offset(row, column);
        int n = length(row, column);
        if (n < 12) {
            throw new IllegalStateException("invalid array");
        }
        int dims = readInt(rows, p);
        if (dims == 0) {
            return 0;
        }
        if (dims != 1 || n < 20 || readInt(rows, p + 8) != 25) {
            throw new IllegalStateException("expected text array");
        }
        int count = readInt(rows, p + 12);
        if (count < 0) {
            throw new IllegalStateException("invalid array count");
        }
        return count;
    }

    /** Returns the byte offset of an array element, or -1 for SQL NULL. */
    public int arrayElementOffset(int row, int column, int index) {
        int count = arrayCount(row, column);
        int p = offset(row, column) + 20;
        int end = offset(row, column) + length(row, column);
        if (index < 0 || index >= count) {
            throw new IndexOutOfBoundsException();
        }
        for (int i = 0; i <= index; i++) {
            if (end - p < 4) {
                throw new IllegalStateException("short array");
            }
            int n = readInt(rows, p);
            p += 4;
            if (n < -1 || n > end - p) {
                throw new IllegalStateException("invalid array element");
            }
            if (i == index) {
                return n == -1 ? -1 : p;
            }
            if (n >= 0) {
                p += n;
            }
        }
        throw new AssertionError();
    }

    public int arrayElementLength(int elementOffset) {
        if (elementOffset < 0) {
            return -1;
        }
        return readInt(rows, elementOffset - 4);
    }

    private static int readInt(byte[] b, int p) {
        return (b[p] & 255) << 24
                | (b[p + 1] & 255) << 16
                | (b[p + 2] & 255) << 8
                | b[p + 3] & 255;
    }
}
