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
    private final int[] p = new int[18];
    private final int[] s = new int[1024];
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
        int cost = cost(saltString);
        byte[] salt = decode(saltString, 7, 29, 16);
        byte[] bytes = password.getBytes(StandardCharsets.UTF_8);
        byte[] key = Arrays.copyOf(bytes, Math.min(72, bytes.length + 1));
        int[] words = words(key, 18);
        int[] saltWords = words(salt, 4);
        System.arraycopy(INITIAL, 0, p, 0, 18);
        System.arraycopy(INITIAL, 18, s, 0, 1024);
        xor(words);
        expand(saltWords);
        for (long i = 0, n = 1L << cost;
             i < n;
             i++) {
            xor(words);
            expand(null);
            xorSalt(saltWords);
            expand(null);
        }
        int[] text = MAGIC.clone();
        for (int i = 0; i < 64; i++) {
            for (int j = 0; j < 6; j += 2) {
                long block = encrypt(text[j], text[j + 1]);
                text[j] = (int) (block >>> 32);
                text[j + 1] = (int) block;
            }
        }
        return format(saltString, text);
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

    String[] calculateBatch(String[] passwords, String[] salts) {
        int n = passwords.length;
        if (n < 1 || n > 4 || salts.length != n) {
            throw new IllegalArgumentException("invalid batch size");
        }
        for (int i = 0; i < n; i++) {
            validate(passwords[i], salts[i]);
        }
        String[] out = new String[n];
        boolean[] done = new boolean[n];
        for (int i = 0; i < n; i++) {
            if (done[i]) {
                continue;
            }
            int[] indexes = new int[4];
            int count = 0;
            for (int j = i; j < n; j++) {
                if (!done[j] && cost(salts[j]) == cost(salts[i])) {
                    indexes[count++] = j;
                    done[j] = true;
                }
            }
            if (count == 3) {
                out[indexes[2]] = calculateInternal(passwords[indexes[2]], salts[indexes[2]]);
                count = 2;
            }
            if (count == 1) {
                out[i] = calculateInternal(passwords[i], salts[i]);
                continue;
            }
            BCrypt[] lanes = new BCrypt[count];
            int[][] keys = new int[count][];
            int[][] saltWords = new int[count][];
            for (int j = 0; j < count; j++) {
                int k = indexes[j];
                lanes[j] = new BCrypt();
                byte[] bytes = passwords[k].getBytes(StandardCharsets.UTF_8);
                keys[j] = words(Arrays.copyOf(bytes, Math.min(72, bytes.length + 1)), 18);
                saltWords[j] = words(decode(salts[k], 7, 29, 16), 4);
                System.arraycopy(INITIAL, 0, lanes[j].p, 0, 18);
                System.arraycopy(INITIAL, 18, lanes[j].s, 0, 1024);
                lanes[j].xor(keys[j]);
            }
            expandBatch(lanes, saltWords);
            for (long iteration = 0, limit = 1L << cost(salts[i]);
                 iteration < limit;
                 iteration++) {
                for (int j = 0; j < count; j++) {
                    lanes[j].xor(keys[j]);
                }
                expandBatch(lanes, null);
                for (int j = 0; j < count; j++) {
                    lanes[j].xorSalt(saltWords[j]);
                }
                expandBatch(lanes, null);
            }
            for (int j = 0; j < count; j++) {
                int[] text = MAGIC.clone();
                for (int round = 0; round < 64; round++) {
                    for (int k = 0; k < 6; k += 2) {
                        long block = lanes[j].encrypt(text[k], text[k + 1]);
                        text[k] = (int) (block >>> 32);
                        text[k + 1] = (int) block;
                    }
                }
                out[indexes[j]] = format(salts[indexes[j]], text);
            }
        }
        return out;
    }

    private static void expandBatch(BCrypt[] lanes, int[][] salt) {
        if (lanes.length == 2) {
            expand2(lanes, salt);
        } else {
            expand4(lanes, salt);
        }
    }

    private static void expand2(BCrypt[] lanes, int[][] salt) {
        int[] p0 = lanes[0].p;
        int[] s0 = lanes[0].s;
        int l0 = 0;
        int r0 = 0;
        int[] p1 = lanes[1].p;
        int[] s1 = lanes[1].s;
        int l1 = 0;
        int r1 = 0;
        for (int part = 0; part < 2; part++) {
            int length = part == 0 ? 18 : 1024;
            for (int i = 0; i < length; i += 2) {
                if (salt != null) {
                    l0 ^= salt[0][(i + (part == 0 ? 0 : 2)) & 3];
                    r0 ^= salt[0][(i + (part == 0 ? 1 : 3)) & 3];
                }
                l0 ^= p0[0];
                if (salt != null) {
                    l1 ^= salt[1][(i + (part == 0 ? 0 : 2)) & 3];
                    r1 ^= salt[1][(i + (part == 0 ? 1 : 3)) & 3];
                }
                l1 ^= p1[0];
                r0 ^= f(l0, s0) ^ p0[1];
                r1 ^= f(l1, s1) ^ p1[1];
                l0 ^= f(r0, s0) ^ p0[2];
                l1 ^= f(r1, s1) ^ p1[2];
                r0 ^= f(l0, s0) ^ p0[3];
                r1 ^= f(l1, s1) ^ p1[3];
                l0 ^= f(r0, s0) ^ p0[4];
                l1 ^= f(r1, s1) ^ p1[4];
                r0 ^= f(l0, s0) ^ p0[5];
                r1 ^= f(l1, s1) ^ p1[5];
                l0 ^= f(r0, s0) ^ p0[6];
                l1 ^= f(r1, s1) ^ p1[6];
                r0 ^= f(l0, s0) ^ p0[7];
                r1 ^= f(l1, s1) ^ p1[7];
                l0 ^= f(r0, s0) ^ p0[8];
                l1 ^= f(r1, s1) ^ p1[8];
                r0 ^= f(l0, s0) ^ p0[9];
                r1 ^= f(l1, s1) ^ p1[9];
                l0 ^= f(r0, s0) ^ p0[10];
                l1 ^= f(r1, s1) ^ p1[10];
                r0 ^= f(l0, s0) ^ p0[11];
                r1 ^= f(l1, s1) ^ p1[11];
                l0 ^= f(r0, s0) ^ p0[12];
                l1 ^= f(r1, s1) ^ p1[12];
                r0 ^= f(l0, s0) ^ p0[13];
                r1 ^= f(l1, s1) ^ p1[13];
                l0 ^= f(r0, s0) ^ p0[14];
                l1 ^= f(r1, s1) ^ p1[14];
                r0 ^= f(l0, s0) ^ p0[15];
                r1 ^= f(l1, s1) ^ p1[15];
                l0 ^= f(r0, s0) ^ p0[16];
                l1 ^= f(r1, s1) ^ p1[16];
                r0 ^= p0[17];
                if (part == 0) {
                    p0[i] = r0;
                    p0[i + 1] = l0;
                } else {
                    s0[i] = r0;
                    s0[i + 1] = l0;
                }
                int t0 = l0;
                l0 = r0;
                r0 = t0;
                r1 ^= p1[17];
                if (part == 0) {
                    p1[i] = r1;
                    p1[i + 1] = l1;
                } else {
                    s1[i] = r1;
                    s1[i + 1] = l1;
                }
                int t1 = l1;
                l1 = r1;
                r1 = t1;
            }
        }
    }

    private static void expand4(BCrypt[] lanes, int[][] salt) {
        int[] p0 = lanes[0].p;
        int[] s0 = lanes[0].s;
        int l0 = 0;
        int r0 = 0;
        int[] p1 = lanes[1].p;
        int[] s1 = lanes[1].s;
        int l1 = 0;
        int r1 = 0;
        int[] p2 = lanes[2].p;
        int[] s2 = lanes[2].s;
        int l2 = 0;
        int r2 = 0;
        int[] p3 = lanes[3].p;
        int[] s3 = lanes[3].s;
        int l3 = 0;
        int r3 = 0;
        for (int part = 0; part < 2; part++) {
            int length = part == 0 ? 18 : 1024;
            for (int i = 0; i < length; i += 2) {
                if (salt != null) {
                    l0 ^= salt[0][(i + (part == 0 ? 0 : 2)) & 3];
                    r0 ^= salt[0][(i + (part == 0 ? 1 : 3)) & 3];
                }
                l0 ^= p0[0];
                if (salt != null) {
                    l1 ^= salt[1][(i + (part == 0 ? 0 : 2)) & 3];
                    r1 ^= salt[1][(i + (part == 0 ? 1 : 3)) & 3];
                }
                l1 ^= p1[0];
                if (salt != null) {
                    l2 ^= salt[2][(i + (part == 0 ? 0 : 2)) & 3];
                    r2 ^= salt[2][(i + (part == 0 ? 1 : 3)) & 3];
                }
                l2 ^= p2[0];
                if (salt != null) {
                    l3 ^= salt[3][(i + (part == 0 ? 0 : 2)) & 3];
                    r3 ^= salt[3][(i + (part == 0 ? 1 : 3)) & 3];
                }
                l3 ^= p3[0];
                r0 ^= f(l0, s0) ^ p0[1];
                r1 ^= f(l1, s1) ^ p1[1];
                r2 ^= f(l2, s2) ^ p2[1];
                r3 ^= f(l3, s3) ^ p3[1];
                l0 ^= f(r0, s0) ^ p0[2];
                l1 ^= f(r1, s1) ^ p1[2];
                l2 ^= f(r2, s2) ^ p2[2];
                l3 ^= f(r3, s3) ^ p3[2];
                r0 ^= f(l0, s0) ^ p0[3];
                r1 ^= f(l1, s1) ^ p1[3];
                r2 ^= f(l2, s2) ^ p2[3];
                r3 ^= f(l3, s3) ^ p3[3];
                l0 ^= f(r0, s0) ^ p0[4];
                l1 ^= f(r1, s1) ^ p1[4];
                l2 ^= f(r2, s2) ^ p2[4];
                l3 ^= f(r3, s3) ^ p3[4];
                r0 ^= f(l0, s0) ^ p0[5];
                r1 ^= f(l1, s1) ^ p1[5];
                r2 ^= f(l2, s2) ^ p2[5];
                r3 ^= f(l3, s3) ^ p3[5];
                l0 ^= f(r0, s0) ^ p0[6];
                l1 ^= f(r1, s1) ^ p1[6];
                l2 ^= f(r2, s2) ^ p2[6];
                l3 ^= f(r3, s3) ^ p3[6];
                r0 ^= f(l0, s0) ^ p0[7];
                r1 ^= f(l1, s1) ^ p1[7];
                r2 ^= f(l2, s2) ^ p2[7];
                r3 ^= f(l3, s3) ^ p3[7];
                l0 ^= f(r0, s0) ^ p0[8];
                l1 ^= f(r1, s1) ^ p1[8];
                l2 ^= f(r2, s2) ^ p2[8];
                l3 ^= f(r3, s3) ^ p3[8];
                r0 ^= f(l0, s0) ^ p0[9];
                r1 ^= f(l1, s1) ^ p1[9];
                r2 ^= f(l2, s2) ^ p2[9];
                r3 ^= f(l3, s3) ^ p3[9];
                l0 ^= f(r0, s0) ^ p0[10];
                l1 ^= f(r1, s1) ^ p1[10];
                l2 ^= f(r2, s2) ^ p2[10];
                l3 ^= f(r3, s3) ^ p3[10];
                r0 ^= f(l0, s0) ^ p0[11];
                r1 ^= f(l1, s1) ^ p1[11];
                r2 ^= f(l2, s2) ^ p2[11];
                r3 ^= f(l3, s3) ^ p3[11];
                l0 ^= f(r0, s0) ^ p0[12];
                l1 ^= f(r1, s1) ^ p1[12];
                l2 ^= f(r2, s2) ^ p2[12];
                l3 ^= f(r3, s3) ^ p3[12];
                r0 ^= f(l0, s0) ^ p0[13];
                r1 ^= f(l1, s1) ^ p1[13];
                r2 ^= f(l2, s2) ^ p2[13];
                r3 ^= f(l3, s3) ^ p3[13];
                l0 ^= f(r0, s0) ^ p0[14];
                l1 ^= f(r1, s1) ^ p1[14];
                l2 ^= f(r2, s2) ^ p2[14];
                l3 ^= f(r3, s3) ^ p3[14];
                r0 ^= f(l0, s0) ^ p0[15];
                r1 ^= f(l1, s1) ^ p1[15];
                r2 ^= f(l2, s2) ^ p2[15];
                r3 ^= f(l3, s3) ^ p3[15];
                l0 ^= f(r0, s0) ^ p0[16];
                l1 ^= f(r1, s1) ^ p1[16];
                l2 ^= f(r2, s2) ^ p2[16];
                l3 ^= f(r3, s3) ^ p3[16];
                r0 ^= p0[17];
                if (part == 0) {
                    p0[i] = r0;
                    p0[i + 1] = l0;
                } else {
                    s0[i] = r0;
                    s0[i + 1] = l0;
                }
                int t0 = l0;
                l0 = r0;
                r0 = t0;
                r1 ^= p1[17];
                if (part == 0) {
                    p1[i] = r1;
                    p1[i + 1] = l1;
                } else {
                    s1[i] = r1;
                    s1[i + 1] = l1;
                }
                int t1 = l1;
                l1 = r1;
                r1 = t1;
                r2 ^= p2[17];
                if (part == 0) {
                    p2[i] = r2;
                    p2[i + 1] = l2;
                } else {
                    s2[i] = r2;
                    s2[i + 1] = l2;
                }
                int t2 = l2;
                l2 = r2;
                r2 = t2;
                r3 ^= p3[17];
                if (part == 0) {
                    p3[i] = r3;
                    p3[i + 1] = l3;
                } else {
                    s3[i] = r3;
                    s3[i + 1] = l3;
                }
                int t3 = l3;
                l3 = r3;
                r3 = t3;
            }
        }
    }

    private void xor(int[] key) {
        for (int i = 0; i < 18; i++) {
            p[i] ^= key[i];
        }
    }

    private void xorSalt(int[] salt) {
        for (int i = 0; i < 18; i++) {
            p[i] ^= salt[i & 3];
        }
    }

    private void expand(int[] salt) {
        long block = 0;
        block = expandP(salt, block);
        expandS(salt, block);
    }

    private long expandP(int[] salt, long block) {
        int[] array = p;
        int left = (int) (block >>> 32);
        int right = (int) block;
        for (int i = 0; i < array.length; i += 2) {
            if (salt != null) {
                left ^= salt[i & 3];
                right ^= salt[(i + 1) & 3];
            }
            block = encrypt(left, right);
            left = (int) (block >>> 32);
            right = (int) block;
            array[i] = left;
            array[i + 1] = right;
        }
        return block;
    }

    private void expandS(int[] salt, long block) {
        int[] p = this.p;
        int[] s = this.s;
        if (p.length < 18 || s.length < 1024) {
            throw new AssertionError();
        }
        int p0 = p[0];
        int p1 = p[1];
        int p2 = p[2];
        int p3 = p[3];
        int p4 = p[4];
        int p5 = p[5];
        int p6 = p[6];
        int p7 = p[7];
        int p8 = p[8];
        int p9 = p[9];
        int p10 = p[10];
        int p11 = p[11];
        int p12 = p[12];
        int p13 = p[13];
        int p14 = p[14];
        int p15 = p[15];
        int p16 = p[16];
        int p17 = p[17];
        int left = (int) (block >>> 32);
        int right = (int) block;
        for (int i = 0; i < 1024; i += 2) {
            if (salt != null) {
                left ^= salt[(i + 2) & 3];
                right ^= salt[(i + 3) & 3];
            }
            left ^= p0;
            right ^= f(left, s) ^ p1;
            left ^= f(right, s) ^ p2;
            right ^= f(left, s) ^ p3;
            left ^= f(right, s) ^ p4;
            right ^= f(left, s) ^ p5;
            left ^= f(right, s) ^ p6;
            right ^= f(left, s) ^ p7;
            left ^= f(right, s) ^ p8;
            right ^= f(left, s) ^ p9;
            left ^= f(right, s) ^ p10;
            right ^= f(left, s) ^ p11;
            left ^= f(right, s) ^ p12;
            right ^= f(left, s) ^ p13;
            left ^= f(right, s) ^ p14;
            right ^= f(left, s) ^ p15;
            left ^= f(right, s) ^ p16;
            right ^= p17;
            s[i] = right;
            s[i + 1] = left;
            int t = left;
            left = right;
            right = t;
        }
    }

    private static int f(int x, int[] s) {
        return ((s[x >>> 24] + s[256 | ((x >>> 16) & 255)]) ^ s[512 | ((x >>> 8) & 255)]) + s[768 | (x & 255)];
    }

    private long encrypt(int left, int right) {
        int[] p = this.p;
        int[] s = this.s;
        if (p.length < 18 || s.length < 1024) {
            throw new AssertionError();
        }
        left ^= p[0];
        right ^= f(left, s) ^ p[1];
        left ^= f(right, s) ^ p[2];
        right ^= f(left, s) ^ p[3];
        left ^= f(right, s) ^ p[4];
        right ^= f(left, s) ^ p[5];
        left ^= f(right, s) ^ p[6];
        right ^= f(left, s) ^ p[7];
        left ^= f(right, s) ^ p[8];
        right ^= f(left, s) ^ p[9];
        left ^= f(right, s) ^ p[10];
        right ^= f(left, s) ^ p[11];
        left ^= f(right, s) ^ p[12];
        right ^= f(left, s) ^ p[13];
        left ^= f(right, s) ^ p[14];
        right ^= f(left, s) ^ p[15];
        left ^= f(right, s) ^ p[16];
        right ^= p[17];
        return (long) right << 32 | (left & 0xffffffffL);
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
