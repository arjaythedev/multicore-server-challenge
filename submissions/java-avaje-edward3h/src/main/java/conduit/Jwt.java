package conduit;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;
import java.util.Map;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import io.avaje.jsonb.JsonType;
import io.avaje.jsonb.Jsonb;
import io.avaje.jsonb.Types;

/** HS256 tokens: {"sub": "<user id>", "iat": now, "exp": now + 30 days}. Verified on every request, no cache. */
final class Jwt {

    private static final Duration TTL = Duration.ofDays(30);
    private static final Base64.Encoder ENCODER = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DECODER = Base64.getUrlDecoder();
    private static final String HEADER = ENCODER.encodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));

    private final SecretKeySpec key;
    private final JsonType<Map<String, Object>> claimsType;

    Jwt(String secret, Jsonb jsonb) {
        this.key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
        this.claimsType = jsonb.type(Types.mapOf(Object.class));
    }

    String sign(long userId) {
        long now = Instant.now().getEpochSecond();
        String payload = "{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + TTL.toSeconds()) + "}";
        String signingInput = HEADER + '.' + ENCODER.encodeToString(payload.getBytes(StandardCharsets.UTF_8));
        return signingInput + '.' + ENCODER.encodeToString(hmac(signingInput));
    }

    /** The token's user id, or 0 if the token is invalid or expired. */
    long verify(String token) {
        try {
            int first = token.indexOf('.');
            int second = token.indexOf('.', first + 1);
            if (first < 0 || second < 0 || token.indexOf('.', second + 1) >= 0) {
                return 0;
            }
            byte[] expected = hmac(token.substring(0, second));
            if (!MessageDigest.isEqual(expected, DECODER.decode(token.substring(second + 1)))) {
                return 0;
            }
            Map<String, Object> header = claimsType.fromJson(DECODER.decode(token.substring(0, first)));
            if (!"HS256".equals(header.get("alg"))) {
                return 0;
            }
            Map<String, Object> claims = claimsType.fromJson(DECODER.decode(token.substring(first + 1, second)));
            if (!(claims.get("exp") instanceof Number exp) || exp.doubleValue() <= Instant.now().getEpochSecond()) {
                return 0;
            }
            // sub must be a JSON string of digits
            long id = claims.get("sub") instanceof String sub ? Body.parseUint(sub) : -1;
            return id > 0 ? id : 0;
        } catch (RuntimeException ex) {
            return 0;
        }
    }

    private byte[] hmac(String input) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(key);
            return mac.doFinal(input.getBytes(StandardCharsets.US_ASCII));
        } catch (java.security.GeneralSecurityException ex) {
            throw new IllegalStateException(ex);
        }
    }
}
