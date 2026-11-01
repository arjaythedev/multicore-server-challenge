package conduit.security;

import java.math.BigInteger;

/**
 * Blowfish's initial subkeys: the P-array (18 words) and the four S-boxes (4 x 256 words) are, in that order, the
 * hexadecimal digits of the fractional part of pi (P[0] = 0x243F6A88 because pi = 3.243F6A88...). Instead of a
 * thousand-line table they are computed once at startup with Machin's formula, pi = 16 atan(1/5) - 4 atan(1/239),
 * in binary fixed point. BCrypt's startup self-test checks the result against a known hash.
 */
final class BlowfishTables {
    static final int P_WORDS = 18;
    static final int S_WORDS = 4 * 256;

    /** P-array followed by the S-boxes, as one array: the layout BCrypt's state uses. */
    static final int[] INITIAL_STATE = piFractionWords(P_WORDS + S_WORDS);

    static {
        if (INITIAL_STATE[0] != 0x243F6A88 || INITIAL_STATE[P_WORDS] != 0xD1310BA6) {
            throw new IllegalStateException("Blowfish tables computed incorrectly");
        }
    }

    private BlowfishTables() {
    }

    /** The first {@code count} 32-bit words of pi's fractional part. */
    private static int[] piFractionWords(int count) {
        int guardBits = 64;                                  // absorbs the rounding of thousands of divisions
        int fractionBits = 32 * count;
        BigInteger one = BigInteger.ONE.shiftLeft(fractionBits + guardBits);
        BigInteger pi = arctanOfInverse(5, one).shiftLeft(4).subtract(arctanOfInverse(239, one).shiftLeft(2));
        BigInteger fraction = pi.shiftRight(guardBits).subtract(BigInteger.valueOf(3).shiftLeft(fractionBits));

        int[] words = new int[count];
        for (int i = 0; i < count; i++) {
            words[i] = fraction.shiftRight(32 * (count - 1 - i)).intValue();
        }
        return words;
    }

    /** atan(1/x) = 1/x - 1/(3x^3) + 1/(5x^5) - ..., scaled by {@code one}. */
    private static BigInteger arctanOfInverse(int x, BigInteger one) {
        BigInteger xSquared = BigInteger.valueOf((long) x * x);
        BigInteger power = one.divide(BigInteger.valueOf(x));   // one / x^(2k+1)
        BigInteger sum = BigInteger.ZERO;
        for (int k = 0; power.signum() != 0; k++) {
            BigInteger term = power.divide(BigInteger.valueOf(2L * k + 1));
            sum = (k % 2 == 0) ? sum.add(term) : sum.subtract(term);
            power = power.divide(xSquared);
        }
        return sum;
    }
}
