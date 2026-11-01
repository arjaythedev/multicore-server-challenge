package dev.mccue.vertx.realworld;

import dev.mccue.json.Json;
import dev.mccue.json.JsonNumber;
import dev.mccue.json.JsonObject;
import dev.mccue.json.JsonString;
import org.jspecify.annotations.Nullable;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Base64;

/// HS256 JWTs. Every token's signature, alg and exp are checked on every request; nothing is remembered.
final class Jwt {
    private static final long THIRTY_DAYS = 30L * 24 * 60 * 60;
    private static final String HEADER = Base64.getUrlEncoder().withoutPadding()
            .encodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));

    private final SecretKeySpec key;
    // A Mac isn't thread safe; each event loop gets its own.
    private final ThreadLocal<Mac> macs;

    Jwt(String secret) {
        this.key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
        this.macs = ThreadLocal.withInitial(() -> {
            try {
                var mac = Mac.getInstance("HmacSHA256");
                mac.init(key);
                return mac;
            } catch (GeneralSecurityException e) {
                throw new IllegalStateException(e);
            }
        });
    }

    String issue(long userId) {
        long now = System.currentTimeMillis() / 1000;
        var payload = Base64.getUrlEncoder().withoutPadding().encodeToString(
                ("{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + THIRTY_DAYS) + "}")
                        .getBytes(StandardCharsets.UTF_8));
        var signingInput = HEADER + "." + payload;
        return signingInput + "." + Base64.getUrlEncoder().withoutPadding().encodeToString(sign(signingInput));
    }

    /// The user id in a valid token, or null if the token is malformed, not HS256, badly signed, expired,
    /// or has no exp or no decimal-string sub.
    @Nullable Long verify(String token) {
        int firstDot = token.indexOf('.');
        int secondDot = token.indexOf('.', firstDot + 1);
        if (firstDot <= 0 || secondDot <= firstDot + 1 || token.indexOf('.', secondDot + 1) != -1) {
            return null;
        }
        try {
            var decoder = Base64.getUrlDecoder();
            var header = Json.readString(new String(decoder.decode(token.substring(0, firstDot)), StandardCharsets.UTF_8));
            if (!(header instanceof JsonObject headerObject)
                || !(headerObject.get("alg") instanceof JsonString alg)
                || !alg.toString().equals("HS256")) {
                return null;
            }

            var signature = decoder.decode(token.substring(secondDot + 1));
            if (!MessageDigest.isEqual(signature, sign(token.substring(0, secondDot)))) {
                return null;
            }

            var payload = Json.readString(new String(decoder.decode(token.substring(firstDot + 1, secondDot)), StandardCharsets.UTF_8));
            if (!(payload instanceof JsonObject claims)
                || !(claims.get("exp") instanceof JsonNumber exp)
                || exp.longValue() <= System.currentTimeMillis() / 1000
                || !(claims.get("sub") instanceof JsonString sub)) {
                return null;
            }
            var subject = sub.toString();
            if (subject.isEmpty() || !subject.chars().allMatch(c -> c >= '0' && c <= '9')) {
                return null;
            }
            return Long.parseLong(subject);
        } catch (RuntimeException e) {
            // bad base64, bad JSON, a sub too large for a long
            return null;
        }
    }

    private byte[] sign(String signingInput) {
        return macs.get().doFinal(signingInput.getBytes(StandardCharsets.US_ASCII));
    }
}
