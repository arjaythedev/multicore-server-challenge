package conduit;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;

/** Percent-decoding of path segments and query values (a malformed escape is kept as it is). */
final class UrlDecoding {
    private UrlDecoding() {
    }

    /** A path segment: %XX escapes only. */
    static String pathSegment(String raw) {
        return isPlain(raw, false) ? raw : decode(raw, false);
    }

    /** A query string value: %XX escapes, and '+' means a space. */
    static String queryValue(String raw) {
        return isPlain(raw, true) ? raw : decode(raw, true);
    }

    /** Nothing to decode: ASCII without escapes. */
    private static boolean isPlain(String raw, boolean plusIsSpace) {
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c == '%' || c > 127 || (plusIsSpace && c == '+')) return false;
        }
        return true;
    }

    private static String decode(String raw, boolean plusIsSpace) {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(raw.length());
        for (int i = 0; i < raw.length(); i++) {
            char c = raw.charAt(i);
            if (c == '%' && i + 2 < raw.length() && hex(raw.charAt(i + 1)) >= 0 && hex(raw.charAt(i + 2)) >= 0) {
                bytes.write(hex(raw.charAt(i + 1)) << 4 | hex(raw.charAt(i + 2)));
                i += 2;
            } else if (c == '+' && plusIsSpace) {
                bytes.write(' ');
            } else {
                bytes.write(c);                      // the request line is read as ISO-8859-1: one char per byte
            }
        }
        return bytes.toString(StandardCharsets.UTF_8);
    }

    private static int hex(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }
}
