package conduit.http;

import java.nio.charset.StandardCharsets;

/** Parses one HTTP/1.1 request (request line, the headers we use, a Content-Length body) from bytes. */
public final class HttpParser {
    public static final int GET = 1, POST = 2, PUT = 3, DELETE = 4, OTHER = 5;

    /** More bytes are needed. */
    public static final int INCOMPLETE = 0;
    /** The request is malformed or uses something we don't support (chunked bodies). */
    public static final int BAD = -1;
    /** The headers or the body are over the limits. */
    public static final int TOO_LARGE = -2;

    static final int MAX_HEADER = 16 * 1024;
    static final int MAX_BODY = 1024 * 1024;

    private HttpParser() {
    }

    /**
     * Parses a request from b[off, end) into r. Returns the number of bytes it used (> 0), or one of
     * {@link #INCOMPLETE}, {@link #BAD} and {@link #TOO_LARGE}.
     */
    public static int parse(byte[] b, int off, int end, Request r) {
        int headEnd = -1;
        int limit = Math.min(end, off + MAX_HEADER);
        for (int i = off + 3; i < limit; i++) {
            if (b[i] == '\n' && b[i - 1] == '\r' && b[i - 2] == '\n' && b[i - 3] == '\r') {
                headEnd = i + 1;
                break;
            }
        }
        if (headEnd < 0) return end - off >= MAX_HEADER ? TOO_LARGE : INCOMPLETE;

        // request line: METHOD SP target SP HTTP/1.x CRLF
        int p = off;
        int sp = indexOf(b, p, headEnd, (byte) ' ');
        if (sp < 0) return BAD;
        r.method = method(b, p, sp - p);
        p = sp + 1;
        sp = indexOf(b, p, headEnd, (byte) ' ');
        if (sp < 0 || sp == p || b[p] != '/') return BAD;
        int q = indexOf(b, p, sp, (byte) '?');
        if (q < 0) {
            r.path = ascii(b, p, sp - p);
            r.query = null;
        } else {
            r.path = ascii(b, p, q - p);
            r.query = ascii(b, q + 1, sp - q - 1);
        }
        p = sp + 1;
        int eol = indexOf(b, p, headEnd, (byte) '\r');
        if (eol - p != 8 || b[p] != 'H' || b[p + 4] != '/' || b[p + 5] != '1' || b[p + 6] != '.') return BAD;
        boolean http10 = b[p + 7] == '0';
        r.keepAlive = !http10;
        p = eol + 2;

        r.auth = null;
        long contentLength = 0;
        while (p < headEnd - 2) {
            eol = indexOf(b, p, headEnd, (byte) '\r');
            int colon = indexOf(b, p, eol, (byte) ':');
            if (colon <= p) return BAD;
            int vs = colon + 1, ve = eol;
            while (vs < ve && (b[vs] == ' ' || b[vs] == '\t')) vs++;
            while (ve > vs && (b[ve - 1] == ' ' || b[ve - 1] == '\t')) ve--;
            int nl = colon - p;
            if (nl == 13 && nameIs(b, p, "authorization")) {
                r.auth = new String(b, vs, ve - vs, StandardCharsets.ISO_8859_1);
            } else if (nl == 14 && nameIs(b, p, "content-length")) {
                if (vs == ve || ve - vs > 9) return ve - vs > 9 ? TOO_LARGE : BAD;
                long v = 0;
                for (int i = vs; i < ve; i++) {
                    if (b[i] < '0' || b[i] > '9') return BAD;
                    v = v * 10 + (b[i] - '0');
                }
                contentLength = v;
            } else if (nl == 10 && nameIs(b, p, "connection")) {
                if (valueHas(b, vs, ve, "close")) r.keepAlive = false;
                else if (valueHas(b, vs, ve, "keep-alive")) r.keepAlive = true;
            } else if (nl == 17 && nameIs(b, p, "transfer-encoding")) {
                return BAD;
            }
            p = eol + 2;
        }
        if (contentLength > MAX_BODY) return TOO_LARGE;
        int total = headEnd - off + (int) contentLength;
        if (end - off < total) return INCOMPLETE;
        if (contentLength == 0) {
            r.body = Request.EMPTY;
        } else {
            r.body = new byte[(int) contentLength];
            System.arraycopy(b, headEnd, r.body, 0, (int) contentLength);
        }
        return total;
    }

    private static int method(byte[] b, int p, int n) {
        if (n == 3 && b[p] == 'G' && b[p + 1] == 'E' && b[p + 2] == 'T') return GET;
        if (n == 4 && b[p] == 'P' && b[p + 1] == 'O' && b[p + 2] == 'S' && b[p + 3] == 'T') return POST;
        if (n == 3 && b[p] == 'P' && b[p + 1] == 'U' && b[p + 2] == 'T') return PUT;
        if (n == 6 && ascii(b, p, n).equals("DELETE")) return DELETE;
        return OTHER;
    }

    private static int indexOf(byte[] b, int from, int to, byte c) {
        for (int i = from; i < to; i++) if (b[i] == c) return i;
        return -1;
    }

    /** Case-insensitive compare of b[p, p + lower.length()) with a lowercase ASCII name. */
    private static boolean nameIs(byte[] b, int p, String lower) {
        for (int i = 0; i < lower.length(); i++) {
            int c = b[p + i];
            if (c >= 'A' && c <= 'Z') c += 32;
            if (c != lower.charAt(i)) return false;
        }
        return true;
    }

    private static boolean valueHas(byte[] b, int vs, int ve, String lower) {
        int n = lower.length();
        for (int i = vs; i + n <= ve; i++) if (nameIs(b, i, lower)) return true;
        return false;
    }

    private static String ascii(byte[] b, int p, int n) {
        return new String(b, p, n, StandardCharsets.ISO_8859_1);
    }
}
