package conduit.http;

import java.util.Arrays;

/**
 * A growable byte buffer that JSON bodies and HTTP responses are written into. Each event loop owns a few and
 * reuses them for every response, so writing a response allocates nothing.
 */
public final class Out {
    private static final byte[] HEX = "0123456789abcdef".getBytes();
    /** Unix epoch ms of the Postgres epoch, 2000-01-01T00:00:00Z. */
    private static final long PG_EPOCH_MS = 946_684_800_000L;

    public byte[] buf;
    public int len;

    public Out(int capacity) {
        buf = new byte[capacity];
    }

    public Out reset() {
        len = 0;
        return this;
    }

    private void ensure(int n) {
        if (len + n > buf.length) buf = Arrays.copyOf(buf, Math.max(buf.length * 2, len + n));
    }

    public Out raw(byte b) {
        ensure(1);
        buf[len++] = b;
        return this;
    }

    public Out raw(byte[] b, int off, int n) {
        ensure(n);
        System.arraycopy(b, off, buf, len, n);
        len += n;
        return this;
    }

    public Out raw(Out o) {
        return raw(o.buf, 0, o.len);
    }

    /** Writes s as is; s must be ASCII (keys, punctuation, header text). */
    public Out ascii(String s) {
        int n = s.length();
        ensure(n);
        for (int i = 0; i < n; i++) buf[len++] = (byte) s.charAt(i);
        return this;
    }

    public Out num(long v) {
        if (v == Long.MIN_VALUE) return ascii(Long.toString(v));
        ensure(20);
        if (v < 0) {
            buf[len++] = '-';
            v = -v;
        }
        int start = len;
        do {
            buf[len++] = (byte) ('0' + v % 10);
            v /= 10;
        } while (v != 0);
        for (int i = start, j = len - 1; i < j; i++, j--) {
            byte t = buf[i];
            buf[i] = buf[j];
            buf[j] = t;
        }
        return this;
    }

    public Out bool(boolean b) {
        return ascii(b ? "true" : "false");
    }

    public Out nul() {
        return ascii("null");
    }

    /** A JSON string from UTF-8 bytes. Non-ASCII bytes are copied as they are. */
    public Out str(byte[] b, int off, int n) {
        ensure(n * 6 + 2);
        byte[] d = buf;
        int p = len;
        d[p++] = '"';
        for (int i = off, end = off + n; i < end; i++) {
            byte c = b[i];
            if (c == '"' || c == '\\') {
                d[p++] = '\\';
                d[p++] = c;
            } else if (c >= 0 && c < 0x20) {
                p = control(d, p, c);
            } else {
                d[p++] = c;
            }
        }
        d[p++] = '"';
        len = p;
        return this;
    }

    /** A JSON string from a Java string, encoded as UTF-8; null gives JSON null. */
    public Out str(String s) {
        if (s == null) return nul();
        int n = s.length();
        ensure(n * 6 + 2);
        byte[] d = buf;
        int p = len;
        d[p++] = '"';
        for (int i = 0; i < n; i++) {
            char c = s.charAt(i);
            if (c < 0x80) {
                if (c == '"' || c == '\\') {
                    d[p++] = '\\';
                    d[p++] = (byte) c;
                } else if (c < 0x20) {
                    p = control(d, p, (byte) c);
                } else {
                    d[p++] = (byte) c;
                }
            } else if (c < 0x800) {
                d[p++] = (byte) (0xc0 | c >> 6);
                d[p++] = (byte) (0x80 | c & 0x3f);
            } else if (Character.isHighSurrogate(c) && i + 1 < n && Character.isLowSurrogate(s.charAt(i + 1))) {
                int cp = Character.toCodePoint(c, s.charAt(++i));
                d[p++] = (byte) (0xf0 | cp >> 18);
                d[p++] = (byte) (0x80 | cp >> 12 & 0x3f);
                d[p++] = (byte) (0x80 | cp >> 6 & 0x3f);
                d[p++] = (byte) (0x80 | cp & 0x3f);
            } else {
                if (Character.isSurrogate(c)) c = '�';
                d[p++] = (byte) (0xe0 | c >> 12);
                d[p++] = (byte) (0x80 | c >> 6 & 0x3f);
                d[p++] = (byte) (0x80 | c & 0x3f);
            }
        }
        d[p++] = '"';
        len = p;
        return this;
    }

    private static int control(byte[] d, int p, byte c) {
        d[p++] = '\\';
        switch (c) {
            case '\n' -> d[p++] = 'n';
            case '\r' -> d[p++] = 'r';
            case '\t' -> d[p++] = 't';
            case '\b' -> d[p++] = 'b';
            case '\f' -> d[p++] = 'f';
            default -> {
                d[p++] = 'u';
                d[p++] = '0';
                d[p++] = '0';
                d[p++] = HEX[c >> 4];
                d[p++] = HEX[c & 0xf];
            }
        }
        return p;
    }

    /**
     * A JSON string holding a Postgres binary timestamptz (microseconds since 2000-01-01 UTC) as RFC 3339 UTC with
     * exactly 3 fractional digits, truncated: "2025-04-01T12:00:00.000Z".
     */
    public Out timestamp(long pgMicros) {
        long ms = Math.floorDiv(pgMicros, 1000) + PG_EPOCH_MS;
        long days = Math.floorDiv(ms, 86_400_000L);
        int msOfDay = (int) Math.floorMod(ms, 86_400_000L);
        // civil_from_days, from Howard Hinnant's date algorithms
        long z = days + 719_468;
        long era = Math.floorDiv(z, 146_097);
        long doe = z - era * 146_097;
        long yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        long y = yoe + era * 400;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        int day = (int) (doy - (153 * mp + 2) / 5 + 1);
        int month = (int) (mp < 10 ? mp + 3 : mp - 9);
        if (month <= 2) y++;
        ensure(26);
        byte[] d = buf;
        int p = len;
        d[p++] = '"';
        p = digits(d, p, (int) y, 4);
        d[p++] = '-';
        p = digits(d, p, month, 2);
        d[p++] = '-';
        p = digits(d, p, day, 2);
        d[p++] = 'T';
        p = digits(d, p, msOfDay / 3_600_000, 2);
        d[p++] = ':';
        p = digits(d, p, msOfDay / 60_000 % 60, 2);
        d[p++] = ':';
        p = digits(d, p, msOfDay / 1000 % 60, 2);
        d[p++] = '.';
        p = digits(d, p, msOfDay % 1000, 3);
        d[p++] = 'Z';
        d[p++] = '"';
        len = p;
        return this;
    }

    private static int digits(byte[] d, int p, int v, int width) {
        for (int i = p + width - 1; i >= p; i--) {
            d[i] = (byte) ('0' + v % 10);
            v /= 10;
        }
        return p + width;
    }

    /** An error body, {"errors":{"body":["msg"]}}. */
    public Out error(String msg) {
        return ascii("{\"errors\":{\"body\":[").str(msg).ascii("]}}");
    }
}
