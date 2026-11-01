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

    private static long jwt(String claims) {
        return jwtWithHeader("{\"alg\":\"HS256\",\"typ\":\"JWT\"}", claims);
    }

    private static long jwtWithHeader(String header, String claims) {
        try {
            java.util.Base64.Encoder e = java.util.Base64.getUrlEncoder().withoutPadding();
            String h = e.encodeToString(header.getBytes(StandardCharsets.UTF_8)), c = e.encodeToString(claims.getBytes(StandardCharsets.UTF_8));
            javax.crypto.Mac m = javax.crypto.Mac.getInstance("HmacSHA256");
            m.init(new javax.crypto.spec.SecretKeySpec("multicore-server-challenge".getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            String t = h + "." + c + "." + e.encodeToString(m.doFinal((h + "." + c).getBytes(StandardCharsets.US_ASCII)));
            byte[] b = t.getBytes(StandardCharsets.US_ASCII);
            return Jwt.verify(b, 0, b.length);
        } catch (Exception x) {
            throw new IllegalStateException(x);
        }
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
        java.util.List<Integer> kernels = new java.util.ArrayList<>(java.util.List.of(BCrypt.JAVA));
        if (BCryptNative.available()) for (int style : BCryptNative.styles()) kernels.add(style);
        else System.out.println("note: no native kernels here, Java kernels only");
        for (int style : kernels) {
            for (String[] v : vectors) {
                BCrypt.Setting vs = BCrypt.parse(v[1]);
                check(BCrypt.hashLanes(new byte[][] {v[0].getBytes(StandardCharsets.UTF_8)}, new BCrypt.Setting[] {vs}, style)[0].equals(v[1]),
                        "bcrypt " + BCryptNative.name(style) + " vector \"" + v[0] + "\"");
            }
            for (int k = 1; k <= BCryptLanes.MAX; k++) {
                byte[][] pw = new byte[k][];
                BCrypt.Setting[] st = new BCrypt.Setting[k];
                for (int i = 0; i < k; i++) {
                    pw[i] = new byte[rnd.nextInt(80)];
                    rnd.nextBytes(pw[i]);
                    st[i] = new BCrypt.Setting("$2a$05$", 5, BCrypt.newSetting().salt());
                }
                String[] h = BCrypt.hashLanes(pw, st, style);
                boolean same = true;
                for (int i = 0; i < k; i++) same &= BCrypt.hashLanes(new byte[][] {pw[i]}, new BCrypt.Setting[] {st[i]}, BCrypt.JAVA)[0].equals(h[i]);
                check(same, "bcrypt " + BCryptNative.name(style) + " " + k + " lanes match single Java hashes");
            }
        }

        // JWT
        Jwt.init("multicore-server-challenge");
        String t = Jwt.issue(1234);
        byte[] tb = t.getBytes(StandardCharsets.US_ASCII);
        check(Jwt.verify(tb, 0, tb.length) == 1234, "jwt round-trips");
        tb[tb.length - 2] ^= 1;
        check(Jwt.verify(tb, 0, tb.length) == -1, "jwt rejects a bad signature");

        // JWT: the fast path and the full parser agree (same secret, hand-built tokens)
        long future = System.currentTimeMillis() / 1000 + 3600, past = System.currentTimeMillis() / 1000 - 3600;
        check(jwt("{\"sub\":\"77\",\"iat\":1,\"exp\":" + future + "}") == 77, "jwt flat claims");
        check(jwt("{\"exp\":" + future + ",\"sub\":\"78\"}") == 78, "jwt claims in any order");
        check(jwt("{ \"sub\" : \"79\", \"exp\" : " + future + " }") == 79, "jwt with spaces (full parser)");
        check(jwt("{\"sub\":\"80\",\"exp\":" + future + ".5}") == 80, "jwt fractional exp (full parser)");
        check(jwt("{\"sub\":\"81\",\"exp\":" + past + "}") == -1, "jwt rejects an expired token");
        check(jwt("{\"sub\":\"82\"}") == -1, "jwt rejects a missing exp");
        check(jwt("{\"sub\":\"83\",\"exp\":\"" + future + "\"}") == -1, "jwt rejects a string exp");
        check(jwt("{\"sub\":83,\"exp\":" + future + "}") == -1, "jwt rejects a numeric sub");
        check(jwt("{\"sub\":\"8x\",\"exp\":" + future + "}") == -1, "jwt rejects a non-numeric sub");
        check(jwt("{\"exp\":" + future + "}") == -1, "jwt rejects a missing sub");
        check(jwt("{\"sub\":\"84\",\"exp\":" + future + ",\"nbf\":" + future + "}") == -1, "jwt rejects a future nbf");
        check(jwt("{\"sub\":\"85\",\"exp\":" + future + ",\"nbf\":" + past + "}") == 85, "jwt accepts a past nbf");
        check(jwt("{\"sub\":\"86\",\"exp\":" + future + ",\"x\":{\"exp\":1}}") == 86, "jwt nested claim (full parser)");
        check(jwt("{\"sub\":\"87\",\"exp\":1,\"exp\":" + future + "}") == 87, "jwt duplicate claim: the last one counts");
        check(jwt("[1,2]") == -1, "jwt rejects a non-object payload");
        check(jwtWithHeader("{\"alg\":\"none\",\"typ\":\"JWT\"}", "{\"sub\":\"88\",\"exp\":" + future + "}") == -1, "jwt rejects alg none");
        check(jwtWithHeader("{\"typ\":\"JWT\",\"alg\":\"HS256\"}", "{\"sub\":\"89\",\"exp\":" + future + "}") == 89, "jwt accepts another header spelling");

        // the key maps
        LongKeys lk = new LongKeys();
        PairKeys pk = new PairKeys();
        java.util.HashMap<Long, Integer> lm = new java.util.HashMap<>();
        java.util.HashMap<String, Integer> pm = new java.util.HashMap<>();
        boolean mapsOk = true;
        for (int i = 0; i < 200_000; i++) {
            long a = rnd.nextInt(5000) - 100, b = rnd.nextInt(50);
            int li = lk.idx(a), pi = pk.idx(a, b);
            Integer ol = lm.putIfAbsent(a, lm.size()), op = pm.putIfAbsent(a + "/" + b, pm.size());
            mapsOk &= li == (ol == null ? lm.size() - 1 : ol) && pi == (op == null ? pm.size() - 1 : op);
            mapsOk &= lk.find(a) == li && pk.find(a, b) == pi && lk.find(a + 1_000_000) == -1 && pk.find(a, b + 1000) == -1;
        }
        check(mapsOk && lk.n == lm.size() && pk.n == pm.size(), "key maps match HashMap");

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
