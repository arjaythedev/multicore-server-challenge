package dev.moose.conduit.json;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Arrays;

public class JsonWriter {

    private static final byte[] HEX = "0123456789abcdef".getBytes();
    private static final byte[] TRUE = "true".getBytes();
    private static final byte[] FALSE = "false".getBytes();
    private static final byte[] NULL = "null".getBytes();

    private byte[] buffer;
    private int length;
    private boolean needsComma;

    public JsonWriter() {
        this(512);
    }

    public JsonWriter(int capacity) {
        this.buffer = new byte[capacity];
    }

    public JsonWriter open() {
        comma();
        put((byte) '{');
        this.needsComma = false;
        return this;
    }

    public JsonWriter close() {
        put((byte) '}');
        this.needsComma = true;
        return this;
    }

    public JsonWriter openArray() {
        comma();
        put((byte) '[');
        this.needsComma = false;
        return this;
    }

    public JsonWriter closeArray() {
        put((byte) ']');
        this.needsComma = true;
        return this;
    }

    public JsonWriter key(String name) {
        comma();
        put((byte) '"');
        ascii(name);
        put((byte) '"');
        put((byte) ':');
        this.needsComma = false;
        return this;
    }

    public JsonWriter string(String value) {
        comma();
        this.needsComma = true;
        if (value == null) {
            put(NULL);
            return this;
        }
        put((byte) '"');
        escape(value);
        put((byte) '"');
        return this;
    }

    public JsonWriter number(long value) {
        comma();
        this.needsComma = true;
        ascii(Long.toString(value));
        return this;
    }

    public JsonWriter bool(boolean value) {
        comma();
        this.needsComma = true;
        put(value ? TRUE : FALSE);
        return this;
    }

    public JsonWriter timestamp(OffsetDateTime value) {
        comma();
        this.needsComma = true;
        final OffsetDateTime utc = value.getOffset().equals(ZoneOffset.UTC) ? value : value.withOffsetSameInstant(ZoneOffset.UTC);
        ensure(26);
        put((byte) '"');
        digits(utc.getYear(), 4);
        put((byte) '-');
        digits(utc.getMonthValue(), 2);
        put((byte) '-');
        digits(utc.getDayOfMonth(), 2);
        put((byte) 'T');
        digits(utc.getHour(), 2);
        put((byte) ':');
        digits(utc.getMinute(), 2);
        put((byte) ':');
        digits(utc.getSecond(), 2);
        put((byte) '.');
        digits(utc.getNano() / 1_000_000, 3);
        put((byte) 'Z');
        put((byte) '"');
        return this;
    }

    public JsonWriter raw(byte[] bytes) {
        comma();
        this.needsComma = true;
        put(bytes);
        return this;
    }

    public byte[] toBytes() {
        return Arrays.copyOf(this.buffer, this.length);
    }

    private void comma() {
        if (this.needsComma) {
            put((byte) ',');
        }
    }

    private void digits(int value, int width) {
        int remaining = value;
        for (int position = this.length + width - 1; position >= this.length; position--) {
            this.buffer[position] = (byte) ('0' + remaining % 10);
            remaining /= 10;
        }
        this.length += width;
    }

    private void ascii(String text) {
        final int size = text.length();
        ensure(size);
        for (int i = 0; i < size; i++) {
            this.buffer[this.length++] = (byte) text.charAt(i);
        }
    }

    private void escape(String text) {
        final int size = text.length();
        ensure(size + 16);
        for (int i = 0; i < size; i++) {
            final char character = text.charAt(i);
            if (character >= 0x20 && character < 0x80 && character != '"' && character != '\\') {
                if (this.length == this.buffer.length) {
                    ensure(size - i + 16);
                }
                this.buffer[this.length++] = (byte) character;
                continue;
            }
            ensure(size - i + 16);
            if (character == '"' || character == '\\') {
                this.buffer[this.length++] = '\\';
                this.buffer[this.length++] = (byte) character;
                continue;
            }
            if (character == '\n') {
                this.buffer[this.length++] = '\\';
                this.buffer[this.length++] = 'n';
                continue;
            }
            if (character == '\r') {
                this.buffer[this.length++] = '\\';
                this.buffer[this.length++] = 'r';
                continue;
            }
            if (character == '\t') {
                this.buffer[this.length++] = '\\';
                this.buffer[this.length++] = 't';
                continue;
            }
            if (character < 0x20) {
                this.buffer[this.length++] = '\\';
                this.buffer[this.length++] = 'u';
                this.buffer[this.length++] = '0';
                this.buffer[this.length++] = '0';
                this.buffer[this.length++] = HEX[character >> 4];
                this.buffer[this.length++] = HEX[character & 0xf];
                continue;
            }
            if (character < 0x800) {
                this.buffer[this.length++] = (byte) (0xc0 | (character >> 6));
                this.buffer[this.length++] = (byte) (0x80 | (character & 0x3f));
                continue;
            }
            if (Character.isHighSurrogate(character) && i + 1 < size && Character.isLowSurrogate(text.charAt(i + 1))) {
                final int codePoint = Character.toCodePoint(character, text.charAt(++i));
                this.buffer[this.length++] = (byte) (0xf0 | (codePoint >> 18));
                this.buffer[this.length++] = (byte) (0x80 | ((codePoint >> 12) & 0x3f));
                this.buffer[this.length++] = (byte) (0x80 | ((codePoint >> 6) & 0x3f));
                this.buffer[this.length++] = (byte) (0x80 | (codePoint & 0x3f));
                continue;
            }
            if (Character.isSurrogate(character)) {
                this.buffer[this.length++] = (byte) 0xef;
                this.buffer[this.length++] = (byte) 0xbf;
                this.buffer[this.length++] = (byte) 0xbd;
                continue;
            }
            this.buffer[this.length++] = (byte) (0xe0 | (character >> 12));
            this.buffer[this.length++] = (byte) (0x80 | ((character >> 6) & 0x3f));
            this.buffer[this.length++] = (byte) (0x80 | (character & 0x3f));
        }
    }

    private void put(byte value) {
        if (this.length == this.buffer.length) {
            ensure(1);
        }
        this.buffer[this.length++] = value;
    }

    private void put(byte[] bytes) {
        ensure(bytes.length);
        System.arraycopy(bytes, 0, this.buffer, this.length, bytes.length);
        this.length += bytes.length;
    }

    private void ensure(int extra) {
        if (this.length + extra <= this.buffer.length) {
            return;
        }
        this.buffer = Arrays.copyOf(this.buffer, Math.max(this.buffer.length * 2, this.length + extra));
    }

}
