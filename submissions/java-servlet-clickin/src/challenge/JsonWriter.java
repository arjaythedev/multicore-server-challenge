package challenge;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** Reusable UTF-8 response arena. Input text is already UTF-8. */
public final class JsonWriter {
    private static final byte[] HEX = "0123456789abcdef".getBytes(StandardCharsets.US_ASCII);
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
        for (int i = 0; i < value.length(); i++) {
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
        for (int i = offset; i < end; i++) {
            int b = bytes[i] & 0xff;
            if (b == '"' || b == '\\') {
                put('\\');
                put(b);
            } else if (b < 0x20) {
                put('\\');
                put('u');
                put('0');
                put('0');
                put(HEX[b >>> 4]);
                put(HEX[b & 15]);
            } else {
                put(b);
            }
        }
        put('"');
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
