package conduit;

import java.util.Arrays;

/** Distinct pairs of longs in first-seen order, each with a dense index. Open addressing, no boxing. */
final class PairKeys {
    long[] a = new long[16], b = new long[16];
    int n;
    private int[] table = new int[64]; // index + 1; 0 is empty
    private int mask = 63;

    private static int hash(long x, long y) {
        long h = (x * 0x9E3779B97F4A7C15L ^ y) * 0xC2B2AE3D27D4EB4FL;
        return (int) (h ^ h >>> 32);
    }

    int idx(long x, long y) {
        int i = hash(x, y) & mask;
        for (int e; (e = table[i]) != 0; i = (i + 1) & mask) if (a[e - 1] == x && b[e - 1] == y) return e - 1;
        if (n == a.length) {
            a = Arrays.copyOf(a, n * 2);
            b = Arrays.copyOf(b, n * 2);
        }
        a[n] = x;
        b[n] = y;
        table[i] = ++n;
        if (n * 2 > table.length) grow();
        return n - 1;
    }

    int find(long x, long y) {
        int i = hash(x, y) & mask;
        for (int e; (e = table[i]) != 0; i = (i + 1) & mask) if (a[e - 1] == x && b[e - 1] == y) return e - 1;
        return -1;
    }

    private void grow() {
        table = new int[table.length * 2];
        mask = table.length - 1;
        for (int x = 0; x < n; x++) {
            int i = hash(a[x], b[x]) & mask;
            while (table[i] != 0) i = (i + 1) & mask;
            table[i] = x + 1;
        }
    }
}
