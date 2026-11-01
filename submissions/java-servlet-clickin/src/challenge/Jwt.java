package challenge;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.Arrays;
import javax.crypto.Mac;
import javax.crypto.ShortBufferException;
import javax.crypto.spec.SecretKeySpec;

/** One instance per caller; Mac and scratch space are not thread-safe. */
public final class Jwt {
    private static final byte[] ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".getBytes(StandardCharsets.US_ASCII);

    /** base64url byte to 6-bit value, -1 for anything outside the alphabet. */
    private static final byte[] INDEX = new byte[256];

    static {
        Arrays.fill(INDEX, (byte) -1);
        for (int i = 0; i < ALPHABET.length; i++) {
            INDEX[ALPHABET[i]] = (byte) i;
        }
    }

    private static final byte[] HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9".getBytes(StandardCharsets.US_ASCII);
    private final Mac mac;
    private final byte[] digest = new byte[32];
    private final byte[] signature = new byte[32];
    private final byte[] headerJson = new byte[4096];
    private final byte[] payloadJson = new byte[4096];
    private byte[] json;
    private int pos;
    private int limit;
    private final byte[] payload = new byte[128];
    private static final byte[] SUB = "{\"sub\":\"".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] IAT = "\",\"iat\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] EXP = ",\"exp\":".getBytes(StandardCharsets.US_ASCII);

    public Jwt(String secret) throws GeneralSecurityException {
        mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
    }

    /** Writes a token into out and returns the number of bytes written. */
    public int sign(long userId, long now, byte[] out,
                    int offset) {
        if (userId <= 0) {
            throw new IllegalArgumentException("userId");
        }
        long expiry = Math.addExact(now, 30L * 86400);
        int p = 0;
        System.arraycopy(SUB, 0, payload, p, SUB.length);
        p += SUB.length;
        p = number(userId, payload, p);
        System.arraycopy(IAT, 0, payload, p, IAT.length);
        p += IAT.length;
        p = number(now, payload, p);
        System.arraycopy(EXP, 0, payload, p, EXP.length);
        p += EXP.length;
        p = number(expiry, payload, p);
        payload[p++] = '}';
        int start = offset;
        System.arraycopy(HEADER, 0, out, offset, HEADER.length);
        offset += HEADER.length;
        out[offset++] = '.';
        offset += encode(payload, p, out, offset);
        mac.update(out, start, offset - start);
        finish();
        out[offset++] = '.';
        offset += encode(digest, digest.length, out, offset);
        return offset - start;
    }

    /** Returns a positive user id, or -1 for an invalid token. */
    public long verify(byte[] token, int offset, int length,
                       long now) {
        if (token == null
                || offset < 0
                || length < 0
                || offset > token.length - length) {
            return -1;
        }
        int end = offset + length;
        int dot1 = -1;
        int dot2 = -1;
        for (int i = offset; i < end; i++) {
            if (token[i] == '.') {
                if (dot1 < 0) {
                    dot1 = i;
                } else if (dot2 < 0) {
                    dot2 = i;
                } else {
                    return -1;
                }
            }
        }
        if (dot1 <= offset || dot2 <= dot1 + 1 || end - dot2 != 44) {
            return -1;
        }
        int hn = decode(token, offset, dot1, headerJson);
        if (hn < 0 || decode(token, dot2 + 1, end, signature) != 32) {
            return -1;
        }
        mac.update(token, offset, dot2 - offset);
        finish();
        int diff = 0;
        for (int i = 0; i < 32; i++) {
            diff |= digest[i] ^ signature[i];
        }
        if (diff != 0 || !claims(headerJson, hn, true, now)) {
            return -1;
        }
        int pn = decode(token, dot1 + 1, dot2, payloadJson);
        return pn >= 0 && claims(payloadJson, pn, false, now)
                ? subject
                : -1;
    }

    private long subject;

    private boolean claims(byte[] bytes, int length, boolean header,
                           long now) {
        json = bytes;
        pos = 0;
        limit = length;
        boolean foundAlg = false;
        boolean foundExp = false;
        boolean foundSub = false;
        subject = -1;
        space();
        if (!take('{')) {
            return false;
        }
        space();
        if (!take('}')) {
            do {
                space();
                int start = pos;
                if (!string()) {
                    return false;
                }
                int end = pos;
                boolean alg = header && stringEquals(start, end, "alg");
                boolean exp = !header && stringEquals(start, end, "exp");
                boolean sub = !header && stringEquals(start, end, "sub");
                space();
                if (!take(':')) {
                    return false;
                }
                space();
                if (alg) {
                    start = pos;
                    if (!string() || !stringEquals(start, pos, "HS256")) {
                        return false;
                    }
                    foundAlg = true;
                } else if (exp) {
                    int first = pos;
                    if (!number() || pos == first) {
                        return false;
                    }
                    long value = 0;
                    boolean negative = json[first] == '-';
                    int i = negative ? first + 1 : first;
                    boolean overflow = false;
                    for (; i < pos; i++) {
                        int d = json[i] - '0';
                        if (d < 0 || d > 9) {
                            return false;
                        }
                        if (value < (Long.MIN_VALUE + d) / 10) {
                            overflow = true;
                        } else if (!overflow) {
                            value = value * 10 - d;
                        }
                    }
                    if (negative
                            ? overflow || value <= now
                            : !overflow && value != Long.MIN_VALUE && -value <= now) {
                        return false;
                    }
                    foundExp = true;
                } else if (sub) {
                    if (!take('"')) {
                        return false;
                    }
                    long value = 0;
                    int count = 0;
                    while (pos < limit && json[pos] >= '0' && json[pos] <= '9') {
                        int d = json[pos++] - '0';
                        if (++count > 19 || value > (Long.MAX_VALUE - d) / 10) {
                            return false;
                        }
                        value = value * 10 + d;
                    }
                    if (count == 0 || value == 0 || !take('"')) {
                        return false;
                    }
                    subject = value;
                    foundSub = true;
                } else if (!value()) {
                    return false;
                }
                space();
                if (take('}')) {
                    break;
                }
                if (!take(',')) {
                    return false;
                }
            } while (true);
        }
        space();
        return pos == limit && (header ? foundAlg : foundExp && foundSub);
    }

    private void space() {
        while (pos < limit
                && (json[pos] == ' '
                        || json[pos] == '\n'
                        || json[pos] == '\r'
                        || json[pos] == '\t')) {
            pos++;
        }
    }

    private boolean take(int c) {
        if (pos < limit && json[pos] == c) {
            pos++;
            return true;
        }
        return false;
    }

    private boolean string() {
        if (!take('"')) {
            return false;
        }
        while (pos < limit) {
            int c = json[pos++] & 255;
            if (c == '"') {
                return true;
            }
            if (c < 32) {
                return false;
            }
            if (c >= 128) {
                int count;
                int code;
                if (c >= 0xc2 && c <= 0xdf) {
                    count = 1;
                    code = c & 31;
                } else if (c >= 0xe0 && c <= 0xef) {
                    count = 2;
                    code = c & 15;
                } else if (c >= 0xf0 && c <= 0xf4) {
                    count = 3;
                    code = c & 7;
                } else {
                    return false;
                }
                int remaining = count;
                while (remaining-- > 0) {
                    if (pos == limit || (json[pos] & 0xc0) != 0x80) {
                        return false;
                    }
                    code = code << 6 | (json[pos++] & 63);
                }
                if (count == 2 && code < 0x800
                        || count == 3 && code < 0x10000
                        || code >= 0xd800 && code <= 0xdfff
                        || code > 0x10ffff) {
                    return false;
                }
            }
            if (c == '\\') {
                if (pos == limit) {
                    return false;
                }
                c = json[pos++];
                if (c == 'u') {
                    for (int i = 0; i < 4; i++) {
                        if (pos == limit || hex(json[pos++]) < 0) {
                            return false;
                        }
                    }
                } else if (c != '"'
                        && c != '\\'
                        && c != '/'
                        && c != 'b'
                        && c != 'f'
                        && c != 'n'
                        && c != 'r'
                        && c != 't') {
                    return false;
                }
            }
        }
        return false;
    }

    private static int hex(byte b) {
        if (b >= '0' && b <= '9') {
            return b - '0';
        }
        if (b >= 'a' && b <= 'f') {
            return b - 'a' + 10;
        }
        if (b >= 'A' && b <= 'F') {
            return b - 'A' + 10;
        }
        return -1;
    }

    private boolean stringEquals(int start, int end, String expected) {
        int j = 0;
        for (int i = start + 1; i < end - 1; i++) {
            int c = json[i] & 255;
            if (c == '\\') {
                c = json[++i];
                if (c == 'u') {
                    c = 0;
                    for (int k = 0; k < 4; k++) {
                        c = c * 16 + hex(json[++i]);
                    }
                } else if (c == 'b') {
                    c = 8;
                } else if (c == 'f') {
                    c = 12;
                } else if (c == 'n') {
                    c = 10;
                } else if (c == 'r') {
                    c = 13;
                } else if (c == 't') {
                    c = 9;
                }
            }
            if (j == expected.length() || c != expected.charAt(j++)) {
                return false;
            }
        }
        return j == expected.length();
    }

    private boolean number() {
        take('-');
        if (take('0')) {
            if (pos < limit && json[pos] >= '0' && json[pos] <= '9') {
                return false;
            }
        } else {
            if (pos == limit || json[pos] < '1' || json[pos] > '9') {
                return false;
            }
            while (pos < limit && json[pos] >= '0' && json[pos] <= '9') {
                pos++;
            }
        }
        if (take('.')) {
            int start = pos;
            while (pos < limit && json[pos] >= '0' && json[pos] <= '9') {
                pos++;
            }
            if (pos == start) {
                return false;
            }
        }
        if (take('e') || take('E')) {
            if (!take('+')) {
                take('-');
            }
            int start = pos;
            while (pos < limit && json[pos] >= '0' && json[pos] <= '9') {
                pos++;
            }
            if (pos == start) {
                return false;
            }
        }
        return true;
    }

    private boolean value() {
        byte[] stack = json == headerJson ? payloadJson : headerJson;
        int depth = 0;
        boolean needValue = true;
        while (true) {
            if (needValue) {
                if (pos == limit) {
                    return false;
                }
                if (json[pos] == '"') {
                    if (!string()) {
                        return false;
                    }
                } else if (take('{')) {
                    stack[depth++] = 3;
                    needValue = false;
                    continue;
                } else if (take('[')) {
                    stack[depth++] = 0;
                    needValue = false;
                    continue;
                } else if (json[pos] == '-' || json[pos] >= '0' && json[pos] <= '9') {
                    if (!number()) {
                        return false;
                    }
                } else if (!literal("true") && !literal("false") && !literal("null")) {
                    return false;
                }
                needValue = false;
            }
            if (depth == 0) {
                return true;
            }
            space();
            int state = stack[depth - 1];
            if (state == 0 || state == 1) {
                if (state == 0 && take(']')) {
                    depth--;
                    continue;
                }
                stack[depth - 1] = 2;
                needValue = true;
            } else if (state == 2) {
                if (take(']')) {
                    depth--;
                } else if (take(',')) {
                    stack[depth - 1] = 1;
                } else {
                    return false;
                }
            } else if (state == 3 || state == 4) {
                if (state == 3 && take('}')) {
                    depth--;
                    continue;
                }
                if (!string()) {
                    return false;
                }
                space();
                if (!take(':')) {
                    return false;
                }
                space();
                stack[depth - 1] = 5;
                needValue = true;
            } else {
                if (take('}')) {
                    depth--;
                } else if (take(',')) {
                    stack[depth - 1] = 4;
                } else {
                    return false;
                }
            }
        }
    }

    private boolean literal(String s) {
        if (limit - pos < s.length()) {
            return false;
        }
        for (int i = 0; i < s.length(); i++) {
            if (json[pos + i] != s.charAt(i)) {
                return false;
            }
        }
        pos += s.length();
        return true;
    }

    private static int decode(byte[] in, int from, int to,
            byte[] out) {
        int n = to - from;
        if ((n & 3) == 1 || (long) n * 3 / 4 > out.length) {
            return -1;
        }
        int bits = 0;
        int count = 0;
        int p = 0;
        int invalid = 0;
        for (int i = from; i < to; i++) {
            int v = INDEX[in[i] & 255];
            invalid |= v;
            bits = (bits << 6) | (v & 63);
            count += 6;
            if (count >= 8) {
                count -= 8;
                out[p++] = (byte) (bits >>> count);
            }
        }
        return invalid >= 0 && (bits & ((1 << count) - 1)) == 0
                ? p
                : -1;
    }

    private void finish() {
        try {
            mac.doFinal(digest, 0);
        } catch (ShortBufferException e) {
            throw new AssertionError(e);
        }
    }

    private static int number(long n, byte[] out, int p) {
        if (n > 0) {
            n = -n;
        } else if (n < 0) {
            out[p++] = '-';
        }
        int start = p;
        do {
            out[p++] = (byte) ('0' - n % 10);
            n /= 10;
        } while (n != 0);
        for (int a = start, b = p - 1;
             a < b;
             a++, b--) {
            byte t = out[a];
            out[a] = out[b];
            out[b] = t;
        }
        return p;
    }

    private static int encode(byte[] source, int length, byte[] out,
            int at) {
        int start = at;
        int i = 0;
        while (i + 3 <= length) {
            int v = (source[i++] & 255) << 16 | (source[i++] & 255) << 8 | (source[i++] & 255);
            out[at++] = ALPHABET[v >>> 18];
            out[at++] = ALPHABET[v >>> 12 & 63];
            out[at++] = ALPHABET[v >>> 6 & 63];
            out[at++] = ALPHABET[v & 63];
        }
        if (i < length) {
            int v = (source[i++] & 255) << 16;
            if (i < length) {
                v |= (source[i] & 255) << 8;
            }
            out[at++] = ALPHABET[v >>> 18];
            out[at++] = ALPHABET[v >>> 12 & 63];
            if (length % 3 == 2) {
                out[at++] = ALPHABET[v >>> 6 & 63];
            }
        }
        return at - start;
    }
}
