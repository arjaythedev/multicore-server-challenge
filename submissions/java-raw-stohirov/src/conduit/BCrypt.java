package conduit;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;

/**
 * bcrypt ($2a$/$2b$/$2y$), cost 10 for new hashes. Blowfish's initial P-array and S-boxes are the fractional hex
 * digits of pi; they are computed once at class load (Machin's formula on BigInteger) instead of being pasted in.
 */
final class BCrypt {
    private static final int[] P_INIT = new int[18];
    private static final int[] S_INIT = new int[1024];
    private static final int[] CTEXT = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    private static final byte[] B64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
            .getBytes(StandardCharsets.US_ASCII);
    private static final byte[] UNB64 = new byte[128];
    private static final SecureRandom RNG = new SecureRandom();

    static {
        int words = 18 + 1024;
        int bits = words * 32;
        int guard = 64;
        BigInteger one = BigInteger.ONE.shiftLeft(bits + guard);
        BigInteger pi = atanInv(5, one).shiftLeft(4).subtract(atanInv(239, one).shiftLeft(2));
        BigInteger frac = pi.subtract(BigInteger.valueOf(3).shiftLeft(bits + guard)).shiftRight(guard);
        byte[] mag = frac.toByteArray(); // big-endian, may have a leading sign byte or be shorter
        byte[] w = new byte[words * 4];
        int copy = Math.min(mag.length, w.length);
        System.arraycopy(mag, mag.length - copy, w, w.length - copy, copy);
        for (int i = 0; i < words; i++) {
            int v = (w[4 * i] & 0xff) << 24 | (w[4 * i + 1] & 0xff) << 16 | (w[4 * i + 2] & 0xff) << 8 | (w[4 * i + 3] & 0xff);
            if (i < 18) P_INIT[i] = v;
            else S_INIT[i - 18] = v;
        }
        if (P_INIT[0] != 0x243f6a88 || P_INIT[17] != 0x8979fb1b || S_INIT[0] != 0xd1310ba6 || S_INIT[1023] != 0x3ac372e6)
            throw new IllegalStateException("bcrypt: pi digits are wrong");
        java.util.Arrays.fill(UNB64, (byte) -1);
        for (int i = 0; i < 64; i++) UNB64[B64[i]] = (byte) i;
    }

    /** atan(1/x) in fixed point with the given one. */
    private static BigInteger atanInv(int x, BigInteger one) {
        BigInteger x2 = BigInteger.valueOf((long) x * x);
        BigInteger term = one.divide(BigInteger.valueOf(x));
        BigInteger sum = term;
        for (int k = 1; ; k++) {
            term = term.divide(x2);
            BigInteger t = term.divide(BigInteger.valueOf(2L * k + 1));
            if (t.signum() == 0) return sum;
            sum = (k & 1) == 1 ? sum.subtract(t) : sum.add(t);
        }
    }

    /** A parsed "$2x$NN$" + 22-char salt prefix. */
    record Setting(String prefix, int cost, byte[] salt) {}

    static Setting parse(String setting) {
        if (setting == null || setting.length() < 29 || setting.charAt(0) != '$' || setting.charAt(1) != '2'
                || setting.charAt(3) != '$' || setting.charAt(6) != '$') return null;
        char minor = setting.charAt(2);
        if (minor != 'a' && minor != 'b' && minor != 'y') return null;
        int cost = (setting.charAt(4) - '0') * 10 + (setting.charAt(5) - '0');
        if (cost < 4 || cost > 31) return null;
        byte[] salt = decode(setting, 7, 16);
        return salt == null ? null : new Setting(setting.substring(0, 7), cost, salt);
    }

    static Setting newSetting() {
        byte[] salt = new byte[16];
        RNG.nextBytes(salt);
        return new Setting("$2a$10$", 10, salt);
    }

    /**
     * The hash strings of k passwords with their settings (all the same cost), up to BCryptLanes.MAX of them run in
     * lockstep: the same work as k single hashes, but the core overlaps their dependent S-box loads.
     */
    static String[] hashLanes(byte[][] passwords, Setting[] settings) {
        int k = passwords.length;
        String[] out = new String[k];
        for (int from = 0; from < k; from += BCryptLanes.MAX) {
            int n = Math.min(BCryptLanes.MAX, k - from);
            int[][] p = new int[n][], s = new int[n][], kw = new int[n][], sw = new int[n][], swk = new int[n][], c = new int[n][];
            for (int i = 0; i < n; i++) {
                byte[] key = keyBytes(passwords[from + i]);
                byte[] salt = settings[from + i].salt();
                p[i] = P_INIT.clone();
                s[i] = S_INIT.clone();
                kw[i] = words(key, 18);
                sw[i] = words(salt, 4);
                swk[i] = words(salt, 18);
                c[i] = CTEXT.clone();
            }
            int cost = settings[from].cost();
            BCryptLanes.expandSalted(n, p, s, kw, sw);
            for (int r = 1 << cost; r > 0; r--) {
                BCryptLanes.expand(n, p, s, kw);
                BCryptLanes.expand(n, p, s, swk);
            }
            BCryptLanes.encrypt(n, p, s, c);
            for (int i = 0; i < n; i++) {
                byte[] raw = new byte[24];
                for (int w = 0; w < 6; w++) {
                    raw[4 * w] = (byte) (c[i][w] >>> 24);
                    raw[4 * w + 1] = (byte) (c[i][w] >>> 16);
                    raw[4 * w + 2] = (byte) (c[i][w] >>> 8);
                    raw[4 * w + 3] = (byte) c[i][w];
                }
                StringBuilder sb = new StringBuilder(60).append(settings[from + i].prefix());
                encode(sb, settings[from + i].salt(), 16);
                encode(sb, raw, 23);
                out[from + i] = sb.toString();
            }
        }
        return out;
    }

    static boolean same(String a, String b) {
        return a != null && b != null && MessageDigest.isEqual(a.getBytes(StandardCharsets.US_ASCII), b.getBytes(StandardCharsets.US_ASCII));
    }

    /** count big-endian words of a cyclic byte stream. */
    private static int[] words(byte[] data, int count) {
        int[] out = new int[count];
        int j = 0;
        for (int i = 0; i < count; i++) {
            int w = 0;
            for (int k = 0; k < 4; k++) {
                w = w << 8 | (data[j] & 0xff);
                j = (j + 1) % data.length;
            }
            out[i] = w;
        }
        return out;
    }

    private static byte[] keyBytes(byte[] password) {
        int n = Math.min(password.length + 1, 72);
        byte[] k = new byte[n];
        System.arraycopy(password, 0, k, 0, Math.min(password.length, n));
        return k; // NUL-terminated (unless truncated at 72)
    }

    private static void encode(StringBuilder sb, byte[] d, int len) {
        int i = 0;
        while (i < len) {
            int c1 = d[i++] & 0xff;
            sb.append((char) B64[c1 >> 2]);
            c1 = (c1 & 3) << 4;
            if (i >= len) {
                sb.append((char) B64[c1]);
                return;
            }
            int c2 = d[i++] & 0xff;
            c1 |= c2 >> 4;
            sb.append((char) B64[c1]);
            c1 = (c2 & 0x0f) << 2;
            if (i >= len) {
                sb.append((char) B64[c1]);
                return;
            }
            c2 = d[i++] & 0xff;
            c1 |= c2 >> 6;
            sb.append((char) B64[c1]);
            sb.append((char) B64[c2 & 0x3f]);
        }
    }

    private static int d64(char c) {
        return c < 128 ? UNB64[c] : -1;
    }

    /** Decodes up to max bytes; null on a bad character. */
    private static byte[] decode(String s, int off, int max) {
        byte[] out = new byte[max];
        int o = 0, i = off, end = s.length();
        while (o < max && i + 1 < end) {
            int c1 = d64(s.charAt(i++)), c2 = d64(s.charAt(i++));
            if (c1 < 0 || c2 < 0) return null;
            out[o++] = (byte) (c1 << 2 | (c2 & 0x30) >> 4);
            if (o >= max || i >= end) break;
            int c3 = d64(s.charAt(i++));
            if (c3 < 0) return null;
            out[o++] = (byte) ((c2 & 0x0f) << 4 | (c3 & 0x3c) >> 2);
            if (o >= max || i >= end) break;
            int c4 = d64(s.charAt(i++));
            if (c4 < 0) return null;
            out[o++] = (byte) ((c3 & 0x03) << 6 | c4);
        }
        return o == max ? out : null;
    }

    /** A new cost-10 hash of a password. */
    static String hash(byte[] password) {
        return hashLanes(new byte[][] {password}, new Setting[] {newSetting()})[0];
    }

    /** Whether a password matches a stored hash. */
    static boolean verify(byte[] password, String stored) {
        Setting st = parse(stored);
        return st != null && same(hashLanes(new byte[][] {password}, new Setting[] {st})[0], stored);
    }
}
