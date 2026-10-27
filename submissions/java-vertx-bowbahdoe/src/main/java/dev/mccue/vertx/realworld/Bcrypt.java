package dev.mccue.vertx.realworld;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;

/// OpenBSD bcrypt ($2a$, $2b$, $2y$), four hashes at a time.
///
/// Nearly all of bcrypt's time is Blowfish encryptions, and each round of one is a chain of dependent S-box loads:
/// a single hash keeps a core waiting on its L1 cache. Four independent hashes advanced in the same loop give the
/// core four chains to overlap, so four hashes take little longer than one. Every lane still does every round.
final class Bcrypt {
    static final int LANES = 4;

    // S-boxes at 0, 256, 512 and 768; the P-array after them.
    private static final int P = 1024;
    private static final int STATE = P + 18;
    private static final int[] INITIAL = new int[STATE];
    static {
        System.arraycopy(BlowfishTables.S0, 0, INITIAL, 0, 256);
        System.arraycopy(BlowfishTables.S1, 0, INITIAL, 256, 256);
        System.arraycopy(BlowfishTables.S2, 0, INITIAL, 512, 256);
        System.arraycopy(BlowfishTables.S3, 0, INITIAL, 768, 256);
        System.arraycopy(BlowfishTables.P, 0, INITIAL, P, 18);
    }

    // "OrpheanBeholderScryDoubt"
    private static final int[] MAGIC = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};

    private static final char[] ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".toCharArray();
    private static final byte[] INDEX = new byte[128];
    static {
        Arrays.fill(INDEX, (byte) -1);
        for (int i = 0; i < ALPHABET.length; i++) {
            INDEX[ALPHABET[i]] = (byte) i;
        }
    }

    /// One hash to compute: a password's key bytes (UTF-8, NUL-terminated, at most 72 bytes), a 16-byte salt.
    record Job(byte[] key, byte[] salt, int cost) {
    }

    private Bcrypt() {
    }

    static byte[] key(String password) {
        var utf8 = password.getBytes(StandardCharsets.UTF_8);
        return Arrays.copyOf(utf8, Math.min(utf8.length + 1, 72));
    }

    /// "$2a$10$" + salt + hash.
    static String encode(String version, int cost, byte[] salt, byte[] hash) {
        var out = new StringBuilder(60).append('$').append(version).append('$');
        if (cost < 10) {
            out.append('0');
        }
        out.append(cost).append('$');
        base64(salt, 16, out);
        base64(hash, 23, out);
        return out.toString();
    }

    /// The job that checks a password against a stored hash, or null if the hash isn't a bcrypt hash.
    static Job checkJob(String password, String hash) {
        if (hash.length() != 60 || hash.charAt(0) != '$' || hash.charAt(1) != '2' || hash.charAt(3) != '$' || hash.charAt(6) != '$') {
            return null;
        }
        char version = hash.charAt(2);
        if (version != 'a' && version != 'b' && version != 'y') {
            return null;
        }
        int cost = (hash.charAt(4) - '0') * 10 + (hash.charAt(5) - '0');
        if (cost < 4 || cost > 31) {
            return null;
        }
        var salt = unbase64(hash, 7, 16);
        if (salt == null) {
            return null;
        }
        return new Job(key(password), salt, cost);
    }

    /// Whether the computed hash is the stored one, in constant time.
    static boolean sameHash(String stored, byte[] computed) {
        var expected = new StringBuilder(31);
        base64(computed, 23, expected);
        return MessageDigest.isEqual(
                stored.substring(29).getBytes(StandardCharsets.US_ASCII),
                expected.toString().getBytes(StandardCharsets.US_ASCII));
    }

    /// Computes up to four jobs of the same cost; the result for job i is element i (23 bytes).
    static byte[][] compute(Job[] jobs, int count) {
        if (count < 1 || count > LANES) {
            throw new IllegalArgumentException("count");
        }
        // Lanes without a job repeat the first; the work is the same either way.
        var lanes = new Job[LANES];
        for (int i = 0; i < LANES; i++) {
            lanes[i] = jobs[i < count ? i : 0];
            if (lanes[i].cost() != jobs[0].cost()) {
                throw new IllegalArgumentException("mixed costs");
            }
        }
        int[] s0 = INITIAL.clone(), s1 = INITIAL.clone(), s2 = INITIAL.clone(), s3 = INITIAL.clone();
        int[] k0 = words(lanes[0].key()), k1 = words(lanes[1].key()), k2 = words(lanes[2].key()), k3 = words(lanes[3].key());
        int[] t0 = words(lanes[0].salt()), t1 = words(lanes[1].salt()), t2 = words(lanes[2].salt()), t3 = words(lanes[3].salt());

        expand(s0, s1, s2, s3, k0, k1, k2, k3, t0, t1, t2, t3);
        for (long round = 1L << jobs[0].cost(); round > 0; round--) {
            expand(s0, s1, s2, s3, k0, k1, k2, k3, null, null, null, null);
            expand(s0, s1, s2, s3, t0, t1, t2, t3, null, null, null, null);
        }

        var results = new byte[count][];
        int[][] states = {s0, s1, s2, s3};
        for (int lane = 0; lane < count; lane++) {
            var s = states[lane];
            var text = MAGIC.clone();
            for (int i = 0; i < 64; i++) {
                for (int j = 0; j < 6; j += 2) {
                    long block = encipher(s, text[j], text[j + 1]);
                    text[j] = (int) (block >>> 32);
                    text[j + 1] = (int) block;
                }
            }
            var out = new byte[23];
            for (int i = 0; i < 23; i++) {
                out[i] = (byte) (text[i >> 2] >>> (24 - 8 * (i & 3)));
            }
            results[lane] = out;
        }
        return results;
    }

    /// 18 key words for the P-array, cycling through the key's bytes (big-endian).
    private static int[] words(byte[] bytes) {
        var words = new int[18];
        int j = 0;
        for (int i = 0; i < 18; i++) {
            int word = 0;
            for (int b = 0; b < 4; b++) {
                word = (word << 8) | (bytes[j] & 0xff);
                j = j + 1 == bytes.length ? 0 : j + 1;
            }
            words[i] = word;
        }
        return words;
    }

    private static int f(int[] s, int x) {
        return ((s[x >>> 24] + s[256 | (x >>> 16 & 0xff)]) ^ s[512 | (x >>> 8 & 0xff)]) + s[768 | (x & 0xff)];
    }

    private static long encipher(int[] s, int l, int r) {
        l ^= s[P];
        for (int i = 1; i < 17; i += 2) {
            r ^= f(s, l) ^ s[P + i];
            l ^= f(s, r) ^ s[P + i + 1];
        }
        r ^= s[P + 17];
        return ((long) r << 32) | (l & 0xffffffffL);
    }

    /// Blowfish key expansion of four states at once: the P-array takes the key words, then every P and S entry is
    /// replaced, in order, by successive encryptions, each of the previous block XOR the salt stream (if any).
    private static void expand(int[] s0, int[] s1, int[] s2, int[] s3,
                               int[] k0, int[] k1, int[] k2, int[] k3,
                               int[] d0, int[] d1, int[] d2, int[] d3) {
        for (int i = 0; i < 18; i++) {
            s0[P + i] ^= k0[i];
            s1[P + i] ^= k1[i];
            s2[P + i] ^= k2[i];
            s3[P + i] ^= k3[i];
        }
        int l0 = 0, r0 = 0, l1 = 0, r1 = 0, l2 = 0, r2 = 0, l3 = 0, r3 = 0;
        boolean salted = d0 != null;
        // 521 blocks: 9 for the P-array, then 512 for the S-boxes. The salt stream (4 words) runs on across both.
        for (int block = 0; block < 521; block++) {
            int at = block < 9 ? P + 2 * block : 2 * (block - 9);
            if (salted) {
                int w = (2 * block) & 3;
                l0 ^= d0[w]; r0 ^= d0[w + 1];
                l1 ^= d1[w]; r1 ^= d1[w + 1];
                l2 ^= d2[w]; r2 ^= d2[w + 1];
                l3 ^= d3[w]; r3 ^= d3[w + 1];
            }
            l0 ^= s0[P]; l1 ^= s1[P]; l2 ^= s2[P]; l3 ^= s3[P];
            for (int i = 1; i < 17; i += 2) {
                r0 ^= f(s0, l0) ^ s0[P + i];
                r1 ^= f(s1, l1) ^ s1[P + i];
                r2 ^= f(s2, l2) ^ s2[P + i];
                r3 ^= f(s3, l3) ^ s3[P + i];
                l0 ^= f(s0, r0) ^ s0[P + i + 1];
                l1 ^= f(s1, r1) ^ s1[P + i + 1];
                l2 ^= f(s2, r2) ^ s2[P + i + 1];
                l3 ^= f(s3, r3) ^ s3[P + i + 1];
            }
            r0 ^= s0[P + 17]; r1 ^= s1[P + 17]; r2 ^= s2[P + 17]; r3 ^= s3[P + 17];
            // the output block is (r, l): swap for the next one
            int t;
            t = l0; l0 = r0; r0 = t;
            t = l1; l1 = r1; r1 = t;
            t = l2; l2 = r2; r2 = t;
            t = l3; l3 = r3; r3 = t;
            s0[at] = l0; s0[at + 1] = r0;
            s1[at] = l1; s1[at + 1] = r1;
            s2[at] = l2; s2[at + 1] = r2;
            s3[at] = l3; s3[at + 1] = r3;
        }
    }

    private static void base64(byte[] data, int length, StringBuilder out) {
        int i = 0;
        while (i < length) {
            int c1 = data[i++] & 0xff;
            out.append(ALPHABET[c1 >>> 2]);
            c1 = (c1 & 0x03) << 4;
            if (i >= length) {
                out.append(ALPHABET[c1]);
                break;
            }
            int c2 = data[i++] & 0xff;
            out.append(ALPHABET[c1 | (c2 >>> 4)]);
            c1 = (c2 & 0x0f) << 2;
            if (i >= length) {
                out.append(ALPHABET[c1]);
                break;
            }
            c2 = data[i++] & 0xff;
            out.append(ALPHABET[c1 | (c2 >>> 6)]);
            out.append(ALPHABET[c2 & 0x3f]);
        }
    }

    /// Decodes `length` bytes starting at `offset`, or null on a character outside the alphabet.
    private static byte[] unbase64(String text, int offset, int length) {
        var out = new byte[length];
        int o = 0;
        int i = offset;
        while (o < length) {
            int c1 = digit(text, i++), c2 = digit(text, i++);
            if (c1 < 0 || c2 < 0) {
                return null;
            }
            out[o++] = (byte) ((c1 << 2) | (c2 >>> 4));
            if (o >= length) {
                break;
            }
            int c3 = digit(text, i++);
            if (c3 < 0) {
                return null;
            }
            out[o++] = (byte) (((c2 & 0x0f) << 4) | (c3 >>> 2));
            if (o >= length) {
                break;
            }
            int c4 = digit(text, i++);
            if (c4 < 0) {
                return null;
            }
            out[o++] = (byte) (((c3 & 0x03) << 6) | c4);
        }
        return out;
    }

    private static int digit(String text, int i) {
        char c = text.charAt(i);
        return c < 128 ? INDEX[c] : -1;
    }
}
