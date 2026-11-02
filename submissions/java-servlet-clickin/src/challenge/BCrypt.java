package challenge;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;

/** A bcrypt instance belongs to one worker thread. */
public final class BCrypt {
    private static final String B64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    private static final int[] INITIAL = initial();
    private static final int[] MAGIC = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    private final SecureRandom random = new SecureRandom();

    public String hash(String password) {
        return calculate(password, newSalt());
    }

    String newSalt() {
        byte[] salt = new byte[16];
        random.nextBytes(salt);
        return "$2b$10$" + encode(salt);
    }

    boolean matches(String actual, String hash) {
        return MessageDigest.isEqual(actual.getBytes(StandardCharsets.US_ASCII), hash.getBytes(StandardCharsets.US_ASCII));
    }

    public boolean verify(String password, String hash) {
        if (hash == null || hash.length() != 60) {
            return false;
        }
        try {
            String actual = calculateInternal(password, hash);
            return MessageDigest.isEqual(actual.getBytes(StandardCharsets.US_ASCII), hash.getBytes(StandardCharsets.US_ASCII));
        } catch (IllegalArgumentException e) {
            return false;
        }
    }

    public String calculate(String password, String saltString) {
        if (saltString == null || saltString.length() != 29) {
            throw new IllegalArgumentException("invalid bcrypt salt");
        }
        return calculateInternal(password, saltString);
    }

    private String calculateInternal(String password, String saltString) {
        validate(password, saltString);
        String[] out = new String[1];
        run(new String[] {password}, new String[] {saltString}, new int[1],
                1, out);
        return out[0];
    }

    static int cost(String saltString) {
        return (saltString.charAt(4) - '0') * 10 + saltString.charAt(5) - '0';
    }

    static void validate(String password, String saltString) {
        if (password == null
                || saltString == null
                || saltString.length() < 29
                || !saltString.startsWith("$2")
                || "aby".indexOf(saltString.charAt(2)) < 0
                || saltString.charAt(3) != '$'
                || saltString.charAt(6) != '$'
                || !Character.isDigit(saltString.charAt(4))
                || !Character.isDigit(saltString.charAt(5))) {
            throw new IllegalArgumentException("invalid bcrypt salt");
        }
        int cost = cost(saltString);
        if (cost < 4 || cost > 31) {
            throw new IllegalArgumentException("invalid bcrypt cost");
        }
        byte[] salt = decode(saltString, 7, 29, 16);
        if (!saltString.regionMatches(7, encode(salt), 0, 22)) {
            throw new IllegalArgumentException("noncanonical bcrypt salt");
        }
    }

    private static String format(String saltString, int[] text) {
        byte[] result = new byte[23];
        for (int i = 0; i < result.length; i++) {
            result[i] = (byte) (text[i / 4] >>> (24 - 8 * (i % 4)));
        }
        return new StringBuilder(60)
                .append(saltString, 0, 29)
                .append(encode(result))
                .toString();
    }

    /**
     * The width with the lowest time per hash on this core, timed at cost 7
     * after a JIT warm-up (~2-5 s of one core at startup). A wider kernel must
     * win by 3% to be picked: more lanes take longer to fill and hold logins
     * longer.
     */
    static int fastestLanes(StringBuilder curve) {
        BCrypt bcrypt = new BCrypt();
        int best = 1;
        double bestNanos = Double.MAX_VALUE;
        // the first sweep runs while C2 is still compiling the kernels; only the second is kept
        for (int pass = 0; pass < 2; pass++) {
            best = 1;
            bestNanos = Double.MAX_VALUE;
            for (int lanes = 1; lanes <= BCryptLanes.MAX; lanes++) {
                String[] passwords = new String[lanes];
                String[] warm = new String[lanes];
                String[] timed = new String[lanes];
                for (int i = 0; i < lanes; i++) {
                    String salt = bcrypt.newSalt().substring(7);
                    passwords[i] = "password" + i;
                    warm[i] = "$2b$04$" + salt;
                    timed[i] = "$2b$07$" + salt;
                }
                for (int i = 0; i < 40; i++) {
                    bcrypt.calculateBatch(passwords, warm);
                }
                long min = Long.MAX_VALUE;
                for (int i = 0; i < 3; i++) {
                    long start = System.nanoTime();
                    bcrypt.calculateBatch(passwords, timed);
                    min = Math.min(min, System.nanoTime() - start);
                }
                double perHash = (double) min / lanes;
                curve.append(pass == 0 ? "" : String.format(" %d:%.1fms", lanes, perHash / 1e6));
                if (perHash < bestNanos * 0.97) {
                    best = lanes;
                    bestNanos = perHash;
                }
            }
        }
        return best;
    }

    /**
     * Up to BCryptLanes.MAX hashes; those sharing a cost run interleaved in one
     * kernel.
     */
    String[] calculateBatch(String[] passwords, String[] salts) {
        int n = passwords.length;
        if (n < 1 || n > BCryptLanes.MAX || salts.length != n) {
            throw new IllegalArgumentException("invalid batch size");
        }
        for (int i = 0; i < n; i++) {
            validate(passwords[i], salts[i]);
        }
        String[] out = new String[n];
        int[] group = new int[n];
        for (int i = 0; i < n; i++) {
            if (out[i] != null) {
                continue;
            }
            int count = 0;
            for (int j = i; j < n; j++) {
                if (out[j] == null && cost(salts[j]) == cost(salts[i])) {
                    group[count++] = j;
                }
            }
            run(passwords, salts, group, count, out);
        }
        return out;
    }

    /**
     * Hashes passwords[group[0..count)] (validated, all one cost) together into
     * out.
     */
    private static void run(String[] passwords, String[] salts, int[] group,
                            int count, String[] out) {
        int[][] p = new int[count][];
        int[][] s = new int[count][];
        int[][] key = new int[count][];
        int[][] salt4 = new int[count][];
        int[][] salt18 = new int[count][];
        int[][] text = new int[count][];
        for (int k = 0; k < count; k++) {
            byte[] bytes = passwords[group[k]].getBytes(StandardCharsets.UTF_8);
            byte[] salt = decode(salts[group[k]], 7, 29, 16);
            p[k] = Arrays.copyOf(INITIAL, 18);
            s[k] = Arrays.copyOfRange(INITIAL, 18, 18 + 1024);
            key[k] = words(Arrays.copyOf(bytes, Math.min(72, bytes.length + 1)), 18);
            salt4[k] = words(salt, 4);
            salt18[k] = words(salt, 18);
            text[k] = MAGIC.clone();
        }
        BCryptLanes.expandSalted(count, p, s, key, salt4);
        for (long i = 0, n = 1L << cost(salts[group[0]]);
             i < n;
             i++) {
            BCryptLanes.expand(count, p, s, key);
            BCryptLanes.expand(count, p, s, salt18);
        }
        BCryptLanes.encrypt(count, p, s, text);
        for (int k = 0; k < count; k++) {
            out[group[k]] = format(salts[group[k]], text[k]);
        }
    }

    private static int[] words(byte[] bytes, int count) {
        int[] result = new int[count];
        int p = 0;
        for (int i = 0; i < count; i++) {
            for (int j = 0; j < 4; j++) {
                result[i] = result[i] << 8 | bytes[p] & 255;
                p = (p + 1) % bytes.length;
            }
        }
        return result;
    }

    private static String encode(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (int p = 0; p < b.length; ) {
            int x = b[p++] & 255;
            s.append(B64.charAt(x >>> 2));
            x = (x & 3) << 4;
            if (p == b.length) {
                s.append(B64.charAt(x));
                break;
            }
            int y = b[p++] & 255;
            s.append(B64.charAt(x | y >>> 4));
            x = (y & 15) << 2;
            if (p == b.length) {
                s.append(B64.charAt(x));
                break;
            }
            y = b[p++] & 255;
            s.append(B64.charAt(x | y >>> 6));
            s.append(B64.charAt(y & 63));
        }
        return s.toString();
    }

    private static byte[] decode(String s, int from, int end,
            int size) {
        byte[] b = new byte[size];
        int buffer = 0;
        int bits = 0;
        int p = 0;
        for (int i = from; i < end; i++) {
            int v = B64.indexOf(s.charAt(i));
            if (v < 0) {
                throw new IllegalArgumentException("invalid bcrypt base64");
            }
            buffer = buffer << 6 | v;
            bits += 6;
            if (bits >= 8) {
                bits -= 8;
                if (p < size) {
                    b[p++] = (byte) (buffer >>> bits);
                }
            }
        }
        if (p != size) {
            throw new IllegalArgumentException("short bcrypt salt");
        }
        return b;
    }

    private static int[] initial() {
        int count = 1042;
        int bits = count * 32;
        int guard = 64;
        BigInteger one = BigInteger.ONE.shiftLeft(bits + guard);
        BigInteger pi = atan(5, one)
                .shiftLeft(4)
                .subtract(atan(239, one).shiftLeft(2));
        BigInteger fraction = pi.shiftRight(guard).subtract(BigInteger.valueOf(3)
                .shiftLeft(bits));
        int[] words = new int[count];
        for (int i = 0; i < count; i++) {
            words[i] = fraction.shiftRight(32 * (count - 1 - i)).intValue();
        }
        return words;
    }

    private static BigInteger atan(int x, BigInteger one) {
        BigInteger square = BigInteger.valueOf((long) x * x);
        BigInteger power = one.divide(BigInteger.valueOf(x));
        BigInteger sum = BigInteger.ZERO;
        for (int i = 0; power.signum() != 0; i++) {
            BigInteger term = power.divide(BigInteger.valueOf(2L * i + 1));
            sum = (i & 1) == 0 ? sum.add(term) : sum.subtract(term);
            power = power.divide(square);
        }
        return sum;
    }
}
