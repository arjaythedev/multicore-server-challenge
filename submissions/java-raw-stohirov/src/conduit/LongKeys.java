package conduit;

import java.util.Arrays;

/** Distinct longs in first-seen order, each with a dense index. Open addressing, no boxing. */
final class LongKeys {
    long[] list = new long[16];
    int n;
    private int[] table = new int[64]; // index + 1; 0 is empty
    private int mask = 63;

    private static int hash(long k) {
        long h = k * 0x9E3779B97F4A7C15L;
        return (int) (h ^ h >>> 32);
    }

    int idx(long k) {
        int i = hash(k) & mask;
        for (int e; (e = table[i]) != 0; i = (i + 1) & mask) if (list[e - 1] == k) return e - 1;
        if (n == list.length) list = Arrays.copyOf(list, n * 2);
        list[n] = k;
        table[i] = ++n;
        if (n * 2 > table.length) grow();
        return n - 1;
    }

    int find(long k) {
        int i = hash(k) & mask;
        for (int e; (e = table[i]) != 0; i = (i + 1) & mask) if (list[e - 1] == k) return e - 1;
        return -1;
    }

    private void grow() {
        table = new int[table.length * 2];
        mask = table.length - 1;
        for (int x = 0; x < n; x++) {
            int i = hash(list[x]) & mask;
            while (table[i] != 0) i = (i + 1) & mask;
            table[i] = x + 1;
        }
    }

    byte[] array() {
        Pg.Arr a = new Pg.Arr(Pg.INT8);
        for (int i = 0; i < n; i++) a.i64(list[i]);
        return a.done();
    }
}
