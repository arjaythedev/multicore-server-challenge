package conduit;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.time.Duration;
import java.util.Base64;
import java.util.concurrent.ConcurrentLinkedQueue;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

import io.avaje.json.JsonReader;
import io.avaje.jsonb.Jsonb;

/**
 * HS256 tokens: {"sub": "<user id>", "iat": now, "exp": now + 30 days}. Verified on every request, no cache: the
 * signature is recomputed each time. Only the {@link Mac} objects are reused, since they hold no per-token state
 * once {@code doFinal} has run.
 */
final class Jwt {

    private static final Duration TTL = Duration.ofDays(30);
    private static final Base64.Encoder ENCODER = Base64.getUrlEncoder().withoutPadding();
    private static final Base64.Decoder DECODER = Base64.getUrlDecoder();
    private static final String HEADER = ENCODER.encodeToString("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.UTF_8));

    private final SecretKeySpec key;
    private final Jsonb jsonb;
    /** Initialised MACs. HMAC never blocks, so a virtual thread holds one only until it next yields: at most one per carrier. */
    private final ConcurrentLinkedQueue<Mac> macs = new ConcurrentLinkedQueue<>();

    Jwt(String secret, Jsonb jsonb) {
        this.key = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
        this.jsonb = jsonb;
    }

    String sign(long userId) {
        long now = System.currentTimeMillis() / 1000;
        String payload = "{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + (now + TTL.toSeconds()) + "}";
        String signingInput = HEADER + '.' + ENCODER.encodeToString(payload.getBytes(StandardCharsets.UTF_8));
        byte[] bytes = signingInput.getBytes(StandardCharsets.US_ASCII);
        return signingInput + '.' + ENCODER.encodeToString(hmac(bytes, bytes.length));
    }

    /** The token's user id, or 0 if the token is invalid or expired. */
    long verify(String token) {
        try {
            int first = token.indexOf('.');
            int second = token.indexOf('.', first + 1);
            if (first < 0 || second < 0 || token.indexOf('.', second + 1) >= 0) {
                return 0;
            }
            byte[] signed = token.getBytes(StandardCharsets.US_ASCII);
            byte[] expected = hmac(signed, second);
            if (!MessageDigest.isEqual(expected, DECODER.decode(token.substring(second + 1)))) {
                return 0;
            }
            // our own tokens carry exactly this header; any other has to be read to check its algorithm
            boolean ours = first == HEADER.length() && token.startsWith(HEADER);
            if (!ours && !isHs256(DECODER.decode(token.substring(0, first)))) {
                return 0;
            }
            return subject(DECODER.decode(token.substring(first + 1, second)));
        } catch (RuntimeException ex) {
            return 0;
        }
    }

    /** True if the header's {@code alg} is the string HS256 (and appears once). */
    private boolean isHs256(byte[] header) {
        boolean hs256 = false;
        boolean seen = false;
        try (JsonReader reader = jsonb.reader(header)) {
            reader.beginObject();
            while (reader.hasNextField()) {
                if (reader.nextField().equals("alg")) {
                    if (seen || reader.currentToken() != JsonReader.Token.STRING) {
                        return false;
                    }
                    seen = true;
                    hs256 = "HS256".equals(reader.readString());
                } else {
                    reader.skipValue();
                }
            }
            reader.endObject();
        }
        return hs256;
    }

    /**
     * The user id in {@code sub} (a JSON string of digits) if {@code exp} (a JSON number) is in the future, else 0.
     * Each of the two must appear once.
     */
    private long subject(byte[] claims) {
        String sub = null;
        double exp = Double.NaN;
        boolean seenSub = false;
        boolean seenExp = false;
        try (JsonReader reader = jsonb.reader(claims)) {
            reader.beginObject();
            while (reader.hasNextField()) {
                switch (reader.nextField()) {
                    case "sub" -> {
                        if (seenSub || reader.currentToken() != JsonReader.Token.STRING) {
                            return 0;
                        }
                        seenSub = true;
                        sub = reader.readString();
                    }
                    case "exp" -> {
                        if (seenExp || reader.currentToken() != JsonReader.Token.NUMBER) {
                            return 0;
                        }
                        seenExp = true;
                        exp = reader.readDouble();
                    }
                    default -> reader.skipValue();
                }
            }
            reader.endObject();
        }
        if (!(exp > System.currentTimeMillis() / 1000)) {
            return 0;
        }
        long id = sub == null ? -1 : Body.parseUint(sub);
        return id > 0 ? id : 0;
    }

    private byte[] hmac(byte[] input, int length) {
        Mac mac = macs.poll();
        try {
            if (mac == null) {
                mac = Mac.getInstance("HmacSHA256");
                mac.init(key);
            }
            mac.update(input, 0, length);
            byte[] out = mac.doFinal();   // also resets the MAC to its freshly initialised state
            macs.offer(mac);
            return out;
        } catch (GeneralSecurityException ex) {
            throw new IllegalStateException(ex);
        }
    }
}
