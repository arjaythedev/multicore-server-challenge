package challenge;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class JwtTest {
    private static String token(String header, String payload) throws Exception {
        var enc = Base64.getUrlEncoder().withoutPadding();
        String input = enc.encodeToString(header.getBytes(StandardCharsets.UTF_8)) + "." + enc.encodeToString(payload.getBytes(StandardCharsets.UTF_8));
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec("secret".getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        return input + "." + enc.encodeToString(mac.doFinal(input.getBytes(StandardCharsets.US_ASCII)));
    }

    private static long verify(Jwt jwt, String token, long now) {
        byte[] b = ("xx" + token + "yy").getBytes(StandardCharsets.US_ASCII);
        return jwt.verify(b, 2, b.length - 4, now);
    }

    private static void check(Jwt jwt, String token, long now,
            long expected) {
        long actual = verify(jwt, token, now);
        if (actual != expected) {
            throw new AssertionError(token + " expected " + expected + " got " + actual);
        }
    }

    public static void main(String[] args) throws Exception {
        Jwt jwt = new Jwt("secret");
        byte[] buf = new byte[512];
        int n = jwt.sign(123, 1000, buf, 0);
        if (jwt.verify(buf, 0, n, 1000) != 123 || jwt.verify(buf, 0, n, 1000 + 30 * 86400) != -1) {
            throw new AssertionError("round trip or expiration");
        }
        buf[n - 5] = buf[n - 5] == 'A' ? (byte) 'B' : (byte) 'A';
        if (jwt.verify(buf, 0, n, 1000) != -1) {
            throw new AssertionError("signature");
        }
        String h = "{\"alg\":\"HS256\"}";
        String p = "{\"sub\":\"1\",\"exp\":1001}";
        check(jwt, token(h, p), 1000, 1);
        check(jwt, token(" { \"typ\" : \"JWT\", \"alg\" : \"HS256\" } ", " { \"extra\": [true, false, null, {\"x\":\"a\\\\\\\"b\",\"n\":-1.2e+3}], \"exp\" : 1001, \"sub\" : \"42\" } "),
                1000, 42);
        check(jwt, token("{\"al\\u0067\":\"HS\\u003256\"}", "{\"s\\u0075b\":\"1\",\"exp\":1001}"),
                1000, 1);
        check(jwt, token(h, "{\"sub\":\"1\",\"exp\":1001,\"x\":"
                + "[".repeat(1000)
                + "0"
                + "]".repeat(1000)
                + "}"),
                1000, 1);
        String[] bad = {
            token("{\"alg\":\"HS384\"}", p),
            token("{\"alg\":\"none\"}", p),
            token(h, "{\"sub\":\"1\"}"),
            token(h, "{\"sub\":\"1\",\"exp\":1000}"),
            token(h, "{\"sub\":\"abc\",\"exp\":1001}"),
            token(h, "{\"sub\":1,\"exp\":1001}"),
            token(h, "{\"sub\":\"9223372036854775808\",\"exp\":1001}"),
            token(h, "{\"sub\":\"1\",\"exp\":1001.0}"),
            token(h, "{\"sub\":\"1\",\"exp\":1e3}"),
            token(h, "{\"sub\":\"1\",\"exp\":1001,\"x\":[1,]}"),
            token(h, p).replaceFirst("\\.", "!."),
            token(h, p) + ".x"
        };
        for (String s : bad) {
            check(jwt, s, 1000, -1);
        }
        check(jwt, token(h, "{\"sub\":\"1\",\"exp\":-1}"), -2, 1);
        check(jwt, token(h, "{\"sub\":\"1\",\"exp\":9223372036854775808}"), Long.MAX_VALUE, 1);
        n = jwt.sign(Long.MAX_VALUE, -1, buf, 0);
        String generated = new String(buf, 0, n, StandardCharsets.US_ASCII);
        if (!generated.equals(token("{\"alg\":\"HS256\",\"typ\":\"JWT\"}", "{\"sub\":\"9223372036854775807\",\"iat\":-1,\"exp\":2591999}"))) {
            throw new AssertionError("signed payload");
        }
    }
}
