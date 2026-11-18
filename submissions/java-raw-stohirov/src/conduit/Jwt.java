package conduit;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Map;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/** HS256 tokens: issued on register/login, verified (signature, alg, exp) on every request. */
final class Jwt {
    private static SecretKeySpec key;
    private static final ThreadLocal<Mac> MAC = ThreadLocal.withInitial(() -> {
        try {
            Mac m = Mac.getInstance("HmacSHA256");
            m.init(key);
            return m;
        } catch (Exception e) {
            throw new IllegalStateException(e);
        }
    });
    private static final byte[] HEADER = Base64.getUrlEncoder().withoutPadding()
            .encode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.US_ASCII));
    private static final Base64.Encoder ENC = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DEC = Base64.getUrlDecoder();

    static void init(String secret) {
        key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
    }

    static String issue(long userId) {
        long now = System.currentTimeMillis() / 1000;
        String payload = "{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + 30L * 24 * 3600) + "}";
        byte[] p = ENC.encode(payload.getBytes(StandardCharsets.US_ASCII));
        byte[] signing = new byte[HEADER.length + 1 + p.length];
        System.arraycopy(HEADER, 0, signing, 0, HEADER.length);
        signing[HEADER.length] = '.';
        System.arraycopy(p, 0, signing, HEADER.length + 1, p.length);
        byte[] sig = ENC.encode(MAC.get().doFinal(signing));
        return new String(signing, StandardCharsets.US_ASCII) + "." + new String(sig, StandardCharsets.US_ASCII);
    }

    private static final byte[] UNB64 = new byte[256];

    static {
        java.util.Arrays.fill(UNB64, (byte) -1);
        byte[] al = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".getBytes(StandardCharsets.US_ASCII);
        for (int i = 0; i < 64; i++) UNB64[al[i]] = (byte) i;
    }

    /** Decodes unpadded base64url into out; the decoded length, or -1 if the text isn't plain base64url. */
    private static int decode(byte[] b, int from, int to, byte[] out) {
        int n = to - from, o = 0, i = from;
        if (n % 4 == 1 || n / 4 * 3 + 2 > out.length) return -1;
        int bad = 0;
        for (; i + 4 <= to; i += 4) {
            int v = UNB64[b[i] & 0xff] << 18 | UNB64[b[i + 1] & 0xff] << 12 | UNB64[b[i + 2] & 0xff] << 6 | UNB64[b[i + 3] & 0xff];
            bad |= v;
            out[o++] = (byte) (v >> 16);
            out[o++] = (byte) (v >> 8);
            out[o++] = (byte) v;
        }
        if (i + 2 <= to) {
            int v = UNB64[b[i] & 0xff] << 18 | UNB64[b[i + 1] & 0xff] << 12 | (i + 3 <= to ? UNB64[b[i + 2] & 0xff] << 6 : 0);
            bad |= v;
            out[o++] = (byte) (v >> 16);
            if (i + 3 <= to) out[o++] = (byte) (v >> 8);
        }
        return bad < 0 ? -1 : o;
    }

    private static long flatClaimsId(byte[] p, int n) {
        return flatClaims(p, n, System.currentTimeMillis() / 1000.0);
    }

    /**
     * The common token: {"key":"digits-or-plain-text" or integer, ...}, flat, no escapes or spaces. Returns the user
     * id, -1 for a rejected token, or -2 for anything else, which the full parser then decides.
     */
    private static long flatClaims(byte[] p, int n, double now) {
        if (n < 2 || p[0] != '{' || p[n - 1] != '}') return -2;
        long exp = -1, nbf = -1, sub = -1;
        boolean hasExp = false, hasNbf = false, hasSub = false;
        int i = 1, end = n - 1;
        while (i < end) {
            if (p[i++] != '"') return -2;
            int ks = i;
            while (i < end && p[i] != '"') {
                if (p[i] == '\\' || (p[i] & 0x80) != 0) return -2;
                i++;
            }
            int kl = i - ks;
            if (i + 1 >= end || p[i + 1] != ':') return -2;
            i += 2;
            boolean isS = kl == 3 && p[ks] == 's' && p[ks + 1] == 'u' && p[ks + 2] == 'b';
            boolean isE = kl == 3 && p[ks] == 'e' && p[ks + 1] == 'x' && p[ks + 2] == 'p';
            boolean isN = kl == 3 && p[ks] == 'n' && p[ks + 1] == 'b' && p[ks + 2] == 'f';
            if (i >= end) return -2;
            if (p[i] == '"') {
                if (isE || isN) return -2;
                int vs = ++i;
                while (i < end && p[i] != '"') {
                    if (p[i] == '\\' || (p[i] & 0x80) != 0) return -2;
                    i++;
                }
                if (i >= end) return -2;
                if (isS) {
                    int len = i - vs;
                    if (len == 0 || len > 18) return -1;
                    long id = 0;
                    for (int x = vs; x < i; x++) {
                        int d = p[x] - '0';
                        if (d < 0 || d > 9) return -1;
                        id = id * 10 + d;
                    }
                    sub = id;
                    hasSub = true;
                }
                i++;
            } else {
                // only plain non-negative integers of up to 15 digits: exact as doubles, like the full parser's
                int vs = i;
                long v = 0;
                while (i < end && p[i] >= '0' && p[i] <= '9') v = v * 10 + (p[i++] - '0');
                int len = i - vs;
                if (len == 0 || len > 15 || (len > 1 && p[vs] == '0')) return -2;
                if (isS) return -2;
                if (isE) {
                    exp = v;
                    hasExp = true;
                } else if (isN) {
                    nbf = v;
                    hasNbf = true;
                }
            }
            if (i == end) break;
            if (p[i++] != ',' || i == end) return -2;
        }
        if (!hasExp || !(now < exp)) return -1;
        if (hasNbf && nbf > now) return -1;
        return hasSub ? sub : -1;
    }

    /** The user id of a valid token, or -1. {@code b[off, off+len)} is the token text. */
    static long verify(byte[] b, int off, int len) {
        int end = off + len;
        int d1 = -1, d2 = -1;
        for (int i = off; i < end; i++) {
            if (b[i] == '.') {
                if (d1 < 0) d1 = i;
                else if (d2 < 0) d2 = i;
                else return -1;
            }
        }
        if (d2 < 0 || d1 == off || d2 == d1 + 1 || d2 == end - 1) return -1;
        // the common token: our exact header, 32 signature bytes, flat claims
        if (d1 - off == HEADER.length && end - d2 - 1 == 43 && java.util.Arrays.equals(b, off, d1, HEADER, 0, HEADER.length)) {
            Mac mac = MAC.get();
            mac.update(b, off, d2 - off);
            byte[] want = mac.doFinal();
            byte[] got = new byte[33];
            if (decode(b, d2 + 1, end, got) == 32) {
                int diff = 0;
                for (int i = 0; i < 32; i++) diff |= want[i] ^ got[i];
                if (diff != 0) return -1;
                byte[] p = new byte[Math.max(0, (d2 - d1 - 1) / 4 * 3 + 3)];
                int n = decode(b, d1 + 1, d2, p);
                long id = n < 0 ? -2 : flatClaimsId(p, n);
                if (id != -2) return id;
            }
        }
        return verifyFull(b, off, len, d1, d2);
    }

    @SuppressWarnings("unchecked")
    private static long verifyFull(byte[] b, int off, int len, int d1, int d2) {
        int end = off + len;
        try {
            Mac mac = MAC.get();
            mac.update(b, off, d2 - off);
            byte[] want = mac.doFinal();
            byte[] got = DEC.decode(java.util.Arrays.copyOfRange(b, d2 + 1, d2 + 1 + end - d2 - 1));
            if (!MessageDigest.isEqual(want, got)) return -1;
            byte[] h = DEC.decode(java.util.Arrays.copyOfRange(b, off, off + d1 - off));
            Object hv = Json.parse(h, 0, h.length);
            if (!(hv instanceof Map) || !"HS256".equals(((Map<String, Object>) hv).get("alg"))) return -1;
            byte[] p = DEC.decode(java.util.Arrays.copyOfRange(b, d1 + 1, d1 + 1 + d2 - d1 - 1));
            Object pv = Json.parse(p, 0, p.length);
            if (!(pv instanceof Map)) return -1;
            Map<String, Object> claims = (Map<String, Object>) pv;
            double now = System.currentTimeMillis() / 1000.0;
            if (!(claims.get("exp") instanceof Double exp) || !(now < exp)) return -1;
            Object nbf = claims.get("nbf");
            if (nbf != null && (!(nbf instanceof Double n) || n > now)) return -1;
            if (!(claims.get("sub") instanceof String sub) || sub.isEmpty() || sub.length() > 18) return -1;
            long id = 0;
            for (int i = 0; i < sub.length(); i++) {
                char c = sub.charAt(i);
                if (c < '0' || c > '9') return -1;
                id = id * 10 + (c - '0');
            }
            return id;
        } catch (IllegalArgumentException e) {
            return -1;
        }
    }
}
