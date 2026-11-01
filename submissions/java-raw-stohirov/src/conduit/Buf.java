package conduit;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

/** A growable byte buffer with the JSON writers every response uses. */
final class Buf {
    byte[] a;
    int n;

    Buf(int cap) {
        a = new byte[cap];
    }

    void ensure(int extra) {
        if (n + extra > a.length) a = Arrays.copyOf(a, Math.max(a.length * 2, n + extra));
    }

    Buf b(int c) {
        if (n == a.length) ensure(1);
        a[n++] = (byte) c;
        return this;
    }

    Buf raw(byte[] s) {
        ensure(s.length);
        System.arraycopy(s, 0, a, n, s.length);
        n += s.length;
        return this;
    }

    Buf raw(byte[] s, int off, int len) {
        ensure(len);
        System.arraycopy(s, off, a, n, len);
        n += len;
        return this;
    }

    /** ASCII only (literals). */
    Buf ascii(String s) {
        int l = s.length();
        ensure(l);
        for (int i = 0; i < l; i++) a[n++] = (byte) s.charAt(i);
        return this;
    }

    Buf num(long v) {
        if (v == Long.MIN_VALUE) return ascii("-9223372036854775808");
        ensure(20);
        if (v < 0) {
            a[n++] = '-';
            v = -v;
        }
        if (v < 10) {
            a[n++] = (byte) ('0' + v);
            return this;
        }
        int len = 0;
        for (long t = v; t > 0; t /= 10) len++;
        int end = n + len;
        for (int i = end - 1; i >= n; i--) {
            a[i] = (byte) ('0' + v % 10);
            v /= 10;
        }
        n = end;
        return this;
    }

    Buf bool(boolean v) {
        return ascii(v ? "true" : "false");
    }

    private static final byte[] HEX = "0123456789abcdef".getBytes(StandardCharsets.US_ASCII);

    /** A JSON string from UTF-8 bytes: quotes, backslashes and control characters escaped, the rest as is. */
    Buf str(byte[] s, int off, int len) {
        ensure(len + 2);
        a[n++] = '"';
        int end = off + len;
        int run = off;
        for (int i = off; i < end; i++) {
            int c = s[i] & 0xff;
            if (c >= 0x20 && c != '"' && c != '\\') continue;
            if (i > run) raw(s, run, i - run);
            ensure(6);
            a[n++] = '\\';
            switch (c) {
                case '"' -> a[n++] = '"';
                case '\\' -> a[n++] = '\\';
                case '\n' -> a[n++] = 'n';
                case '\r' -> a[n++] = 'r';
                case '\t' -> a[n++] = 't';
                case '\b' -> a[n++] = 'b';
                case '\f' -> a[n++] = 'f';
                default -> {
                    a[n++] = 'u';
                    a[n++] = '0';
                    a[n++] = '0';
                    a[n++] = HEX[c >> 4];
                    a[n++] = HEX[c & 15];
                }
            }
            run = i + 1;
        }
        if (end > run) raw(s, run, end - run);
        ensure(1);
        a[n++] = '"';
        return this;
    }

    Buf str(byte[] s) {
        return s == null ? ascii("null") : str(s, 0, s.length);
    }

    Buf str(String s) {
        return s == null ? ascii("null") : str(s.getBytes(StandardCharsets.UTF_8));
    }

    /** RFC 3339 UTC with milliseconds, from Postgres's binary timestamptz (microseconds since 2000-01-01). */
    Buf ts(long pgMicros) {
        long ms = Math.floorDiv(pgMicros, 1000L) + 946_684_800_000L;
        long days = Math.floorDiv(ms, 86_400_000L);
        int msOfDay = (int) (ms - days * 86_400_000L);
        // civil_from_days (H. Hinnant)
        long z = days + 719_468;
        long era = Math.floorDiv(z, 146_097);
        long doe = z - era * 146_097;
        long yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        long y = yoe + era * 400;
        long doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        long mp = (5 * doy + 2) / 153;
        int d = (int) (doy - (153 * mp + 2) / 5 + 1);
        int m = (int) (mp < 10 ? mp + 3 : mp - 9);
        if (m <= 2) y++;
        ensure(26);
        a[n++] = '"';
        int yy = (int) y;
        a[n++] = (byte) ('0' + yy / 1000 % 10);
        a[n++] = (byte) ('0' + yy / 100 % 10);
        a[n++] = (byte) ('0' + yy / 10 % 10);
        a[n++] = (byte) ('0' + yy % 10);
        a[n++] = '-';
        two(m);
        a[n++] = '-';
        two(d);
        a[n++] = 'T';
        int s = msOfDay / 1000;
        two(s / 3600);
        a[n++] = ':';
        two(s / 60 % 60);
        a[n++] = ':';
        two(s % 60);
        a[n++] = '.';
        int f = msOfDay % 1000;
        a[n++] = (byte) ('0' + f / 100);
        a[n++] = (byte) ('0' + f / 10 % 10);
        a[n++] = (byte) ('0' + f % 10);
        a[n++] = 'Z';
        a[n++] = '"';
        return this;
    }

    private void two(int v) {
        a[n++] = (byte) ('0' + v / 10);
        a[n++] = (byte) ('0' + v % 10);
    }

    byte[] toBytes() {
        return Arrays.copyOf(a, n);
    }
}
