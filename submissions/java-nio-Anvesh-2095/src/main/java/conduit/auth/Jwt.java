package conduit.auth;

import conduit.http.Json;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Map;

/** HS256 JWTs: {"sub": "<user id>", "iat": now, "exp": now + 30 days}. Every request verifies; nothing is cached. */
public final class Jwt {
    private static final long TTL_S = 30L * 24 * 3600;
    private static final String HEADER = b64("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.US_ASCII));
    private static final Base64.Decoder DEC = Base64.getUrlDecoder();

    private static SecretKeySpec key;
    private static final ThreadLocal<Mac> MAC = ThreadLocal.withInitial(() -> {
        try {
            Mac m = Mac.getInstance("HmacSHA256");
            m.init(key);
            return m;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    });

    private Jwt() {
    }

    public static void init(String secret) {
        key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
    }

    public static String mint(long userId) {
        long now = System.currentTimeMillis() / 1000;
        String payload = b64(("{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + TTL_S) + "}")
                .getBytes(StandardCharsets.US_ASCII));
        String signed = HEADER + "." + payload;
        return signed + "." + b64(MAC.get().doFinal(signed.getBytes(StandardCharsets.US_ASCII)));
    }

    /** Returns the token's user id, or -1 if the token is malformed, not HS256, badly signed or expired. */
    public static long verify(String token) {
        int d1 = token.indexOf('.');
        int d2 = d1 < 0 ? -1 : token.indexOf('.', d1 + 1);
        if (d1 <= 0 || d2 < 0 || token.indexOf('.', d2 + 1) >= 0 || d2 == token.length() - 1) return -1;
        try {
            Object header = Json.parse(DEC.decode(token.substring(0, d1)));
            if (!(header instanceof Map<?, ?> h) || !"HS256".equals(h.get("alg"))) return -1;

            byte[] sig = DEC.decode(token.substring(d2 + 1));
            byte[] want = MAC.get().doFinal(token.substring(0, d2).getBytes(StandardCharsets.ISO_8859_1));
            if (!MessageDigest.isEqual(sig, want)) return -1;

            Object payload = Json.parse(DEC.decode(token.substring(d1 + 1, d2)));
            if (!(payload instanceof Map<?, ?> p)) return -1;
            if (!(p.get("exp") instanceof Double exp) || exp <= System.currentTimeMillis() / 1000.0) return -1;
            if (!(p.get("sub") instanceof String sub) || sub.isEmpty() || sub.length() > 18) return -1;
            long id = 0;
            for (int i = 0; i < sub.length(); i++) {
                char c = sub.charAt(i);
                if (c < '0' || c > '9') return -1;
                id = id * 10 + (c - '0');
            }
            return id > 0 ? id : -1;
        } catch (IllegalArgumentException e) {
            return -1;
        }
    }

    private static String b64(byte[] b) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
    }
}
