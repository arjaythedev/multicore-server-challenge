package conduit.http;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * A small JSON parser for request bodies and JWT segments. Only write requests and logins have bodies, so this
 * builds plain objects: Map, List, String, Double, Boolean, and {@link #NULL} for JSON null (so an absent key and
 * a null value can be told apart). Malformed input throws {@link IllegalArgumentException}.
 */
public final class Json {
    public static final Object NULL = new Object() {
        @Override
        public String toString() {
            return "null";
        }
    };
    private static final int MAX_DEPTH = 64;

    private final byte[] b;
    private int p;
    private final int end;

    private Json(byte[] b, int off, int len) {
        this.b = b;
        this.p = off;
        this.end = off + len;
    }

    public static Object parse(byte[] b, int off, int len) {
        Json j = new Json(b, off, len);
        j.ws();
        Object v = j.value(0);
        j.ws();
        if (j.p != j.end) throw j.bad();
        return v;
    }

    public static Object parse(byte[] b) {
        return parse(b, 0, b.length);
    }

    /** Returns the object under key in m when m is an object, else null. */
    @SuppressWarnings("unchecked")
    public static Map<String, Object> object(Object m, String key) {
        if (!(m instanceof Map)) return null;
        Object v = ((Map<String, Object>) m).get(key);
        return v instanceof Map ? (Map<String, Object>) v : null;
    }

    private IllegalArgumentException bad() {
        return new IllegalArgumentException("malformed JSON at byte " + p);
    }

    private void ws() {
        while (p < end) {
            byte c = b[p];
            if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return;
            p++;
        }
    }

    private Object value(int depth) {
        if (p >= end || depth > MAX_DEPTH) throw bad();
        byte c = b[p];
        switch (c) {
            case '{':
                return object(depth);
            case '[':
                return array(depth);
            case '"':
                return string();
            case 't':
                return literal("true", Boolean.TRUE);
            case 'f':
                return literal("false", Boolean.FALSE);
            case 'n':
                return literal("null", NULL);
            default:
                if (c == '-' || (c >= '0' && c <= '9')) return number();
                throw bad();
        }
    }

    private Object literal(String word, Object v) {
        int n = word.length();
        if (end - p < n) throw bad();
        for (int i = 0; i < n; i++) if (b[p + i] != word.charAt(i)) throw bad();
        p += n;
        return v;
    }

    private Map<String, Object> object(int depth) {
        p++;
        Map<String, Object> m = new HashMap<>();
        ws();
        if (p < end && b[p] == '}') {
            p++;
            return m;
        }
        while (true) {
            ws();
            if (p >= end || b[p] != '"') throw bad();
            String k = string();
            ws();
            if (p >= end || b[p] != ':') throw bad();
            p++;
            ws();
            m.put(k, value(depth + 1));
            ws();
            if (p >= end) throw bad();
            if (b[p] == ',') {
                p++;
            } else if (b[p] == '}') {
                p++;
                return m;
            } else {
                throw bad();
            }
        }
    }

    private List<Object> array(int depth) {
        p++;
        List<Object> l = new ArrayList<>();
        ws();
        if (p < end && b[p] == ']') {
            p++;
            return l;
        }
        while (true) {
            ws();
            l.add(value(depth + 1));
            ws();
            if (p >= end) throw bad();
            if (b[p] == ',') {
                p++;
            } else if (b[p] == ']') {
                p++;
                return l;
            } else {
                throw bad();
            }
        }
    }

    private Double number() {
        int s = p;
        if (b[p] == '-') p++;
        if (p >= end) throw bad();
        if (b[p] == '0') {
            p++;
        } else if (b[p] >= '1' && b[p] <= '9') {
            while (p < end && b[p] >= '0' && b[p] <= '9') p++;
        } else {
            throw bad();
        }
        if (p < end && b[p] == '.') {
            p++;
            int d = p;
            while (p < end && b[p] >= '0' && b[p] <= '9') p++;
            if (p == d) throw bad();
        }
        if (p < end && (b[p] == 'e' || b[p] == 'E')) {
            p++;
            if (p < end && (b[p] == '+' || b[p] == '-')) p++;
            int d = p;
            while (p < end && b[p] >= '0' && b[p] <= '9') p++;
            if (p == d) throw bad();
        }
        return Double.valueOf(new String(b, s, p - s, StandardCharsets.ISO_8859_1));
    }

    private String string() {
        p++;
        int s = p;
        // fast path: no escapes
        while (p < end) {
            byte c = b[p];
            if (c == '"') {
                String r = new String(b, s, p - s, StandardCharsets.UTF_8);
                p++;
                return r;
            }
            if (c == '\\') break;
            if (c >= 0 && c < 0x20) throw bad();
            p++;
        }
        StringBuilder sb = new StringBuilder(new String(b, s, p - s, StandardCharsets.UTF_8));
        while (true) {
            if (p >= end) throw bad();
            byte c = b[p];
            if (c == '"') {
                p++;
                return sb.toString();
            }
            if (c >= 0 && c < 0x20) throw bad();
            if (c != '\\') {
                int r = p;
                while (p < end && b[p] != '"' && b[p] != '\\' && (b[p] < 0 || b[p] >= 0x20)) p++;
                sb.append(new String(b, r, p - r, StandardCharsets.UTF_8));
                continue;
            }
            p++;
            if (p >= end) throw bad();
            byte e = b[p++];
            switch (e) {
                case '"' -> sb.append('"');
                case '\\' -> sb.append('\\');
                case '/' -> sb.append('/');
                case 'b' -> sb.append('\b');
                case 'f' -> sb.append('\f');
                case 'n' -> sb.append('\n');
                case 'r' -> sb.append('\r');
                case 't' -> sb.append('\t');
                case 'u' -> {
                    if (end - p < 4) throw bad();
                    int cp = 0;
                    for (int i = 0; i < 4; i++) {
                        int h = Character.digit(b[p++], 16);
                        if (h < 0) throw bad();
                        cp = cp << 4 | h;
                    }
                    sb.append((char) cp);
                }
                default -> throw bad();
            }
        }
    }
}
