package conduit.json;

import conduit.db.Row;
import io.netty.buffer.ByteBuf;
import io.netty.buffer.ByteBufAllocator;
import java.nio.charset.StandardCharsets;

/**
 * Writes a JSON response body straight into a Netty buffer, followed (in front) by the HTTP head, so a response is
 * one buffer and one write. Text columns are copied from Postgres's rows as UTF-8 bytes, escaping only what JSON
 * requires: no Java strings, no transcoding.
 *
 * <p>The buffer starts with {@link #HEAD_ROOM} free bytes; {@link #toHttpResponse} writes the status line and headers
 * right before the body, once the body's length is known.
 */
public final class JsonWriter {
    static final int HEAD_ROOM = 128;

    /** Bytes that need escaping inside a JSON string: control characters, quote and backslash. */
    private static final boolean[] NEEDS_ESCAPE = new boolean[256];
    private static final byte[] HEX = "0123456789abcdef".getBytes(StandardCharsets.US_ASCII);

    static {
        for (int b = 0; b < 0x20; b++) NEEDS_ESCAPE[b] = true;
        NEEDS_ESCAPE['"'] = true;
        NEEDS_ESCAPE['\\'] = true;
    }

    private final ByteBuf out;
    /** Whether the next value or name must be preceded by a comma. */
    private boolean needsComma;

    public JsonWriter(ByteBufAllocator allocator, int expectedSize) {
        out = allocator.directBuffer(HEAD_ROOM + expectedSize);
        out.writerIndex(HEAD_ROOM);
    }

    /** Discards what was written (an error replaces a partially written body). */
    public void reset() {
        out.writerIndex(HEAD_ROOM);
        needsComma = false;
    }

    public int bodyLength() {
        return out.writerIndex() - HEAD_ROOM;
    }

    /** The JSON written so far (a view, valid until this writer's response is sent). */
    public ByteBuf body() {
        return out.slice(HEAD_ROOM, bodyLength());
    }

    /** Frees the buffer when no response is sent after all (the client went away). */
    public void release() {
        out.release();
    }

    // ---------- fragments: JSON rendered once and copied into several responses ----------

    /** Where the next byte will be written; with {@link #buffer()}, locates a fragment written meanwhile. */
    public int position() {
        return out.writerIndex();
    }

    public ByteBuf buffer() {
        return out;
    }

    /** Starts a new fragment: it is a value of its own, not a continuation of what was written before. */
    public void startFragment() {
        needsComma = false;
    }

    /**
     * Copies a fragment that ends right after a member name (such as {@code ..."following":}), so that the next call
     * writes that member's value.
     */
    public JsonWriter openFragment(ByteBuf source, int offset, int length) {
        separate();
        out.writeBytes(source, offset, length);
        needsComma = false;
        return this;
    }

    // ---------- structure ----------

    public JsonWriter beginObject() {
        separate();
        out.writeByte('{');
        needsComma = false;
        return this;
    }

    public JsonWriter endObject() {
        out.writeByte('}');
        needsComma = true;
        return this;
    }

    public JsonWriter beginArray() {
        separate();
        out.writeByte('[');
        needsComma = false;
        return this;
    }

    public JsonWriter endArray() {
        out.writeByte(']');
        needsComma = true;
        return this;
    }

    /** An object member's name; {@code key} is pre-encoded as {@code "name":} (see {@link Keys}). */
    public JsonWriter key(byte[] key) {
        separate();
        out.writeBytes(key);
        needsComma = false;
        return this;
    }

    private void separate() {
        if (needsComma) out.writeByte(',');
    }

    // ---------- values ----------

    public JsonWriter nullValue() {
        separate();
        out.writeBytes(NULL);
        needsComma = true;
        return this;
    }

    public JsonWriter value(boolean value) {
        separate();
        out.writeBytes(value ? TRUE : FALSE);
        needsComma = true;
        return this;
    }

    public JsonWriter value(long value) {
        separate();
        writeDecimal(value);
        needsComma = true;
        return this;
    }

    public JsonWriter value(String value) {
        if (value == null) return nullValue();
        byte[] utf8 = value.getBytes(StandardCharsets.UTF_8);
        separate();
        writeEscaped(utf8);
        needsComma = true;
        return this;
    }

    /** UTF-8 bytes from a buffer (a text column of a row, or an element of a text[] column). */
    public JsonWriter utf8Value(ByteBuf source, int offset, int length) {
        if (length < 0) return nullValue();
        separate();
        writeEscaped(source, offset, length);
        needsComma = true;
        return this;
    }

    /** A text column, or null for SQL NULL. */
    public JsonWriter column(Row row, int column) {
        return utf8Value(row.buffer(), row.offset(column), row.length(column));
    }

    /** A timestamptz column as RFC 3339 UTC with milliseconds: "2025-04-01T12:00:00.000Z". */
    public JsonWriter timestamp(Row row, int column) {
        separate();
        out.writeByte('"');
        Timestamps.writeIso(out, row.getTimestampMicros(column));
        out.writeByte('"');
        needsComma = true;
        return this;
    }

    /** A text[] column as an array of strings. */
    public JsonWriter textArray(Row row, int column) {
        beginArray();
        row.forEachTextElement(column, this::utf8Value);
        return endArray();
    }

    // the elements of a text[] being sorted: offsets and lengths in the row
    private int[] elementOffsets = new int[8];
    private int[] elementLengths = new int[8];
    private int elementCount;

    /**
     * A text[] column as an array of strings sorted by their UTF-8 bytes, which is code point order: the same as
     * ORDER BY under the C and C.UTF-8 collations. Insertion sort: an article has a handful of tags.
     */
    public JsonWriter sortedTextArray(Row row, int column) {
        elementCount = 0;
        row.forEachTextElement(column, (buffer, offset, length) -> {
            if (elementCount == elementOffsets.length) {
                elementOffsets = java.util.Arrays.copyOf(elementOffsets, elementCount * 2);
                elementLengths = java.util.Arrays.copyOf(elementLengths, elementCount * 2);
            }
            elementOffsets[elementCount] = offset;
            elementLengths[elementCount] = length;
            elementCount++;
        });
        ByteBuf data = row.buffer();
        for (int i = 1; i < elementCount; i++) {
            int offset = elementOffsets[i];
            int length = elementLengths[i];
            int j = i - 1;
            while (j >= 0 && compareUtf8(data, elementOffsets[j], elementLengths[j], offset, length) > 0) {
                elementOffsets[j + 1] = elementOffsets[j];
                elementLengths[j + 1] = elementLengths[j];
                j--;
            }
            elementOffsets[j + 1] = offset;
            elementLengths[j + 1] = length;
        }
        beginArray();
        for (int i = 0; i < elementCount; i++) utf8Value(data, elementOffsets[i], elementLengths[i]);
        return endArray();
    }

    /** Unsigned byte comparison; NULL (length -1) sorts last, as in ORDER BY. */
    private static int compareUtf8(ByteBuf data, int offsetA, int lengthA, int offsetB, int lengthB) {
        if (lengthA < 0 || lengthB < 0) return Boolean.compare(lengthA < 0, lengthB < 0);
        int common = Math.min(lengthA, lengthB);
        for (int i = 0; i < common; i++) {
            int difference = (data.getByte(offsetA + i) & 0xff) - (data.getByte(offsetB + i) & 0xff);
            if (difference != 0) return difference;
        }
        return lengthA - lengthB;
    }

    /** Copies an already encoded JSON value (used to give every request of a batch the same tag list). */
    public JsonWriter raw(ByteBuf encodedJson) {
        separate();
        out.writeBytes(encodedJson, encodedJson.readerIndex(), encodedJson.readableBytes());
        needsComma = true;
        return this;
    }

    // ---------- the HTTP response ----------

    /**
     * Writes the HTTP head in front of the body and returns the buffer, ready to be written to the socket. A 204
     * response has no body and no Content-Length.
     */
    public ByteBuf toHttpResponse(int status, boolean closeConnection) {
        if (status == 204) reset();
        byte[] statusLine = HttpStatus.line(status);
        int bodyLength = bodyLength();
        int headLength = statusLine.length + (closeConnection ? CONNECTION_CLOSE.length : 0) + 2;
        if (status != 204) headLength += CONTENT_HEADERS.length + decimalLength(bodyLength) + 2;

        int start = HEAD_ROOM - headLength;
        int end = out.writerIndex();
        out.writerIndex(start);
        out.writeBytes(statusLine);
        if (status != 204) {
            out.writeBytes(CONTENT_HEADERS);
            writeDecimal(bodyLength);
            out.writeShort(CRLF);
        }
        if (closeConnection) out.writeBytes(CONNECTION_CLOSE);
        out.writeShort(CRLF);
        out.readerIndex(start);
        out.writerIndex(end);
        return out;
    }

    // ---------- encoding ----------

    private static final byte[] NULL = {'n', 'u', 'l', 'l'};
    private static final byte[] TRUE = {'t', 'r', 'u', 'e'};
    private static final byte[] FALSE = {'f', 'a', 'l', 's', 'e'};
    private static final byte[] CONTENT_HEADERS =
            "Content-Type: application/json\r\nContent-Length: ".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CONNECTION_CLOSE = "Connection: close\r\n".getBytes(StandardCharsets.US_ASCII);
    private static final int CRLF = ('\r' << 8) | '\n';

    private void writeEscaped(byte[] utf8) {
        out.writeByte('"');
        int runStart = 0;
        for (int i = 0; i < utf8.length; i++) {
            int b = utf8[i] & 0xff;
            if (!NEEDS_ESCAPE[b]) continue;
            out.writeBytes(utf8, runStart, i - runStart);
            writeEscape(b);
            runStart = i + 1;
        }
        out.writeBytes(utf8, runStart, utf8.length - runStart);
        out.writeByte('"');
    }

    /** Copies runs of bytes that need no escaping in one go; most strings are a single run. */
    private void writeEscaped(ByteBuf source, int offset, int length) {
        out.writeByte('"');
        int end = offset + length;
        int runStart = offset;
        for (int i = offset; i < end; i++) {
            int b = source.getByte(i) & 0xff;
            if (!NEEDS_ESCAPE[b]) continue;
            out.writeBytes(source, runStart, i - runStart);
            writeEscape(b);
            runStart = i + 1;
        }
        out.writeBytes(source, runStart, end - runStart);
        out.writeByte('"');
    }

    private void writeEscape(int b) {
        out.writeByte('\\');
        switch (b) {
            case '"' -> out.writeByte('"');
            case '\\' -> out.writeByte('\\');
            case '\n' -> out.writeByte('n');
            case '\r' -> out.writeByte('r');
            case '\t' -> out.writeByte('t');
            case '\b' -> out.writeByte('b');
            case '\f' -> out.writeByte('f');
            default -> out.writeByte('u').writeByte('0').writeByte('0').writeByte(HEX[b >> 4]).writeByte(HEX[b & 15]);
        }
    }

    private void writeDecimal(long value) {
        if (value < 0) {
            if (value == Long.MIN_VALUE) {
                out.writeCharSequence(Long.toString(value), StandardCharsets.US_ASCII);
                return;
            }
            out.writeByte('-');
            value = -value;
        }
        int digits = decimalLength(value);
        int end = out.writerIndex() + digits;
        out.ensureWritable(digits);
        for (int position = end - 1; position >= end - digits; position--) {
            out.setByte(position, (int) ('0' + value % 10));
            value /= 10;
        }
        out.writerIndex(end);
    }

    private static int decimalLength(long value) {
        int digits = 1;
        while (value >= 10) {
            value /= 10;
            digits++;
        }
        return digits;
    }
}
