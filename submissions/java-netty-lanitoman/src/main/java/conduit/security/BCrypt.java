package conduit.security;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;

/**
 * bcrypt ($2a$, $2b$, $2y$), following Provos and Mazieres: an expensive Blowfish key schedule ("EksBlowfishSetup")
 * that runs 2^cost rounds, then 64 encryptions of "OrpheanBeholderScryDoubt". Nearly all the time goes into the key
 * schedule: about a million Blowfish block encryptions at cost 10.
 *
 * <p>A Blowfish round is a chain of dependent table lookups, so a single hash leaves most of a CPU core's execution
 * units idle. {@link #compute} therefore runs several independent hashes interleaved in one thread (as password
 * crackers do): the CPU overlaps their lookups, and four hashes cost much less than four times one. Every hash still
 * does all of its 2^cost rounds. The inner loop runs in C when native/bcrypt_lanes.c was built (six lanes,
 * {@link NativeBcrypt}), else in Java (four lanes).
 */
public final class BCrypt {
    public static final int COST = 10;
    /** Hashes interleaved by the Java code (the JIT runs out of registers beyond four). */
    private static final int JAVA_LANES = 4;
    /** bcrypt uses at most 72 bytes of the password. */
    public static final int MAX_PASSWORD_BYTES = 72;

    private static final String ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    private static final int[] ALPHABET_INDEX = new int[128];
    /** "OrpheanBeholderScryDoubt" as six big-endian words. */
    private static final int[] MAGIC = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    private static final SecureRandom RANDOM = new SecureRandom();

    // Layout of a Blowfish state array: the P-array, then the four S-boxes.
    private static final int P = 0;
    private static final int S0 = 18, S1 = S0 + 256, S2 = S1 + 256, S3 = S2 + 256;
    private static final int STATE_WORDS = S3 + 256;

    static {
        java.util.Arrays.fill(ALPHABET_INDEX, -1);
        for (int i = 0; i < ALPHABET.length(); i++) ALPHABET_INDEX[ALPHABET.charAt(i)] = i;
    }

    private BCrypt() {
    }

    /** One hash to compute: the password and salt as Blowfish words in, the 23-byte result out. */
    public static final class Job {
        final int[] keyWords = new int[18];
        final int[] saltWords = new int[4];
        final byte[] salt;
        final int cost;
        final byte[] output = new byte[23];
        /** For verification: the result the stored hash says we should get. */
        private final byte[] expected;

        private Job(byte[] password, byte[] salt, int cost, byte[] expected) {
            this.salt = salt;
            this.cost = cost;
            this.expected = expected;
            // The key is the password's bytes and a terminating NUL, at most 72 bytes, repeated to fill 18 words.
            int keyLength = Math.min(password.length + 1, MAX_PASSWORD_BYTES);
            byte[] key = new byte[keyLength];
            System.arraycopy(password, 0, key, 0, Math.min(password.length, keyLength));
            int position = 0;
            for (int i = 0; i < 18; i++) {
                int word = 0;
                for (int j = 0; j < 4; j++) {
                    word = (word << 8) | (key[position] & 0xff);
                    position = (position + 1) % keyLength;
                }
                keyWords[i] = word;
            }
            for (int i = 0; i < 4; i++) {
                saltWords[i] = (salt[4 * i] & 0xff) << 24 | (salt[4 * i + 1] & 0xff) << 16
                        | (salt[4 * i + 2] & 0xff) << 8 | (salt[4 * i + 3] & 0xff);
            }
        }

        /** After compute(): the hash string to store, "$2b$10$" + 22 characters of salt + 31 of result. */
        public String hashString() {
            StringBuilder hash = new StringBuilder(60).append("$2b$").append(cost < 10 ? "0" : "").append(cost).append('$');
            encodeBase64(salt, hash);
            encodeBase64(output, hash);
            return hash.toString();
        }

        /** After compute(): whether the password matched the stored hash this job was made from. */
        public boolean matches() {
            return expected != null && MessageDigest.isEqual(output, expected);
        }
    }

    /** A job that hashes a new password with a fresh random salt at cost 10. */
    public static Job newHash(String password) {
        byte[] salt = new byte[16];
        RANDOM.nextBytes(salt);
        return new Job(password.getBytes(StandardCharsets.UTF_8), salt, COST, null);
    }

    /** A job that checks a password against a stored hash, or null when the stored hash isn't bcrypt. */
    public static Job verification(String password, String storedHash) {
        if (storedHash == null || storedHash.length() != 60 || storedHash.charAt(0) != '$' || storedHash.charAt(1) != '2'
                || "aby".indexOf(storedHash.charAt(2)) < 0 || storedHash.charAt(3) != '$' || storedHash.charAt(6) != '$') {
            return null;
        }
        int cost = (storedHash.charAt(4) - '0') * 10 + (storedHash.charAt(5) - '0');
        if (cost < 4 || cost > 31) return null;
        byte[] salt = decodeBase64(storedHash.substring(7, 29), 16);
        byte[] expected = decodeBase64(storedHash.substring(29), 23);
        if (salt == null || expected == null) return null;
        return new Job(password.getBytes(StandardCharsets.UTF_8), salt, cost, expected);
    }

    // ---------- computing ----------

    /** How many hashes {@link #compute} interleaves at most: a full batch for the password workers. */
    public static int lanes() {
        return NativeBcrypt.available() ? NativeBcrypt.LANES : JAVA_LANES;
    }

    /** Computes jobs[0..count), interleaving up to {@link #lanes()} of the same cost at a time. */
    public static void compute(Job[] jobs, int count) {
        boolean inC = NativeBcrypt.available();
        int maxLanes = inC ? NativeBcrypt.LANES : JAVA_LANES;
        int done = 0;
        while (done < count) {
            int lanes = 1;
            while (lanes < maxLanes && done + lanes < count && jobs[done + lanes].cost == jobs[done].cost) lanes++;
            if (inC) NativeBcrypt.compute(jobs, done, lanes);
            else computeInterleaved(jobs, done, lanes);
            done += lanes;
        }
    }

    /**
     * At startup: checks the Java implementation, then tries the C kernel and keeps it only if it gives exactly the
     * Java results. Returns which implementation is in use, for the startup log.
     */
    public static String start() {
        selfTest();
        String problem = NativeBcrypt.load(BlowfishTables.INITIAL_STATE);
        if (problem != null) return "Java (C kernel not used: " + problem + ")";
        if (!nativeMatchesJava()) {
            NativeBcrypt.disable();
            return "Java (C kernel disagreed with the Java implementation)";
        }
        selfTest();                                    // the known hash once more, now through the C kernel
        return "C, " + NativeBcrypt.LANES + " lanes";
    }

    /**
     * Every batch size the C kernel runs, each lane with its own password and random salt (at cost 4, to be quick),
     * against the Java implementation.
     */
    private static boolean nativeMatchesJava() {
        String[] passwords = {"password123", "a", "ünïcødé ✓", "x".repeat(71), "y".repeat(72), "z".repeat(100)};
        for (int count = 1; count <= NativeBcrypt.LANES; count++) {
            Job[] inC = new Job[count];
            Job[] inJava = new Job[count];
            for (int i = 0; i < count; i++) {
                byte[] password = passwords[i % passwords.length].getBytes(StandardCharsets.UTF_8);
                byte[] salt = new byte[16];
                RANDOM.nextBytes(salt);
                inC[i] = new Job(password, salt, 4, null);
                inJava[i] = new Job(password, salt, 4, null);
                computeInterleaved(inJava, i, 1);
            }
            NativeBcrypt.compute(inC, 0, count);
            for (int i = 0; i < count; i++) {
                if (!MessageDigest.isEqual(inC[i].output, inJava[i].output)) return false;
            }
        }
        return true;
    }

    public static void compute(Job job) {
        compute(new Job[] {job}, 1);
    }

    /*
     * The states of the hashes computed together sit in ONE array, lane k at offset k * STATE_WORDS (A, B, C, D).
     * The hot loop then needs a single base register instead of one per lane, which leaves the JIT enough registers
     * to keep all eight block halves in registers: about 15% faster than an array per lane.
     */
    private static final int A = 0, B = STATE_WORDS, C = 2 * STATE_WORDS, D = 3 * STATE_WORDS;

    private static void computeInterleaved(Job[] jobs, int first, int lanes) {
        // Three hashes run as four, the fourth a throwaway repeat of the third (its state is separate and its result
        // is never written): the four-lane code is the fast one.
        int width = lanes == 1 ? 1 : lanes == 2 ? 2 : 4;
        int[] states = new int[width * STATE_WORDS];
        Job[] lane = new Job[width];
        for (int i = 0; i < width; i++) {
            lane[i] = jobs[first + Math.min(i, lanes - 1)];
            initialState(states, i * STATE_WORDS, lane[i]);
        }
        long rounds = 1L << lane[0].cost;
        for (long round = 0; round < rounds; round++) {
            for (int i = 0; i < width; i++) xorKey(states, i * STATE_WORDS, lane[i].keyWords);
            rekey(states, width);
            for (int i = 0; i < width; i++) xorSalt(states, i * STATE_WORDS, lane[i].saltWords);
            rekey(states, width);
        }
        for (int i = 0; i < lanes; i++) finish(states, i * STATE_WORDS, lane[i].output);
    }

    private static void rekey(int[] states, int width) {
        switch (width) {
            case 1 -> rekey1(states);
            case 2 -> rekey2(states);
            default -> rekey4(states);
        }
    }

    /**
     * The state at {@code at}: the initial state from pi, then ExpandKey(state, salt, key), in which the salt
     * (repeated) is the data stream.
     */
    private static void initialState(int[] s, int at, Job job) {
        System.arraycopy(BlowfishTables.INITIAL_STATE, 0, s, at, STATE_WORDS);
        xorKey(s, at, job.keyWords);
        int left = 0, right = 0;
        for (int i = 0; i < STATE_WORDS; i += 2) {
            left ^= job.saltWords[i % 4];
            right ^= job.saltWords[(i + 1) % 4];
            long block = encrypt(s, at, left, right);
            left = (int) (block >>> 32);
            right = (int) block;
            s[at + i] = left;
            s[at + i + 1] = right;
        }
    }

    private static void xorKey(int[] s, int at, int[] keyWords) {
        for (int i = 0; i < 18; i++) s[at + P + i] ^= keyWords[i];
    }

    /** ExpandKey(state, 0, salt): the 16-byte salt, repeated, as the key. */
    private static void xorSalt(int[] s, int at, int[] saltWords) {
        for (int i = 0; i < 18; i++) s[at + P + i] ^= saltWords[i % 4];
    }

    /** Encrypts "OrpheanBeholderScryDoubt" 64 times; the first 23 bytes of the result are the hash. */
    private static void finish(int[] s, int at, byte[] output) {
        int[] text = MAGIC.clone();
        for (int i = 0; i < 64; i++) {
            for (int j = 0; j < 6; j += 2) {
                long block = encrypt(s, at, text[j], text[j + 1]);
                text[j] = (int) (block >>> 32);
                text[j + 1] = (int) block;
            }
        }
        for (int i = 0; i < 23; i++) output[i] = (byte) (text[i / 4] >>> (24 - 8 * (i % 4)));
    }

    // ---------- Blowfish ----------

    /** Blowfish's round function on the state at {@code at}: four S-box lookups mixed with addition and xor. */
    private static int f(int[] s, int at, int x) {
        return ((s[at + S0 + (x >>> 24)] + s[at + S1 + ((x >>> 16) & 0xff)]) ^ s[at + S2 + ((x >>> 8) & 0xff)])
                + s[at + S3 + (x & 0xff)];
    }

    /** One block with the state at {@code at}: 16 rounds. Returns (left << 32 | right). */
    private static long encrypt(int[] s, int at, int left, int right) {
        left ^= s[at + P];
        for (int i = 1; i <= 16; i += 2) {
            right ^= f(s, at, left) ^ s[at + P + i];
            left ^= f(s, at, right) ^ s[at + P + i + 1];
        }
        right ^= s[at + P + 17];
        return ((long) right << 32) | (left & 0xffffffffL);
    }

    /**
     * Re-derives the state of lane A from itself: starting from a zero block, each encryption's output replaces the
     * next two words of the P-array and then of the S-boxes (521 encryptions).
     */
    private static void rekey1(int[] s) {
        int la = 0, ra = 0;
        for (int i = 0; i < STATE_WORDS; i += 2) {
            la ^= s[A + P];
            for (int r = 1; r <= 16; r += 2) {
                ra ^= f(s, A, la) ^ s[A + P + r];
                la ^= f(s, A, ra) ^ s[A + P + r + 1];
            }
            int t = la;
            la = ra ^ s[A + P + 17];
            ra = t;
            s[A + i] = la;
            s[A + i + 1] = ra;
        }
    }

    /** rekey1 for lanes A and B at once, their rounds interleaved. */
    private static void rekey2(int[] s) {
        int la = 0, ra = 0, lb = 0, rb = 0;
        for (int i = 0; i < STATE_WORDS; i += 2) {
            la ^= s[A + P];
            lb ^= s[B + P];
            for (int r = 1; r <= 16; r += 2) {
                ra ^= f(s, A, la) ^ s[A + P + r];
                rb ^= f(s, B, lb) ^ s[B + P + r];
                la ^= f(s, A, ra) ^ s[A + P + r + 1];
                lb ^= f(s, B, rb) ^ s[B + P + r + 1];
            }
            int ta = la, tb = lb;
            la = ra ^ s[A + P + 17];
            lb = rb ^ s[B + P + 17];
            ra = ta;
            rb = tb;
            s[A + i] = la;
            s[A + i + 1] = ra;
            s[B + i] = lb;
            s[B + i + 1] = rb;
        }
    }

    /** rekey1 for lanes A, B, C and D at once, their rounds interleaved. */
    private static void rekey4(int[] s) {
        int la = 0, ra = 0, lb = 0, rb = 0, lc = 0, rc = 0, ld = 0, rd = 0;
        for (int i = 0; i < STATE_WORDS; i += 2) {
            la ^= s[A + P];
            lb ^= s[B + P];
            lc ^= s[C + P];
            ld ^= s[D + P];
            for (int r = 1; r <= 16; r += 2) {
                ra ^= f(s, A, la) ^ s[A + P + r];
                rb ^= f(s, B, lb) ^ s[B + P + r];
                rc ^= f(s, C, lc) ^ s[C + P + r];
                rd ^= f(s, D, ld) ^ s[D + P + r];
                la ^= f(s, A, ra) ^ s[A + P + r + 1];
                lb ^= f(s, B, rb) ^ s[B + P + r + 1];
                lc ^= f(s, C, rc) ^ s[C + P + r + 1];
                ld ^= f(s, D, rd) ^ s[D + P + r + 1];
            }
            int ta = la, tb = lb, tc = lc, td = ld;
            la = ra ^ s[A + P + 17];
            lb = rb ^ s[B + P + 17];
            lc = rc ^ s[C + P + 17];
            ld = rd ^ s[D + P + 17];
            ra = ta;
            rb = tb;
            rc = tc;
            rd = td;
            s[A + i] = la;
            s[A + i + 1] = ra;
            s[B + i] = lb;
            s[B + i + 1] = rb;
            s[C + i] = lc;
            s[C + i + 1] = rc;
            s[D + i] = ld;
            s[D + i + 1] = rd;
        }
    }

    // ---------- bcrypt's base64 (its own alphabet, no padding) ----------

    private static void encodeBase64(byte[] data, StringBuilder out) {
        int i = 0;
        while (i < data.length) {
            int c1 = data[i++] & 0xff;
            out.append(ALPHABET.charAt(c1 >>> 2));
            c1 = (c1 & 0x03) << 4;
            if (i >= data.length) {
                out.append(ALPHABET.charAt(c1));
                return;
            }
            int c2 = data[i++] & 0xff;
            out.append(ALPHABET.charAt(c1 | (c2 >>> 4)));
            c1 = (c2 & 0x0f) << 2;
            if (i >= data.length) {
                out.append(ALPHABET.charAt(c1));
                return;
            }
            c2 = data[i++] & 0xff;
            out.append(ALPHABET.charAt(c1 | (c2 >>> 6)));
            out.append(ALPHABET.charAt(c2 & 0x3f));
        }
    }

    /** Decodes exactly {@code length} bytes, or returns null on a character outside the alphabet. */
    private static byte[] decodeBase64(String text, int length) {
        byte[] out = new byte[length];
        int position = 0;
        int produced = 0;
        while (produced < length && position + 1 < text.length()) {
            int c1 = index(text.charAt(position++));
            int c2 = index(text.charAt(position++));
            if (c1 < 0 || c2 < 0) return null;
            out[produced++] = (byte) ((c1 << 2) | ((c2 & 0x30) >> 4));
            if (produced >= length || position >= text.length()) break;
            int c3 = index(text.charAt(position++));
            if (c3 < 0) return null;
            out[produced++] = (byte) (((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2));
            if (produced >= length || position >= text.length()) break;
            int c4 = index(text.charAt(position++));
            if (c4 < 0) return null;
            out[produced++] = (byte) (((c3 & 0x03) << 6) | c4);
        }
        return produced == length ? out : null;
    }

    private static int index(char c) {
        return c < 128 ? ALPHABET_INDEX[c] : -1;
    }

    // ---------- startup self-test ----------

    /** Checks the implementation (one lane and interleaved) against a hash made by another bcrypt implementation. */
    public static void selfTest() {
        String knownHash = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";   // "password123"
        Job single = verification("password123", knownHash);
        compute(single);
        Job[] four = new Job[4];
        for (int i = 0; i < 4; i++) four[i] = verification(i == 2 ? "wrong" : "password123", knownHash);
        compute(four, 4);
        Job[] three = new Job[3];
        for (int i = 0; i < 3; i++) three[i] = verification(i == 1 ? "wrong" : "password123", knownHash);
        compute(three, 3);
        Job roundTrip = newHash("conduit");
        compute(roundTrip);
        Job check = verification("conduit", roundTrip.hashString());
        compute(check);
        boolean ok = single.matches() && four[0].matches() && four[1].matches() && !four[2].matches() && four[3].matches()
                && three[0].matches() && !three[1].matches() && three[2].matches() && check.matches();
        if (!ok) throw new IllegalStateException("bcrypt self-test failed");
    }
}
