package dev.moose.conduit.auth;

import dev.moose.conduit.json.JsonReader;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Base64;
import java.util.Map;

public class JwtService {

    public static final long INVALID = -1;

    private static final long THIRTY_DAYS_SECONDS = 30L * 24 * 60 * 60;
    private static final Base64.Encoder ENCODER = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DECODER = Base64.getUrlDecoder();
    private static final String HEADER = ENCODER.encodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));

    private final ThreadLocal<Mac> macs;

    public JwtService(String secret) {
        final SecretKeySpec key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
        this.macs = ThreadLocal.withInitial(() -> {
            try {
                final Mac mac = Mac.getInstance("HmacSHA256");
                mac.init(key);
                return mac;
            } catch (GeneralSecurityException exception) {
                throw new IllegalStateException(exception);
            }
        });
    }

    public String issue(long userId) {
        final long now = System.currentTimeMillis() / 1000;
        final String claims = "{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + THIRTY_DAYS_SECONDS) + "}";
        final String signingInput = HEADER + "." + ENCODER.encodeToString(claims.getBytes(StandardCharsets.UTF_8));
        return signingInput + "." + ENCODER.encodeToString(sign(signingInput));
    }

    public long verify(String token) {
        final int firstDot = token.indexOf('.');
        final int secondDot = token.indexOf('.', firstDot + 1);
        if (firstDot <= 0 || secondDot <= firstDot + 1 || token.indexOf('.', secondDot + 1) != -1) {
            return INVALID;
        }
        try {
            if (!token.regionMatches(0, HEADER, 0, firstDot) || firstDot != HEADER.length()) {
                final Object header = JsonReader.parse(DECODER.decode(token.substring(0, firstDot)));
                if (!(header instanceof Map<?, ?> headerObject) || !"HS256".equals(headerObject.get("alg"))) {
                    return INVALID;
                }
            }
            final byte[] signature = DECODER.decode(token.substring(secondDot + 1));
            if (!MessageDigest.isEqual(signature, sign(token.substring(0, secondDot)))) {
                return INVALID;
            }
            final Object payload = JsonReader.parse(DECODER.decode(token.substring(firstDot + 1, secondDot)));
            if (!(payload instanceof Map<?, ?> claims)) {
                return INVALID;
            }
            if (!(claims.get("exp") instanceof Double expiry) || expiry <= System.currentTimeMillis() / 1000.0) {
                return INVALID;
            }
            if (!(claims.get("sub") instanceof String subject)) {
                return INVALID;
            }
            return parseId(subject);
        } catch (IllegalArgumentException | JsonReader.MalformedException exception) {
            return INVALID;
        }
    }

    private static long parseId(String subject) {
        if (subject.isEmpty() || subject.length() > 18) {
            return INVALID;
        }
        long value = 0;
        for (int i = 0; i < subject.length(); i++) {
            final char character = subject.charAt(i);
            if (character < '0' || character > '9') {
                return INVALID;
            }
            value = value * 10 + (character - '0');
        }
        return value;
    }

    private byte[] sign(String signingInput) {
        return this.macs.get().doFinal(signingInput.getBytes(StandardCharsets.US_ASCII));
    }

}
