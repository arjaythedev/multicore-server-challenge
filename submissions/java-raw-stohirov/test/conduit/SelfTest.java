package conduit;

import java.nio.charset.StandardCharsets;
import java.util.Random;

/** Unit checks for the hand-written pieces: bcrypt (every lane width), JWT, timestamps, JSON. Run: tools/selftest.sh */
public final class SelfTest {
    private static int failed;

    private static void check(boolean ok, String what) {
        System.out.println((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failed++;
    }

    public static void main(String[] args) {
        // bcrypt: published vectors (Openwall crypt_blowfish) and the seed's hash of "password123"
        String[][] vectors = {
                {"U*U", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"},
                {"U*U*", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK"},
                {"U*U*U", "$2a$05$XXXXXXXXXXXXXXXXXXXXXOAcXxm9kjPGEMsLznoKqmqw7tc8WCx4a"},
                {"", "$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy"},
                {"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789chars after 72 are ignored",
                        "$2a$05$abcdefghijklmnopqrstuu5s2v8.iXieOjg/.AySBTTZIIVFJeBui"},
                {"password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"},
        };
        for (String[] v : vectors) check(BCrypt.verify(v[0].getBytes(StandardCharsets.UTF_8), v[1]), "bcrypt vector \"" + v[0] + "\"");
        check(!BCrypt.verify("password124".getBytes(StandardCharsets.UTF_8), vectors[5][1]), "bcrypt rejects a wrong password");
        check(BCrypt.verify("hunter2".getBytes(StandardCharsets.UTF_8), BCrypt.hash("hunter2".getBytes(StandardCharsets.UTF_8))), "bcrypt hash round-trips");
        Random rnd = new Random(42);
        for (int k = 1; k <= BCryptLanes.MAX; k++) {
            byte[][] pw = new byte[k][];
            BCrypt.Setting[] st = new BCrypt.Setting[k];
            for (int i = 0; i < k; i++) {
                pw[i] = new byte[rnd.nextInt(80)];
                rnd.nextBytes(pw[i]);
                st[i] = new BCrypt.Setting("$2a$05$", 5, BCrypt.newSetting().salt());
            }
            String[] h = BCrypt.hashLanes(pw, st);
            boolean same = true;
            for (int i = 0; i < k; i++) {
                String one = BCrypt.hashLanes(new byte[][] {pw[i]}, new BCrypt.Setting[] {st[i]})[0];
                same &= one.equals(h[i]);
            }
            check(same, "bcrypt " + k + " lanes match single hashes");
        }

        // JWT
        Jwt.init("multicore-server-challenge");
        String t = Jwt.issue(1234);
        byte[] tb = t.getBytes(StandardCharsets.US_ASCII);
        check(Jwt.verify(tb, 0, tb.length) == 1234, "jwt round-trips");
        tb[tb.length - 2] ^= 1;
        check(Jwt.verify(tb, 0, tb.length) == -1, "jwt rejects a bad signature");

        // timestamps: 2025-04-01T12:00:00.000Z, truncated not rounded
        long micros = (1743508800L - 946684800L) * 1_000_000L + 999_999;
        check(new String(new Buf(32).ts(micros).toBytes(), StandardCharsets.US_ASCII).equals("\"2025-04-01T12:00:00.999Z\""), "timestamp format");
        check(new String(new Buf(32).ts(-1).toBytes(), StandardCharsets.US_ASCII).equals("\"1999-12-31T23:59:59.999Z\""), "timestamp before 2000");

        // JSON
        byte[] j = "{\"a\":\"x\\u00e9\\n\",\"b\":[1,null,true]}".getBytes(StandardCharsets.UTF_8);
        check(Json.parse(j, 0, j.length) != null, "json parses");
        byte[] bad = "{\"a\":1,}".getBytes(StandardCharsets.UTF_8);
        check(Json.parse(bad, 0, bad.length) == null, "json rejects a trailing comma");
        check(new String(new Buf(16).str("a\"b\\c\n\u0001").toBytes(), StandardCharsets.UTF_8).equals("\"a\\\"b\\\\c\\n\\u0001\""), "json escapes");

        System.out.println(failed == 0 ? "all passed" : failed + " failed");
        System.exit(failed == 0 ? 0 : 1);
    }
}
