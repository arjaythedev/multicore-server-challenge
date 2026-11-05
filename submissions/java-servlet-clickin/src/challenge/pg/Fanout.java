package challenge.pg;

import java.util.Arrays;

/**
 * Rebuilds a batch's per-request rows from shared rows. A list or comments
 * batch returns every distinct article (or comment) once, tagged 0, and one row
 * per request with what is the request's own: the page's ids and the viewer's
 * favorited / followed ids among them. Each request gets exactly the rows its
 * single statement would return, so the views read them as before. Nothing
 * outlives the statement: the rows are dropped at its CommandComplete.
 */
final class Fanout {
    /** How a batch's rows are shaped; NONE: rows are already per request. */
    enum Shape {
        NONE(0, 0),
        /**
         * shared: 0,id,slug,title,description,created,updated,tag ids,count,username,bio,image,author_id + 4 nulls;
         * after the requests' rows, the tags table: -1,id,name + 14 nulls, in name order.
         */
        LIST(17, 14),
        /** as LIST, but every listed author is followed (the feed walks only followees). */
        FEED(17, 14),
        /**
         * shared: 0,article_id,id,body,created,updated + 3 nulls,author_id,null (each thread's rows together,
         * newest first); after the requests' rows, each author: -1,id + 4 nulls,username,bio,image + 2 nulls.
         */
        COMMENTS(11, 8);

        /** Columns of a returned row, and of a rebuilt row (without the tag). */
        final int columns;

        final int rebuilt;

        Shape(int columns, int rebuilt) {
            this.columns = columns;
            this.rebuilt = rebuilt;
        }
    }

    // an empty page's row: id..updated null, tags '{}', count 0, favorited false, username..image null, following false
    private static final byte[] EMPTY_TEXT_ARRAY = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 25};
    private byte[] rows = new byte[1 << 16];
    private int length;
    private int[] starts = new int[256];
    private int count;
    private long[] keys = new long[1024];
    // row index + 1 of the key's (first) shared row; 0: empty slot
    private int[] values = new int[1024];
    private final int[] columnAt = new int[17];
    // a list batch's tags rows: tag id to rank (name order) + 1, and rank to the row holding its name
    private int[] rankOf = new int[256];
    private int[] nameRow = new int[256];
    private int[] ranks = new int[16];
    private byte[] out = new byte[1024];
    private int outLength;

    void add(byte[] data, int at, int end) {
        int n = end - at;
        if (n > rows.length - length) {
            rows = Arrays.copyOf(rows, Math.max(length + n, rows.length * 2));
        }
        if (count == starts.length) {
            starts = Arrays.copyOf(starts, count * 2);
        }
        System.arraycopy(data, at, rows, length, n);
        starts[count++] = length;
        length += n;
    }

    void reset() {
        length = count = 0;
    }

    /** Hands each request of the batch its rows; {@code units[indexes[i]]} is request i + 1. */
    void finish(Shape shape, Unit[] units, int[] indexes, int requests) {
        try {
            int shared = 0;
            while (shared < count && tag(shared) == 0) {
                shared++;
            }
            int end = count;
            while (end > shared && tag(end - 1) == -1) {
                end--;
            }
            if (shape == Shape.COMMENTS) {
                indexAuthors(end);
            } else {
                nameTags(shared, end);
            }
            index(shape, shared);
            for (int r = shared; r < end; r++) {
                int i = tag(r) - 1;
                if (i < 0 || i >= requests) {
                    throw new IllegalStateException("fanout row tag out of range");
                }
                Query q = units[indexes[i]].queries[0];
                if (shape == Shape.COMMENTS) {
                    comments(r, q);
                } else {
                    page(shape, r, q);
                }
            }
        } finally {
            reset();
        }
    }

    /**
     * Rewrites each shared row's tag ids (column 7, int4[]) as the text[] of
     * their names in name order: the array the single statement returns. The
     * names come from this batch's tags rows ({@code [end, count)}).
     */
    private void nameTags(int shared, int end) {
        int tags = count - end;
        Arrays.fill(rankOf, 0);
        for (int k = 0; k < tags; k++) {
            columns(end + k, Shape.LIST.columns);
            long id = int8(1);
            if (id < 0 || id >= 1 << 24) {
                throw new IllegalStateException("tag id out of range");
            }
            if (id >= rankOf.length) {
                rankOf = Arrays.copyOf(rankOf, Math.max((int) id + 1, rankOf.length * 2));
            }
            if (k == nameRow.length) {
                nameRow = Arrays.copyOf(nameRow, k * 2);
            }
            rankOf[(int) id] = k + 1;
            nameRow[k] = end + k;
        }
        for (int row = 0; row < shared; row++) {
            columns(row, Shape.LIST.columns);
            int at = columnAt[7];
            int n = arrayCount4(at);
            if (n > ranks.length) {
                ranks = Arrays.copyOf(ranks, Math.max(n, ranks.length * 2));
            }
            for (int e = 0; e < n; e++) {
                int p = at + 24 + e * 8;
                if (readInt(rows, p) != 4) {
                    throw new IllegalStateException("null tag id");
                }
                int id = readInt(rows, p + 4);
                int rank = id >= 0 && id < rankOf.length ? rankOf[id] - 1 : -1;
                if (rank < 0) {
                    throw new IllegalStateException("tag missing from the batch's tags rows");
                }
                ranks[e] = rank;
            }
            Arrays.sort(ranks, 0, n);
            // the row again, with the names in place of the ids, appended to rows and pointed at
            begin(Shape.LIST.columns);
            putRaw(rows, starts[row] + 2, at);
            if (n == 0) {
                putColumn(EMPTY_TEXT_ARRAY, 0, EMPTY_TEXT_ARRAY.length);
            } else {
                int size = 20;
                for (int e = 0; e < n; e++) {
                    size += 4 + nameLength(ranks[e]);
                }
                putInt(size);
                putInt(1);
                putInt(0);
                putInt(25);
                putInt(n);
                putInt(1);
                for (int e = 0; e < n; e++) {
                    columns(nameRow[ranks[e]], Shape.LIST.columns);
                    putRaw(rows, columnAt[2], columnEnd(2));
                }
                columns(row, Shape.LIST.columns);
            }
            putRaw(rows, columnEnd(7), starts[row] + rowLength(row));
            int p = length;
            add(out, 0, outLength);
            count--;
            starts[row] = p;
        }
    }

    private int nameLength(int rank) {
        columns(nameRow[rank], Shape.LIST.columns);
        int n = readInt(rows, columnAt[2]);
        if (n < 0) {
            throw new IllegalStateException("null tag name");
        }
        return n;
    }

    /** Bytes of a row as stored (column count and columns). */
    private int rowLength(int row) {
        int p = starts[row];
        int n = (rows[p] & 255) << 8 | rows[p + 1] & 255;
        int q = p + 2;
        for (int c = 0; c < n; c++) {
            q += 4 + Math.max(readInt(rows, q), 0);
        }
        return q - p;
    }

    // binary int4[]: as int8[] with (length 4, value) pairs
    private int arrayCount4(int at) {
        int n = readInt(rows, at);
        if (n < 12) {
            throw new IllegalStateException("invalid int4 array");
        }
        int dims = readInt(rows, at + 4);
        if (dims == 0) {
            return 0;
        }
        if (dims != 1 || readInt(rows, at + 12) != 23 || n != 20 + readInt(rows, at + 16) * 8) {
            throw new IllegalStateException("expected int4 array");
        }
        return readInt(rows, at + 16);
    }

    private int tag(int row) {
        int p = starts[row];
        if (readInt(rows, p + 2) != 4) {
            throw new IllegalStateException("invalid fanout row tag");
        }
        return readInt(rows, p + 6);
    }

    /** Offsets (length prefix) of a row's columns into columnAt. */
    private void columns(int row, int expected) {
        int p = starts[row];
        int n = (rows[p] & 255) << 8 | rows[p + 1] & 255;
        if (n != expected) {
            throw new IllegalStateException("unexpected fanout row width");
        }
        p += 2;
        for (int c = 0; c < n; c++) {
            columnAt[c] = p;
            p += 4 + Math.max(readInt(rows, p), 0);
        }
    }

    private int columnEnd(int column) {
        int p = columnAt[column];
        return p + 4 + Math.max(readInt(rows, p), 0);
    }

    private long int8(int column) {
        int p = columnAt[column];
        if (readInt(rows, p) != 8) {
            throw new IllegalStateException("expected int8");
        }
        return readLong(rows, p + 4);
    }

    /** Maps each shared row's key (article id) to its first row. */
    private void index(Shape shape, int shared) {
        int capacity = Integer.highestOneBit(Math.max(shared, 1) * 2) * 2;
        if (keys.length < capacity) {
            keys = new long[capacity];
            values = new int[capacity];
        } else {
            Arrays.fill(values, 0);
        }
        int mask = keys.length - 1;
        for (int row = 0; row < shared; row++) {
            columns(row, shape.columns);
            long key = int8(1);
            int slot = slot(key, mask);
            while (values[slot] != 0 && keys[slot] != key) {
                slot = slot + 1 & mask;
            }
            if (values[slot] == 0) {
                keys[slot] = key;
                values[slot] = row + 1;
            }
        }
    }

    // a comments batch's authors: user id to row index + 1
    private long[] authorKeys = new long[1024];
    private int[] authorValues = new int[1024];

    private void indexAuthors(int end) {
        int capacity = Integer.highestOneBit(Math.max(count - end, 1) * 2) * 2;
        if (authorKeys.length < capacity) {
            authorKeys = new long[capacity];
            authorValues = new int[capacity];
        } else {
            Arrays.fill(authorValues, 0);
        }
        int mask = authorKeys.length - 1;
        for (int row = end; row < count; row++) {
            columns(row, Shape.COMMENTS.columns);
            long key = int8(1);
            int slot = slot(key, mask);
            while (authorValues[slot] != 0 && authorKeys[slot] != key) {
                slot = slot + 1 & mask;
            }
            authorKeys[slot] = key;
            authorValues[slot] = row + 1;
        }
    }

    private int findAuthor(long key) {
        int mask = authorKeys.length - 1;
        int slot = slot(key, mask);
        while (authorValues[slot] != 0) {
            if (authorKeys[slot] == key) {
                return authorValues[slot] - 1;
            }
            slot = slot + 1 & mask;
        }
        return -1;
    }

    private int find(long key) {
        int mask = keys.length - 1;
        int slot = slot(key, mask);
        while (values[slot] != 0) {
            if (keys[slot] == key) {
                return values[slot] - 1;
            }
            slot = slot + 1 & mask;
        }
        return -1;
    }

    private static int slot(long key, int mask) {
        long h = key * 0x9E3779B97F4A7C15L;
        return (int) (h ^ h >>> 32) & mask;
    }

    /** One request of a list or feed: its page's rows, or the empty page's row. */
    private void page(Shape shape, int r, Query q) {
        columns(r, shape.columns);
        int ids = columnAt[13];
        int fav = columnAt[14];
        int fol = columnAt[15];
        int nAt = columnAt[16];
        int nEnd = columnEnd(16);
        int idCount = arrayCount(ids);
        if (idCount == 0) {
            begin(shape.rebuilt);
            for (int c = 0; c < 6; c++) {
                putNull();
            }
            putColumn(EMPTY_TEXT_ARRAY, 0, EMPTY_TEXT_ARRAY.length);
            putInt(8);
            putLong(0);
            putBool(false);
            putNull();
            putNull();
            putNull();
            putBool(false);
            putRaw(rows, nAt, nEnd);
            q.appendRow(out, 0, outLength);
            return;
        }
        for (int e = 0; e < idCount; e++) {
            long id = arrayInt8(ids, e);
            boolean favorited = contains(fav, id);
            int row = find(id);
            if (row < 0) {
                throw new IllegalStateException("fanout article missing");
            }
            columns(row, shape.columns);
            boolean following = shape == Shape.FEED || contains(fol, int8(12));
            begin(shape.rebuilt);
            putRaw(rows, columnAt[1], columnEnd(8));
            putBool(favorited);
            putRaw(rows, columnAt[9], columnEnd(11));
            putBool(following);
            putRaw(rows, nAt, nEnd);
            q.appendRow(out, 0, outLength);
        }
    }

    /** One request of a comments batch: its article's comment rows. */
    private void comments(int r, Query q) {
        columns(r, Shape.COMMENTS.columns);
        long article = int8(1);
        int fol = columnAt[10];
        int first = find(article);
        if (first < 0) {
            throw new IllegalStateException("fanout comments missing");
        }
        for (int row = first; row < count; row++) {
            columns(row, Shape.COMMENTS.columns);
            if (tag(row) != 0 || int8(1) != article) {
                break;
            }
            boolean authored = readInt(rows, columnAt[9]) == 8;
            long author = authored ? readLong(rows, columnAt[9] + 4) : 0;
            boolean following = authored && contains(fol, author);
            begin(Shape.COMMENTS.rebuilt);
            putRaw(rows, columnAt[2], columnEnd(5));
            if (authored) {
                int user = findAuthor(author);
                if (user < 0) {
                    throw new IllegalStateException("fanout comment author missing");
                }
                columns(user, Shape.COMMENTS.columns);
                putRaw(rows, columnAt[6], columnEnd(8));
                columns(row, Shape.COMMENTS.columns);
            } else {
                putNull();
                putNull();
                putNull();
            }
            putBool(following);
            q.appendRow(out, 0, outLength);
        }
    }

    // binary int8[]: ndim, flags, element oid, then (ndim 1) size, lower bound and (length, value) pairs
    private int arrayCount(int at) {
        int n = readInt(rows, at);
        if (n < 0) {
            return 0;
        }
        if (n < 12) {
            throw new IllegalStateException("invalid int8 array");
        }
        int dims = readInt(rows, at + 4);
        if (dims == 0) {
            return 0;
        }
        if (dims != 1 || readInt(rows, at + 12) != 20 || n != 20 + readInt(rows, at + 16) * 12) {
            throw new IllegalStateException("expected int8 array");
        }
        return readInt(rows, at + 16);
    }

    private long arrayInt8(int at, int index) {
        int p = at + 24 + index * 12;
        if (readInt(rows, p) != 8) {
            throw new IllegalStateException("null array element");
        }
        return readLong(rows, p + 4);
    }

    private boolean contains(int at, long value) {
        int n = arrayCount(at);
        for (int e = 0; e < n; e++) {
            if (arrayInt8(at, e) == value) {
                return true;
            }
        }
        return false;
    }

    private void begin(int columns) {
        outLength = 0;
        reserve(2);
        out[0] = (byte) (columns >>> 8);
        out[1] = (byte) columns;
        outLength = 2;
    }

    private void reserve(int n) {
        if (n > out.length - outLength) {
            out = Arrays.copyOf(out, Math.max(outLength + n, out.length * 2));
        }
    }

    private void putRaw(byte[] b, int from, int to) {
        reserve(to - from);
        System.arraycopy(b, from, out, outLength, to - from);
        outLength += to - from;
    }

    private void putColumn(byte[] b, int from, int n) {
        putInt(n);
        putRaw(b, from, from + n);
    }

    private void putNull() {
        putInt(-1);
    }

    private void putBool(boolean v) {
        putInt(1);
        reserve(1);
        out[outLength++] = (byte) (v ? 1 : 0);
    }

    private void putInt(int v) {
        reserve(4);
        out[outLength] = (byte) (v >>> 24);
        out[outLength + 1] = (byte) (v >>> 16);
        out[outLength + 2] = (byte) (v >>> 8);
        out[outLength + 3] = (byte) v;
        outLength += 4;
    }

    private void putLong(long v) {
        putInt((int) (v >>> 32));
        putInt((int) v);
    }

    private static int readInt(byte[] b, int p) {
        return (b[p] & 255) << 24 | (b[p + 1] & 255) << 16 | (b[p + 2] & 255) << 8 | b[p + 3] & 255;
    }

    private static long readLong(byte[] b, int p) {
        return (long) readInt(b, p) << 32 | readInt(b, p + 4) & 0xffffffffL;
    }
}
