package challenge;

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Reusable UTF-8 response arena. Input text is already UTF-8. */
public final class JsonWriter {
    private static final byte[] HEX = "0123456789abcdef".getBytes(StandardCharsets.US_ASCII);
    private static final VarHandle LONGS = MethodHandles.byteArrayViewVarHandle(long[].class, ByteOrder.LITTLE_ENDIAN);
    private static final long ONES = 0x0101010101010101L;
    private static final long HIGHS = 0x8080808080808080L;
    private byte[] data = new byte[1024];
    private int length;

    public void reset() {
        length = 0;
    }

    public byte[] bytes() {
        return data;
    }

    public int length() {
        return length;
    }

    public void raw(byte[] bytes, int offset, int count) {
        if (offset < 0 || count < 0 || offset > bytes.length - count) {
            throw new IndexOutOfBoundsException();
        }
        reserve(count);
        System.arraycopy(bytes, offset, data, length, count);
        length += count;
    }

    public void raw(String value) {
        int i = 0;
        reserve(value.length());
        for (; i < value.length(); i++) {
            int c = value.charAt(i);
            if (c >= 0x80) {
                break;
            }
            data[length++] = (byte) c;
        }
        for (; i < value.length(); i++) {
            int c = value.charAt(i);
            if (c < 0x80) {
                put(c);
            } else if (c < 0x800) {
                put(0xc0 | c >>> 6);
                put(0x80 | c & 63);
            } else if (Character.isHighSurrogate((char) c) && i + 1 < value.length() && Character.isLowSurrogate(value.charAt(i + 1))) {
                c = Character.toCodePoint((char) c, value.charAt(++i));
                put(0xf0 | c >>> 18);
                put(0x80 | c >>> 12 & 63);
                put(0x80 | c >>> 6 & 63);
                put(0x80 | c & 63);
            } else if (Character.isSurrogate((char) c)) {
                put('?');
            } else {
                put(0xe0 | c >>> 12);
                put(0x80 | c >>> 6 & 63);
                put(0x80 | c & 63);
            }
        }
    }

    public void number(long value) {
        if (value > 0) {
            value = -value;
        } else if (value < 0) {
            put('-');
        }
        int start = length;
        do {
            put('0' - (int) (value % 10));
            value /= 10;
        } while (value != 0);
        for (int a = start, b = length - 1;
             a < b;
             a++, b--) {
            byte t = data[a];
            data[a] = data[b];
            data[b] = t;
        }
    }

    public void string(byte[] bytes, int offset, int count) {
        if (offset < 0 || count < 0 || offset > bytes.length - count) {
            throw new IndexOutOfBoundsException();
        }
        put('"');
        int end = offset + count;
        int start = offset;
        int i = offset;
        for (; ; ) {
            // eight bytes at a time while none needs escaping: no control byte, '"' or '\\'
            while (i <= end - 8 && !special((long) LONGS.get(bytes, i))) {
                i += 8;
            }
            if (i >= end) {
                break;
            }
            int b = bytes[i] & 0xff;
            if (b == '"' || b == '\\' || b < 0x20) {
                if (i > start) {
                    raw(bytes, start, i - start);
                }
                put('\\');
                if (b < 0x20) {
                    put('u');
                    put('0');
                    put('0');
                    put(HEX[b >>> 4]);
                    put(HEX[b & 15]);
                } else {
                    put(b);
                }
                start = i + 1;
            }
            i++;
        }
        if (start < end) {
            raw(bytes, start, end - start);
        }
        put('"');
    }

    /** Whether any byte of {@code w} is below 0x20, '"' or '\\' (bytes 0x80 and up never are). */
    private static boolean special(long w) {
        long quote = w ^ (ONES * '"');
        long slash = w ^ (ONES * '\\');
        long zeroQuote = (quote - ONES) & ~quote;
        long zeroSlash = (slash - ONES) & ~slash;
        long below = (w - ONES * 0x20) & ~w;
        return ((zeroQuote | zeroSlash | below) & HIGHS) != 0;
    }

    public void put(int value) {
        reserve(1);
        data[length++] = (byte) value;
    }

    private void reserve(int count) {
        int needed = Math.addExact(length, count);
        if (needed > data.length) {
            int capacity = data.length;
            while (capacity < needed) {
                int next = capacity + (capacity >>> 1);
                if (next <= capacity) {
                    capacity = needed;
                    break;
                }
                capacity = next;
            }
            data = Arrays.copyOf(data, capacity);
        }
    }
}
