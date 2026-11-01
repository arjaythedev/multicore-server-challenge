package conduit;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * A strict JSON parser for request bodies. Objects become maps, arrays lists, strings strings, numbers
 * {@link Double}, true/false {@link Boolean}, null {@link #NULL}. Malformed input gives {@code null}.
 */
final class Json {
    static final Object NULL = new Object();

    private final byte[] s;
    private int i;
    private final int end;

    private Json(byte[] s, int off, int len) {
        this.s = s;
        this.i = off;
        this.end = off + len;
    }

    static Object parse(byte[] s, int off, int len) {
        Json p = new Json(s, off, len);
        try {
            Object v = p.value(0);
            p.ws();
            return p.i == p.end ? v : null;
        } catch (RuntimeException e) {
            return null;
        }
    }

    private static RuntimeException bad() {
        return new IllegalArgumentException();
    }

    private void ws() {
        while (i < end) {
            byte c = s[i];
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') i++;
            else break;
        }
    }

    private Object value(int depth) {
        if (depth > 64) throw bad();
        ws();
        if (i >= end) throw bad();
        byte c = s[i];
        switch (c) {
            case '{': {
                i++;
                Map<String, Object> m = new HashMap<>();
                ws();
                if (i < end && s[i] == '}') {
                    i++;
                    return m;
                }
                while (true) {
                    ws();
                    if (i >= end || s[i] != '"') throw bad();
                    String k = string();
                    ws();
                    if (i >= end || s[i] != ':') throw bad();
                    i++;
                    m.put(k, value(depth + 1));
                    ws();
                    if (i >= end) throw bad();
                    if (s[i] == ',') {
                        i++;
                    } else if (s[i] == '}') {
                        i++;
                        return m;
                    } else throw bad();
                }
            }
            case '[': {
                i++;
                List<Object> l = new ArrayList<>();
                ws();
                if (i < end && s[i] == ']') {
                    i++;
                    return l;
                }
                while (true) {
                    l.add(value(depth + 1));
                    ws();
                    if (i >= end) throw bad();
                    if (s[i] == ',') {
                        i++;
                    } else if (s[i] == ']') {
                        i++;
                        return l;
                    } else throw bad();
                }
            }
            case '"':
                return string();
            case 't':
                lit("true");
                return Boolean.TRUE;
            case 'f':
                lit("false");
                return Boolean.FALSE;
            case 'n':
                lit("null");
                return NULL;
            default:
                return number();
        }
    }

    private void lit(String w) {
        int l = w.length();
        if (end - i < l) throw bad();
        for (int k = 0; k < l; k++) if (s[i + k] != w.charAt(k)) throw bad();
        i += l;
    }

    private Object number() {
        int st = i;
        if (i < end && s[i] == '-') i++;
        int d0 = i;
        while (i < end && s[i] >= '0' && s[i] <= '9') i++;
        if (i == d0) throw bad();
        if (s[d0] == '0' && i - d0 > 1) throw bad();
        if (i < end && s[i] == '.') {
            i++;
            int f0 = i;
            while (i < end && s[i] >= '0' && s[i] <= '9') i++;
            if (i == f0) throw bad();
        }
        if (i < end && (s[i] == 'e' || s[i] == 'E')) {
            i++;
            if (i < end && (s[i] == '+' || s[i] == '-')) i++;
            int e0 = i;
            while (i < end && s[i] >= '0' && s[i] <= '9') i++;
            if (i == e0) throw bad();
        }
        return Double.valueOf(new String(s, st, i - st, StandardCharsets.US_ASCII));
    }

    private String string() {
        i++; // opening quote
        int st = i;
        // fast path: no escapes
        while (i < end) {
            int c = s[i] & 0xff;
            if (c == '"') {
                String r = new String(s, st, i - st, StandardCharsets.UTF_8);
                i++;
                return r;
            }
            if (c == '\\') break;
            if (c < 0x20) throw bad();
            i++;
        }
        StringBuilder sb = new StringBuilder(new String(s, st, i - st, StandardCharsets.UTF_8));
        int run = i;
        while (true) {
            if (i >= end) throw bad();
            int c = s[i] & 0xff;
            if (c == '"') {
                sb.append(new String(s, run, i - run, StandardCharsets.UTF_8));
                i++;
                return sb.toString();
            }
            if (c < 0x20) throw bad();
            if (c != '\\') {
                i++;
                continue;
            }
            sb.append(new String(s, run, i - run, StandardCharsets.UTF_8));
            i++;
            if (i >= end) throw bad();
            byte e = s[i++];
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
                    if (end - i < 4) throw bad();
                    int v = 0;
                    for (int k = 0; k < 4; k++) {
                        int h = Character.digit(s[i + k], 16);
                        if (h < 0) throw bad();
                        v = v << 4 | h;
                    }
                    i += 4;
                    sb.append((char) v);
                }
                default -> throw bad();
            }
            run = i;
        }
    }

    // ---- field access for validation ----

    /** The object under key {@code wrap}, or null if the body isn't {"wrap": {...}}. */
    @SuppressWarnings("unchecked")
    static Map<String, Object> wrapped(byte[] body, int off, int len, String wrap) {
        if (len == 0) return null;
        Object v = parse(body, off, len);
        if (!(v instanceof Map)) return null;
        Object w = ((Map<String, Object>) v).get(wrap);
        return w instanceof Map ? (Map<String, Object>) w : null;
    }

    /** A required non-empty string field, or null. */
    static String required(Map<String, Object> m, String k) {
        Object v = m.get(k);
        return v instanceof String str && !str.isEmpty() ? str : null;
    }

    /** Sentinel: the field is present but invalid. */
    static final String INVALID = new String("\0invalid");

    /** An optional string field: null when absent or JSON null, INVALID when not a string (or empty if !allowEmpty). */
    static String optional(Map<String, Object> m, String k, boolean allowEmpty) {
        Object v = m.get(k);
        if (v == null || v == NULL) return null;
        if (!(v instanceof String str)) return INVALID;
        if (!allowEmpty && str.isEmpty()) return INVALID;
        return str;
    }
}
