package challenge;

import java.lang.invoke.MethodHandles;
import java.lang.invoke.VarHandle;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;

/**
 * Branchless lookup of short ASCII words (at most 8 bytes) inside a byte
 * buffer. The masked 8-byte word is hashed into a slot table and a mismatch is
 * masked to id 0 instead of compared and jumped on. The multiplier is searched
 * at construction so the given words never collide.
 */
public final class WordTable {
    private static final VarHandle LONG = MethodHandles.byteArrayViewVarHandle(long[].class, ByteOrder.LITTLE_ENDIAN);
    private final long[] words;
    private final int[] lengths;
    private final byte[] slots;
    private final long multiplier;
    private final int shift;

    /** Ids are 1..n in argument order; 0 means "not in the table". */
    public WordTable(String... list) {
        if (list.length > 127) {
            throw new IllegalArgumentException("too many words");
        }
        words = new long[list.length + 1];
        lengths = new int[list.length + 1];
        for (int i = 0; i < list.length; i++) {
            byte[] b = list[i].getBytes(StandardCharsets.US_ASCII);
            if (b.length == 0 || b.length > 8) {
                throw new IllegalArgumentException("word must be 1..8 bytes: " + list[i]);
            }
            long w = 0;
            for (int j = 0; j < b.length; j++) {
                w |= (b[j] & 255L) << (8 * j);
            }
            words[i + 1] = w;
            lengths[i + 1] = b.length;
        }
        for (int bits = Math.max(4, 64 - Long.numberOfLeadingZeros(list.length * 4L)); ; bits++) {
            for (long m = 0x9e3779b97f4a7c15L, tries = 0;
                 tries < 100_000;
                 m += 2, tries++) {
                byte[] table = place(m, 64 - bits);
                if (table != null) {
                    slots = table;
                    multiplier = m;
                    shift = 64 - bits;
                    return;
                }
            }
        }
    }

    private byte[] place(long m, int shift) {
        byte[] table = new byte[1 << (64 - shift)];
        for (int t = 1; t < words.length; t++) {
            int h = (int) (words[t] * m >>> shift);
            if (table[h] != 0) {
                return null;
            }
            table[h] = (byte) t;
        }
        return table;
    }

    /**
     * Id of the word in b[from, to), or 0. Reads 8 bytes from {@code from},
     * clamped into the buffer.
     */
    public int id(byte[] b, int from, int to) {
        int len = to - from;
        long w = (long) LONG.get(b, Math.max(0, Math.min(from, b.length - 8))) & (-1L >>> ((8 - Math.max(1, Math.min(len, 8))) << 3));
        int t = slots[(int) (w * multiplier >>> shift)];
        long d = (words[t] ^ w) | (lengths[t] ^ len);
        return t & (int) ~((d | -d) >> 63);
    }
}
