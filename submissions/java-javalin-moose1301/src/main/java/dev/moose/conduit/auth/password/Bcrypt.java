package dev.moose.conduit.auth.password;

import jdk.internal.misc.Unsafe;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.Arrays;

public class Bcrypt {

    public static final int LANES = 4;
    public static final int COST = 10;

    private static final int P_OFFSET = 1024;
    private static final int STATE_SIZE = P_OFFSET + 18;
    private static final long STATE_BYTES = 4L * STATE_SIZE;
    private static final long P_BYTES = 4L * P_OFFSET;
    private static final Unsafe UNSAFE = Unsafe.getUnsafe();
    private static final int[] INITIAL_STATE = blowfishInitialState();
    private static final int[] MAGIC = {0x4f727068, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274};
    private static final char[] ALPHABET = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".toCharArray();
    private static final byte[] ALPHABET_INDEX = new byte[128];

    static {
        Arrays.fill(ALPHABET_INDEX, (byte) -1);
        for (int i = 0; i < ALPHABET.length; i++) {
            ALPHABET_INDEX[ALPHABET[i]] = (byte) i;
        }
    }

    public record Job(int[] keyWords, int[] saltWords, byte[] salt, int cost) {
    }

    private Bcrypt() {
    }

    public static boolean tooLong(String password) {
        return password.getBytes(StandardCharsets.UTF_8).length > 72;
    }

    public static Job hashJob(String password, byte[] salt) {
        return new Job(keyWords(password), cyclicWords(salt), salt, COST);
    }

    public static Job checkJob(String password, String storedHash) {
        if (storedHash.length() != 60 || storedHash.charAt(0) != '$' || storedHash.charAt(1) != '2'
                || storedHash.charAt(3) != '$' || storedHash.charAt(6) != '$') {
            return null;
        }
        final char version = storedHash.charAt(2);
        if (version != 'a' && version != 'b' && version != 'y') {
            return null;
        }
        final int cost = (storedHash.charAt(4) - '0') * 10 + (storedHash.charAt(5) - '0');
        if (cost < 4 || cost > 31) {
            return null;
        }
        final byte[] salt = decode(storedHash, 7, 16);
        if (salt == null) {
            return null;
        }
        return new Job(keyWords(password), cyclicWords(salt), salt, cost);
    }

    public static String encode(byte[] salt, byte[] hash) {
        final StringBuilder builder = new StringBuilder(60).append("$2a$").append(COST).append('$');
        encode(salt, 16, builder);
        encode(hash, 23, builder);
        return builder.toString();
    }

    public static boolean matches(String storedHash, byte[] computed) {
        final StringBuilder expected = new StringBuilder(31);
        encode(computed, 23, expected);
        return MessageDigest.isEqual(
                storedHash.substring(29).getBytes(StandardCharsets.US_ASCII),
                expected.toString().getBytes(StandardCharsets.US_ASCII));
    }

    public static byte[][] compute(Job[] jobs, int count) {
        final int lanes = count == 1 ? 1 : count == 2 ? 2 : LANES;
        final Job[] laneJobs = new Job[lanes];
        for (int lane = 0; lane < lanes; lane++) {
            laneJobs[lane] = jobs[lane < count ? lane : 0];
        }
        final long memory = UNSAFE.allocateMemory(STATE_BYTES * lanes);
        try {
            for (int lane = 0; lane < lanes; lane++) {
                for (int i = 0; i < STATE_SIZE; i++) {
                    UNSAFE.putInt(memory + lane * STATE_BYTES + 4L * i, INITIAL_STATE[i]);
                }
            }
            switch (lanes) {
                case 1 -> run1(memory, laneJobs);
                case 2 -> run2(memory, laneJobs);
                default -> run4(memory, laneJobs);
            }
            final byte[][] results = new byte[count][];
            for (int lane = 0; lane < count; lane++) {
                final int[] state = new int[STATE_SIZE];
                for (int i = 0; i < STATE_SIZE; i++) {
                    state[i] = UNSAFE.getInt(memory + lane * STATE_BYTES + 4L * i);
                }
                results[lane] = finish(state);
            }
            return results;
        } finally {
            UNSAFE.freeMemory(memory);
        }
    }

    private static void run1(long memory, Job[] jobs) {
        expand1(memory + 0 * STATE_BYTES,
                        jobs[0].keyWords,
                        jobs[0].saltWords);
        for (long round = 1L << jobs[0].cost; round > 0; round--) {
            expand1(memory + 0 * STATE_BYTES,
                    jobs[0].keyWords,
                    null);
            expand1(memory + 0 * STATE_BYTES,
                    jobs[0].saltWords,
                    null);
        }
    }

    private static void run2(long memory, Job[] jobs) {
        expand2(memory + 0 * STATE_BYTES, memory + 1 * STATE_BYTES,
                        jobs[0].keyWords, jobs[1].keyWords,
                        jobs[0].saltWords, jobs[1].saltWords);
        for (long round = 1L << jobs[0].cost; round > 0; round--) {
            expand2(memory + 0 * STATE_BYTES, memory + 1 * STATE_BYTES,
                    jobs[0].keyWords, jobs[1].keyWords,
                    null, null);
            expand2(memory + 0 * STATE_BYTES, memory + 1 * STATE_BYTES,
                    jobs[0].saltWords, jobs[1].saltWords,
                    null, null);
        }
    }

    private static void run4(long memory, Job[] jobs) {
        expand4(memory + 0 * STATE_BYTES, memory + 1 * STATE_BYTES, memory + 2 * STATE_BYTES, memory + 3 * STATE_BYTES,
                        jobs[0].keyWords, jobs[1].keyWords, jobs[2].keyWords, jobs[3].keyWords,
                        jobs[0].saltWords, jobs[1].saltWords, jobs[2].saltWords, jobs[3].saltWords);
        for (long round = 1L << jobs[0].cost; round > 0; round--) {
            expand4(memory + 0 * STATE_BYTES, memory + 1 * STATE_BYTES, memory + 2 * STATE_BYTES, memory + 3 * STATE_BYTES,
                    jobs[0].keyWords, jobs[1].keyWords, jobs[2].keyWords, jobs[3].keyWords,
                    null, null, null, null);
            expand4(memory + 0 * STATE_BYTES, memory + 1 * STATE_BYTES, memory + 2 * STATE_BYTES, memory + 3 * STATE_BYTES,
                    jobs[0].saltWords, jobs[1].saltWords, jobs[2].saltWords, jobs[3].saltWords,
                    null, null, null, null);
        }
    }

    private static void expand1(long state0,
                                int[] key0,
                                int[] salt0) {
        for (int i = 0; i < 18; i++) {
            final long word = P_BYTES + 4L * i;
            UNSAFE.putInt(state0 + word, UNSAFE.getInt(state0 + word) ^ key0[i]);
        }
        int left0 = 0;
        int right0 = 0;
        final boolean salted = salt0 != null;
        for (int block = 0; block < 521; block++) {
            if (salted) {
                final int saltIndex = (block & 1) << 1;
                left0 ^= salt0[saltIndex];
                right0 ^= salt0[saltIndex + 1];
            }
            left0 ^= UNSAFE.getInt(state0 + P_BYTES);
            for (long round = P_BYTES + 4; round < P_BYTES + 68; round += 8) {
                right0 ^= feistel(state0, left0) ^ UNSAFE.getInt(state0 + round);
                left0 ^= feistel(state0, right0) ^ UNSAFE.getInt(state0 + round + 4);
            }
            right0 ^= UNSAFE.getInt(state0 + P_BYTES + 68);
            final long target = block < 9 ? P_BYTES + 8L * block : 8L * (block - 9);
            UNSAFE.putInt(state0 + target, right0);
            UNSAFE.putInt(state0 + target + 4, left0);
            final int swapped0 = left0;
            left0 = right0;
            right0 = swapped0;
        }
    }

    private static void expand2(long state0, long state1,
                                int[] key0, int[] key1,
                                int[] salt0, int[] salt1) {
        for (int i = 0; i < 18; i++) {
            final long word = P_BYTES + 4L * i;
            UNSAFE.putInt(state0 + word, UNSAFE.getInt(state0 + word) ^ key0[i]);
            UNSAFE.putInt(state1 + word, UNSAFE.getInt(state1 + word) ^ key1[i]);
        }
        int left0 = 0;
        int right0 = 0;
        int left1 = 0;
        int right1 = 0;
        final boolean salted = salt0 != null;
        for (int block = 0; block < 521; block++) {
            if (salted) {
                final int saltIndex = (block & 1) << 1;
                left0 ^= salt0[saltIndex];
                right0 ^= salt0[saltIndex + 1];
                left1 ^= salt1[saltIndex];
                right1 ^= salt1[saltIndex + 1];
            }
            left0 ^= UNSAFE.getInt(state0 + P_BYTES);
            left1 ^= UNSAFE.getInt(state1 + P_BYTES);
            for (long round = P_BYTES + 4; round < P_BYTES + 68; round += 8) {
                right0 ^= feistel(state0, left0) ^ UNSAFE.getInt(state0 + round);
                right1 ^= feistel(state1, left1) ^ UNSAFE.getInt(state1 + round);
                left0 ^= feistel(state0, right0) ^ UNSAFE.getInt(state0 + round + 4);
                left1 ^= feistel(state1, right1) ^ UNSAFE.getInt(state1 + round + 4);
            }
            right0 ^= UNSAFE.getInt(state0 + P_BYTES + 68);
            right1 ^= UNSAFE.getInt(state1 + P_BYTES + 68);
            final long target = block < 9 ? P_BYTES + 8L * block : 8L * (block - 9);
            UNSAFE.putInt(state0 + target, right0);
            UNSAFE.putInt(state0 + target + 4, left0);
            final int swapped0 = left0;
            left0 = right0;
            right0 = swapped0;
            UNSAFE.putInt(state1 + target, right1);
            UNSAFE.putInt(state1 + target + 4, left1);
            final int swapped1 = left1;
            left1 = right1;
            right1 = swapped1;
        }
    }

    private static void expand4(long state0, long state1, long state2, long state3,
                                int[] key0, int[] key1, int[] key2, int[] key3,
                                int[] salt0, int[] salt1, int[] salt2, int[] salt3) {
        for (int i = 0; i < 18; i++) {
            final long word = P_BYTES + 4L * i;
            UNSAFE.putInt(state0 + word, UNSAFE.getInt(state0 + word) ^ key0[i]);
            UNSAFE.putInt(state1 + word, UNSAFE.getInt(state1 + word) ^ key1[i]);
            UNSAFE.putInt(state2 + word, UNSAFE.getInt(state2 + word) ^ key2[i]);
            UNSAFE.putInt(state3 + word, UNSAFE.getInt(state3 + word) ^ key3[i]);
        }
        int left0 = 0;
        int right0 = 0;
        int left1 = 0;
        int right1 = 0;
        int left2 = 0;
        int right2 = 0;
        int left3 = 0;
        int right3 = 0;
        final boolean salted = salt0 != null;
        for (int block = 0; block < 521; block++) {
            if (salted) {
                final int saltIndex = (block & 1) << 1;
                left0 ^= salt0[saltIndex];
                right0 ^= salt0[saltIndex + 1];
                left1 ^= salt1[saltIndex];
                right1 ^= salt1[saltIndex + 1];
                left2 ^= salt2[saltIndex];
                right2 ^= salt2[saltIndex + 1];
                left3 ^= salt3[saltIndex];
                right3 ^= salt3[saltIndex + 1];
            }
            left0 ^= UNSAFE.getInt(state0 + P_BYTES);
            left1 ^= UNSAFE.getInt(state1 + P_BYTES);
            left2 ^= UNSAFE.getInt(state2 + P_BYTES);
            left3 ^= UNSAFE.getInt(state3 + P_BYTES);
            for (long round = P_BYTES + 4; round < P_BYTES + 68; round += 8) {
                right0 ^= feistel(state0, left0) ^ UNSAFE.getInt(state0 + round);
                right1 ^= feistel(state1, left1) ^ UNSAFE.getInt(state1 + round);
                right2 ^= feistel(state2, left2) ^ UNSAFE.getInt(state2 + round);
                right3 ^= feistel(state3, left3) ^ UNSAFE.getInt(state3 + round);
                left0 ^= feistel(state0, right0) ^ UNSAFE.getInt(state0 + round + 4);
                left1 ^= feistel(state1, right1) ^ UNSAFE.getInt(state1 + round + 4);
                left2 ^= feistel(state2, right2) ^ UNSAFE.getInt(state2 + round + 4);
                left3 ^= feistel(state3, right3) ^ UNSAFE.getInt(state3 + round + 4);
            }
            right0 ^= UNSAFE.getInt(state0 + P_BYTES + 68);
            right1 ^= UNSAFE.getInt(state1 + P_BYTES + 68);
            right2 ^= UNSAFE.getInt(state2 + P_BYTES + 68);
            right3 ^= UNSAFE.getInt(state3 + P_BYTES + 68);
            final long target = block < 9 ? P_BYTES + 8L * block : 8L * (block - 9);
            UNSAFE.putInt(state0 + target, right0);
            UNSAFE.putInt(state0 + target + 4, left0);
            final int swapped0 = left0;
            left0 = right0;
            right0 = swapped0;
            UNSAFE.putInt(state1 + target, right1);
            UNSAFE.putInt(state1 + target + 4, left1);
            final int swapped1 = left1;
            left1 = right1;
            right1 = swapped1;
            UNSAFE.putInt(state2 + target, right2);
            UNSAFE.putInt(state2 + target + 4, left2);
            final int swapped2 = left2;
            left2 = right2;
            right2 = swapped2;
            UNSAFE.putInt(state3 + target, right3);
            UNSAFE.putInt(state3 + target + 4, left3);
            final int swapped3 = left3;
            left3 = right3;
            right3 = swapped3;
        }
    }

    private static int feistel(long state, int value) {
        return ((UNSAFE.getInt(state + ((value >>> 24) << 2))
                + UNSAFE.getInt(state + 1024 + (((value >>> 16) & 0xff) << 2)))
                ^ UNSAFE.getInt(state + 2048 + (((value >>> 8) & 0xff) << 2)))
                + UNSAFE.getInt(state + 3072 + ((value & 0xff) << 2));
    }

    private static byte[] finish(int[] state) {
        final int[] text = MAGIC.clone();
        for (int iteration = 0; iteration < 64; iteration++) {
            for (int word = 0; word < 6; word += 2) {
                int left = text[word] ^ state[P_OFFSET];
                int right = text[word + 1];
                for (int round = 1; round < 17; round += 2) {
                    right ^= feistel(state, left) ^ state[P_OFFSET + round];
                    left ^= feistel(state, right) ^ state[P_OFFSET + round + 1];
                }
                right ^= state[P_OFFSET + 17];
                text[word] = right;
                text[word + 1] = left;
            }
        }
        final byte[] output = new byte[23];
        for (int i = 0; i < 23; i++) {
            output[i] = (byte) (text[i >> 2] >>> (24 - 8 * (i & 3)));
        }
        return output;
    }

    private static int feistel(int[] state, int value) {
        return ((state[value >>> 24] + state[256 | ((value >>> 16) & 0xff)]) ^ state[512 | ((value >>> 8) & 0xff)])
                + state[768 | (value & 0xff)];
    }

    private static int[] keyWords(String password) {
        final byte[] utf8 = password.getBytes(StandardCharsets.UTF_8);
        return cyclicWords(Arrays.copyOf(utf8, Math.min(utf8.length + 1, 72)));
    }

    private static int[] cyclicWords(byte[] bytes) {
        final int[] words = new int[18];
        int index = 0;
        for (int i = 0; i < 18; i++) {
            int word = 0;
            for (int byteIndex = 0; byteIndex < 4; byteIndex++) {
                word = (word << 8) | (bytes[index] & 0xff);
                index = index + 1 == bytes.length ? 0 : index + 1;
            }
            words[i] = word;
        }
        return words;
    }

    private static int[] blowfishInitialState() {
        final int words = 18 + 1024;
        final int bits = 32 * words + 64;
        final BigInteger pi = arctanInverse(5, bits).shiftLeft(4).subtract(arctanInverse(239, bits).shiftLeft(2));
        final BigInteger fraction = pi.subtract(BigInteger.valueOf(3).shiftLeft(bits));
        final int[] digits = new int[words];
        for (int i = 0; i < words; i++) {
            digits[i] = fraction.shiftRight(bits - 32 * (i + 1)).intValue();
        }
        final int[] state = new int[STATE_SIZE];
        System.arraycopy(digits, 18, state, 0, 1024);
        System.arraycopy(digits, 0, state, P_OFFSET, 18);
        if (state[P_OFFSET] != 0x243f6a88 || state[0] != 0xd1310ba6 || state[1023] != 0x3ac372e6) {
            throw new IllegalStateException("Blowfish tables derived incorrectly");
        }
        return state;
    }

    private static BigInteger arctanInverse(int inverse, int bits) {
        final BigInteger divisor = BigInteger.valueOf(inverse);
        final BigInteger divisorSquared = BigInteger.valueOf((long) inverse * inverse);
        BigInteger term = BigInteger.ONE.shiftLeft(bits).divide(divisor);
        BigInteger sum = term;
        boolean subtract = true;
        for (long denominator = 3; term.signum() != 0; denominator += 2) {
            term = term.divide(divisorSquared);
            final BigInteger delta = term.divide(BigInteger.valueOf(denominator));
            sum = subtract ? sum.subtract(delta) : sum.add(delta);
            subtract = !subtract;
        }
        return sum;
    }

    private static void encode(byte[] data, int length, StringBuilder builder) {
        int index = 0;
        while (index < length) {
            int first = data[index++] & 0xff;
            builder.append(ALPHABET[first >>> 2]);
            first = (first & 0x03) << 4;
            if (index >= length) {
                builder.append(ALPHABET[first]);
                return;
            }
            int second = data[index++] & 0xff;
            builder.append(ALPHABET[first | (second >>> 4)]);
            first = (second & 0x0f) << 2;
            if (index >= length) {
                builder.append(ALPHABET[first]);
                return;
            }
            second = data[index++] & 0xff;
            builder.append(ALPHABET[first | (second >>> 6)]);
            builder.append(ALPHABET[second & 0x3f]);
        }
    }

    private static byte[] decode(String text, int offset, int length) {
        final byte[] output = new byte[length];
        int outputIndex = 0;
        int textIndex = offset;
        while (outputIndex < length) {
            final int first = digit(text, textIndex++);
            final int second = digit(text, textIndex++);
            if (first < 0 || second < 0) {
                return null;
            }
            output[outputIndex++] = (byte) ((first << 2) | (second >>> 4));
            if (outputIndex >= length) {
                return output;
            }
            final int third = digit(text, textIndex++);
            if (third < 0) {
                return null;
            }
            output[outputIndex++] = (byte) (((second & 0x0f) << 4) | (third >>> 2));
            if (outputIndex >= length) {
                return output;
            }
            final int fourth = digit(text, textIndex++);
            if (fourth < 0) {
                return null;
            }
            output[outputIndex++] = (byte) (((third & 0x03) << 6) | fourth);
        }
        return output;
    }

    private static int digit(String text, int index) {
        final char character = text.charAt(index);
        return character < 128 ? ALPHABET_INDEX[character] : -1;
    }

}
