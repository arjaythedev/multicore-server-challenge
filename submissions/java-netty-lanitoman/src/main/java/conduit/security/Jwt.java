package conduit.security;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * HS256 JSON Web Tokens with the claims {"sub": "<user id>", "iat": now, "exp": now + 30 days}. Every request's
 * token is verified from scratch: signature, algorithm and expiry. Nothing is remembered between requests.
 */
public final class Jwt {
    private static final long LIFETIME_SECONDS = 30L * 24 * 3600;
    private static final String HEADER = base64Url("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));
    private static final JsonFactory JSON = new JsonFactory();

    private static byte[] secret;
    /** A keyed HMAC per thread: Mac objects aren't thread-safe, and keying one costs more than using it. */
    private static final ThreadLocal<Mac> HMAC = ThreadLocal.withInitial(Jwt::newMac);

    private Jwt() {
    }

    public static void init(String jwtSecret) {
        secret = jwtSecret.getBytes(StandardCharsets.UTF_8);
    }

    public static String issue(long userId) {
        long now = System.currentTimeMillis() / 1000;
        String payload = "{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + LIFETIME_SECONDS) + "}";
        String signingInput = HEADER + "." + base64Url(payload.getBytes(StandardCharsets.UTF_8));
        return signingInput + "." + base64Url(sign(signingInput.getBytes(StandardCharsets.US_ASCII), signingInput.length()));
    }

    /** The token's user id, or 0 when the token is invalid in any way. */
    public static long verify(String token) {
        if (token.length() < 5 || token.length() > 4096) return 0;
        int firstDot = token.indexOf('.');
        int lastDot = token.lastIndexOf('.');
        if (firstDot < 1 || lastDot <= firstDot + 1 || token.indexOf('.', firstDot + 1) != lastDot) return 0;
        try {
            Base64.Decoder decoder = Base64.getUrlDecoder();
            // nothing inside the token is trusted before its signature checks out
            byte[] signature = decoder.decode(token.substring(lastDot + 1));
            byte[] expected = sign(token.getBytes(StandardCharsets.US_ASCII), lastDot);
            if (!MessageDigest.isEqual(signature, expected)) return 0;
            if (!headerSaysHs256(decoder.decode(token.substring(0, firstDot)))) return 0;
            return subjectIfNotExpired(decoder.decode(token.substring(firstDot + 1, lastDot)));
        } catch (IllegalArgumentException | IOException e) {
            return 0;                                   // not base64url, or not JSON
        }
    }

    private static boolean headerSaysHs256(byte[] json) throws IOException {
        boolean hs256 = false;
        try (JsonParser parser = JSON.createParser(json)) {
            if (parser.nextToken() != JsonToken.START_OBJECT) return false;
            while (parser.nextToken() == JsonToken.FIELD_NAME) {
                String name = parser.currentName();
                JsonToken value = parser.nextToken();
                if (name.equals("alg")) {
                    if (value != JsonToken.VALUE_STRING || !parser.getText().equals("HS256")) return false;
                    hs256 = true;
                } else {
                    parser.skipChildren();
                }
            }
        }
        return hs256;
    }

    /** "sub" must be a decimal string and "exp" a number in the future. */
    private static long subjectIfNotExpired(byte[] json) throws IOException {
        long subject = 0;
        double expires = -1;
        try (JsonParser parser = JSON.createParser(json)) {
            if (parser.nextToken() != JsonToken.START_OBJECT) return 0;
            while (parser.nextToken() == JsonToken.FIELD_NAME) {
                String name = parser.currentName();
                JsonToken value = parser.nextToken();
                switch (name) {
                    case "sub" -> {
                        if (value != JsonToken.VALUE_STRING) return 0;
                        subject = parseUserId(parser.getText());
                        if (subject == 0) return 0;
                    }
                    case "exp" -> {
                        if (value != JsonToken.VALUE_NUMBER_INT && value != JsonToken.VALUE_NUMBER_FLOAT) return 0;
                        expires = parser.getDoubleValue();
                    }
                    default -> parser.skipChildren();
                }
            }
        }
        if (subject == 0 || expires < 0) return 0;
        return expires > System.currentTimeMillis() / 1000.0 ? subject : 0;
    }

    /** A positive id written with decimal digits only (at most 18, so it can't overflow); 0 otherwise. */
    private static long parseUserId(String digits) {
        if (digits.isEmpty() || digits.length() > 18) return 0;
        long id = 0;
        for (int i = 0; i < digits.length(); i++) {
            char c = digits.charAt(i);
            if (c < '0' || c > '9') return 0;
            id = id * 10 + (c - '0');
        }
        return id;
    }

    private static byte[] sign(byte[] data, int length) {
        Mac mac = HMAC.get();
        mac.update(data, 0, length);
        return mac.doFinal();
    }

    private static Mac newMac() {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret, "HmacSHA256"));
            return mac;
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    private static String base64Url(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }
}
