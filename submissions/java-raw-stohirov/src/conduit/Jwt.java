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

    /** The user id of a valid token, or -1. {@code b[off, off+len)} is the token text. */
    @SuppressWarnings("unchecked")
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
