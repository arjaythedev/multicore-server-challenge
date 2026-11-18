package conduit.auth;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;

/**
 * bcrypt ($2a$/$2b$), written from the algorithm (Provos and Mazières, 1999) so the build has no dependencies.
 *
 * <p>Blowfish's initial P-array and S-boxes are the fractional hex digits of pi, so instead of embedding 1,042
 * constants they are computed once at class load (Machin's formula in fixed point, a few milliseconds) and checked
 * against the well-known first words.
 */
public final class Bcrypt {
    public static final int COST = 10;
    private static final String B64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    private static final int[] B64_INDEX = new int[128];
    /** "OrpheanBeholderScryDoubt" as six big-endian words. */
    private static final int[] CTEXT = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    private static final int[] P_INIT = new int[18];
    private static final int[] S_INIT = new int[1024];
    private static final SecureRandom RANDOM = new SecureRandom();

    static {
        java.util.Arrays.fill(B64_INDEX, -1);
        for (int i = 0; i < B64.length(); i++) B64_INDEX[B64.charAt(i)] = i;
        int[] words = piWords(18 + 1024);
        System.arraycopy(words, 0, P_INIT, 0, 18);
        System.arraycopy(words, 18, S_INIT, 0, 1024);
        if (P_INIT[0] != 0x243f6a88 || P_INIT[17] != 0x8979fb1b || S_INIT[0] != 0xd1310ba6 || S_INIT[1023] != 0x3ac372e6) {
            throw new IllegalStateException("Blowfish constants computed wrong");
        }
    }

    private Bcrypt() {
    }

    /** The first n 32-bit words of pi's fractional part. */
    private static int[] piWords(int n) {
        int bits = n * 32 + 64; // 64 guard bits absorb the series' rounding error
        BigInteger pi = atan(5, bits).shiftLeft(4).subtract(atan(239, bits).shiftLeft(2)); // 16 atan(1/5) - 4 atan(1/239)
        BigInteger frac = pi.subtract(BigInteger.valueOf(3).shiftLeft(bits)).shiftRight(64);
        int[] w = new int[n];
        for (int i = 0; i < n; i++) w[i] = frac.shiftRight((n - 1 - i) * 32).intValue();
        return w;
    }

    /** atan(1/x) * 2^bits, by its Taylor series. */
    private static BigInteger atan(int x, int bits) {
        BigInteger xx = BigInteger.valueOf((long) x * x);
        BigInteger term = BigInteger.ONE.shiftLeft(bits).divide(BigInteger.valueOf(x));
        BigInteger sum = term;
        for (int k = 1; term.signum() != 0; k++) {
            term = term.divide(xx);
            BigInteger t = term.divide(BigInteger.valueOf(2L * k + 1));
            sum = (k & 1) == 1 ? sum.subtract(t) : sum.add(t);
        }
        return sum;
    }

    /** Hashes a password at {@link #COST} with a random salt, as "$2b$10$...". */
    public static String hash(String password) {
        byte[] salt = new byte[16];
        RANDOM.nextBytes(salt);
        StringBuilder sb = new StringBuilder(60).append("$2b$").append(COST).append('$');
        encode(sb, salt, 16);
        return hash(password, sb.toString());
    }

    /** Checks a password against a stored "$2a$"/"$2b$"/"$2y$" hash, in constant time. */
    public static boolean check(String password, String stored) {
        String h;
        try {
            h = hash(password, stored);
        } catch (IllegalArgumentException e) {
            return false;
        }
        return MessageDigest.isEqual(h.getBytes(StandardCharsets.US_ASCII), stored.getBytes(StandardCharsets.US_ASCII));
    }

    /** bcrypt with the version, cost and salt taken from setting (a full hash or just its first 29 characters). */
    static String hash(String password, String setting) {
        if (setting.length() < 29 || setting.charAt(0) != '$' || setting.charAt(1) != '2' || setting.charAt(3) != '$'
                || setting.charAt(6) != '$' || "aby".indexOf(setting.charAt(2)) < 0) {
            throw new IllegalArgumentException("bad bcrypt setting");
        }
        int cost = Integer.parseInt(setting, 4, 6, 10);
        if (cost < 4 || cost > 31) throw new IllegalArgumentException("bad bcrypt cost");
        byte[] salt = decode(setting, 7, 16);

        byte[] pw = password.getBytes(StandardCharsets.UTF_8);
        int keyLen = Math.min(pw.length + 1, 72); // NUL-terminated, at most 72 bytes
        byte[] key = new byte[keyLen];
        System.arraycopy(pw, 0, key, 0, Math.min(pw.length, keyLen));

        int[] p = P_INIT.clone();
        int[] s = S_INIT.clone();
        int[] lr = new int[2];
        expand(p, s, lr, key, salt);
        for (long i = 1L << cost; i > 0; i--) {
            expand(p, s, lr, key, null);
            expand(p, s, lr, salt, null);
        }
        int[] c = CTEXT.clone();
        for (int i = 0; i < 64; i++) {
            for (int j = 0; j < 6; j += 2) {
                lr[0] = c[j];
                lr[1] = c[j + 1];
                encipher(p, s, lr);
                c[j] = lr[0];
                c[j + 1] = lr[1];
            }
        }
        byte[] out = new byte[24];
        for (int i = 0; i < 6; i++) {
            out[4 * i] = (byte) (c[i] >>> 24);
            out[4 * i + 1] = (byte) (c[i] >>> 16);
            out[4 * i + 2] = (byte) (c[i] >>> 8);
            out[4 * i + 3] = (byte) c[i];
        }
        StringBuilder sb = new StringBuilder(60).append(setting, 0, 29);
        encode(sb, out, 23);
        return sb.toString();
    }

    /**
     * Blowfish key schedule step. With salt == null it is the plain ExpandKey(state, key); with a salt it is the
     * salted variant, which XORs the salt into each block before encrypting it.
     */
    private static void expand(int[] p, int[] s, int[] lr, byte[] key, byte[] salt) {
        int[] kpos = {0};
        for (int i = 0; i < 18; i++) p[i] ^= word(key, kpos);
        int[] spos = {0};
        lr[0] = 0;
        lr[1] = 0;
        for (int i = 0; i < 18; i += 2) {
            if (salt != null) {
                lr[0] ^= word(salt, spos);
                lr[1] ^= word(salt, spos);
            }
            encipher(p, s, lr);
            p[i] = lr[0];
            p[i + 1] = lr[1];
        }
        for (int i = 0; i < 1024; i += 2) {
            if (salt != null) {
                lr[0] ^= word(salt, spos);
                lr[1] ^= word(salt, spos);
            }
            encipher(p, s, lr);
            s[i] = lr[0];
            s[i + 1] = lr[1];
        }
    }

    /** The next 4 bytes of data as a big-endian word, cycling through data. */
    private static int word(byte[] data, int[] pos) {
        int w = 0;
        int j = pos[0];
        for (int i = 0; i < 4; i++) {
            w = w << 8 | data[j] & 0xff;
            j = (j + 1) % data.length;
        }
        pos[0] = j;
        return w;
    }

    private static void encipher(int[] p, int[] s, int[] lr) {
        int l = lr[0] ^ p[0], r = lr[1];
        for (int i = 1; i <= 16; i += 2) {
            r ^= (((s[l >>> 24] + s[0x100 | l >>> 16 & 0xff]) ^ s[0x200 | l >>> 8 & 0xff]) + s[0x300 | l & 0xff]) ^ p[i];
            l ^= (((s[r >>> 24] + s[0x100 | r >>> 16 & 0xff]) ^ s[0x200 | r >>> 8 & 0xff]) + s[0x300 | r & 0xff]) ^ p[i + 1];
        }
        lr[0] = r ^ p[17];
        lr[1] = l;
    }

    /** bcrypt's base64 (its own alphabet, no padding) of the first n bytes of d. */
    private static void encode(StringBuilder sb, byte[] d, int n) {
        int off = 0;
        while (off < n) {
            int c1 = d[off++] & 0xff;
            sb.append(B64.charAt(c1 >> 2));
            c1 = (c1 & 0x03) << 4;
            if (off >= n) {
                sb.append(B64.charAt(c1));
                break;
            }
            int c2 = d[off++] & 0xff;
            sb.append(B64.charAt(c1 | c2 >> 4));
            c1 = (c2 & 0x0f) << 2;
            if (off >= n) {
                sb.append(B64.charAt(c1));
                break;
            }
            c2 = d[off++] & 0xff;
            sb.append(B64.charAt(c1 | c2 >> 6));
            sb.append(B64.charAt(c2 & 0x3f));
        }
    }

    /** Decodes n bytes of bcrypt base64 from s starting at from. */
    private static byte[] decode(String s, int from, int n) {
        byte[] out = new byte[n];
        int o = 0, i = from;
        while (o < n) {
            int c1 = digit(s, i++), c2 = digit(s, i++);
            out[o++] = (byte) (c1 << 2 | (c2 & 0x30) >> 4);
            if (o >= n) break;
            int c3 = digit(s, i++);
            out[o++] = (byte) ((c2 & 0x0f) << 4 | (c3 & 0x3c) >> 2);
            if (o >= n) break;
            int c4 = digit(s, i++);
            out[o++] = (byte) ((c3 & 0x03) << 6 | c4);
        }
        return out;
    }

    private static int digit(String s, int i) {
        char c = i < s.length() ? s.charAt(i) : 0;
        int d = c < 128 ? B64_INDEX[c] : -1;
        if (d < 0) throw new IllegalArgumentException("bad bcrypt base64");
        return d;
    }
}
