package conduit.http;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** The parsed request a connection is serving. A connection serves one request at a time, so it reuses one. */
public class Request {
    static final byte[] EMPTY = new byte[0];

    public int method;
    /** The raw (still percent-encoded) path, without the query. */
    public String path;
    /** The raw query string after '?', or null. */
    public String query;
    /** The Authorization header value, or null. */
    public String auth;
    public byte[] body = EMPTY;
    public boolean keepAlive;

    /** The decoded value of the first query parameter called name, or null if there is none. */
    public String param(String name) {
        String q = query;
        if (q == null) return null;
        int n = name.length();
        int i = 0;
        while (i <= q.length()) {
            int amp = q.indexOf('&', i);
            if (amp < 0) amp = q.length();
            if (amp - i >= n && q.startsWith(name, i) && (amp - i == n || q.charAt(i + n) == '=')) {
                return amp - i == n ? "" : decode(q, i + n + 1, amp, true);
            }
            i = amp + 1;
        }
        return null;
    }

    /** Percent-decodes s[from, to) as UTF-8 ('+' is a space when plus is true). Bad escapes are kept as is. */
    public static String decode(String s, int from, int to, boolean plus) {
        boolean plain = true;
        for (int i = from; i < to; i++) {
            char c = s.charAt(i);
            if (c == '%' || (plus && c == '+')) {
                plain = false;
                break;
            }
        }
        if (plain) return s.substring(from, to);
        ByteArrayOutputStream out = new ByteArrayOutputStream(to - from);
        for (int i = from; i < to; i++) {
            char c = s.charAt(i);
            if (c == '+' && plus) {
                out.write(' ');
            } else if (c == '%') {
                int h = i + 2 < to ? hex(s, i + 1) : -1;
                if (h >= 0) {
                    out.write(h);
                    i += 2;
                } else {
                    out.write('%');
                }
            } else {
                out.write(c);
            }
        }
        return out.toString(StandardCharsets.UTF_8);
    }

    private static int hex(String s, int i) {
        int a = Character.digit(s.charAt(i), 16), b = Character.digit(s.charAt(i + 1), 16);
        return a < 0 || b < 0 ? -1 : a << 4 | b;
    }
}
