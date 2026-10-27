package dev.mccue.vertx.realworld;

import io.vertx.core.buffer.Buffer;
import org.jspecify.annotations.Nullable;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;

/// A JSON response body, written straight into a buffer. The structure is the caller's job: this only knows how to
/// write keys, values and escapes.
final class Out {
    private final StringBuilder sb = new StringBuilder(1024);
    private boolean needsComma = false;

    Out open() {
        comma();
        sb.append('{');
        needsComma = false;
        return this;
    }

    Out close() {
        sb.append('}');
        needsComma = true;
        return this;
    }

    Out openArray() {
        comma();
        sb.append('[');
        needsComma = false;
        return this;
    }

    Out closeArray() {
        sb.append(']');
        needsComma = true;
        return this;
    }

    Out key(String key) {
        comma();
        sb.append('"').append(key).append("\":");
        needsComma = false;
        return this;
    }

    Out string(@Nullable String value) {
        comma();
        if (value == null) {
            sb.append("null");
        }
        else {
            sb.append('"');
            escape(value);
            sb.append('"');
        }
        needsComma = true;
        return this;
    }

    Out number(long value) {
        comma();
        sb.append(value);
        needsComma = true;
        return this;
    }

    Out bool(boolean value) {
        comma();
        sb.append(value);
        needsComma = true;
        return this;
    }

    /// RFC 3339 in UTC with exactly three (truncated) fractional digits.
    Out timestamp(OffsetDateTime value) {
        var t = value.withOffsetSameInstant(ZoneOffset.UTC);
        comma();
        sb.append('"');
        pad(t.getYear(), 4).append('-');
        pad(t.getMonthValue(), 2).append('-');
        pad(t.getDayOfMonth(), 2).append('T');
        pad(t.getHour(), 2).append(':');
        pad(t.getMinute(), 2).append(':');
        pad(t.getSecond(), 2).append('.');
        pad(t.getNano() / 1_000_000, 3).append("Z\"");
        needsComma = true;
        return this;
    }

    Buffer toBuffer() {
        return Buffer.buffer(sb.toString());
    }

    private void comma() {
        if (needsComma) {
            sb.append(',');
        }
    }

    private StringBuilder pad(int value, int width) {
        var digits = Integer.toString(value);
        for (int i = digits.length(); i < width; i++) {
            sb.append('0');
        }
        return sb.append(digits);
    }

    /// Characters that need no escape are copied in runs, not one at a time.
    private void escape(String value) {
        int run = 0;
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c >= 0x20 && c != '"' && c != '\\') {
                continue;
            }
            sb.append(value, run, i);
            run = i + 1;
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                case '\b' -> sb.append("\\b");
                case '\f' -> sb.append("\\f");
                default -> {
                    sb.append("\\u00");
                    sb.append(Character.forDigit(c >> 4, 16));
                    sb.append(Character.forDigit(c & 0xF, 16));
                }
            }
        }
        sb.append(value, run, value.length());
    }
}
