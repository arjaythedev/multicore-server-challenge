package conduit.pg;

import conduit.http.Out;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/**
 * The binary-format rows one statement returned: the raw DataRow payloads, copied back to back. Read them with a
 * cursor: {@link #row(int)}, then the column getters in column order.
 */
public final class Rows {
    private byte[] buf = new byte[256];
    private int len;
    private int[] starts = new int[4];
    private int count;
    /** Rows affected, from the CommandComplete tag (INSERT/UPDATE/DELETE), or the row count for SELECT. */
    public long affected;

    private int pos;
    /** The current column's data offset and length (-1 for NULL), set by {@link #next()}. */
    private int off, n;

    void add(byte[] src, int from, int length) {
        if (count == starts.length) starts = Arrays.copyOf(starts, count * 2);
        if (len + length > buf.length) buf = Arrays.copyOf(buf, Math.max(buf.length * 2, len + length));
        System.arraycopy(src, from, buf, len, length);
        starts[count++] = len;
        len += length;
    }

    public int count() {
        return count;
    }

    /** Positions the cursor at the first column of row i. */
    public Rows row(int i) {
        pos = starts[i] + 2; // skip the int16 column count
        return this;
    }

    /** Advances to the next column; returns its length, or -1 for NULL. */
    private int next() {
        n = int32(buf, pos);
        off = pos + 4;
        pos = off + Math.max(n, 0);
        return n;
    }

    public Rows skip() {
        next();
        return this;
    }

    public boolean isNull() {
        return int32(buf, pos) < 0;
    }

    public long int8() {
        next();
        return int64(buf, off);
    }

    public int int4() {
        next();
        return int32(buf, off);
    }

    public boolean bool() {
        next();
        return buf[off] != 0;
    }

    public String text() {
        return next() < 0 ? null : new String(buf, off, n, StandardCharsets.UTF_8);
    }

    /** Writes a text column as a JSON string, or null. */
    public void json(Out o) {
        if (next() < 0) o.nul();
        else o.str(buf, off, n);
    }

    /** Writes a timestamptz column as a JSON timestamp string. */
    public void jsonTimestamp(Out o) {
        next();
        o.timestamp(int64(buf, off));
    }

    /** Writes a one-dimensional text[] column as a JSON array of strings. */
    public void jsonTextArray(Out o) {
        o.raw((byte) '[');
        if (next() > 0) {
            int p = off;
            int ndim = int32(buf, p);
            if (ndim > 0) {
                int items = int32(buf, p + 12);
                p += 20; // ndim, flags, element oid, dim length, lower bound
                for (int i = 0; i < items; i++) {
                    int l = int32(buf, p);
                    p += 4;
                    if (i > 0) o.raw((byte) ',');
                    if (l < 0) {
                        o.nul();
                    } else {
                        o.str(buf, p, l);
                        p += l;
                    }
                }
            }
        }
        o.raw((byte) ']');
    }

    static int int32(byte[] b, int p) {
        return (b[p] & 0xff) << 24 | (b[p + 1] & 0xff) << 16 | (b[p + 2] & 0xff) << 8 | b[p + 3] & 0xff;
    }

    static long int64(byte[] b, int p) {
        return (long) int32(b, p) << 32 | int32(b, p + 4) & 0xffffffffL;
    }
}
