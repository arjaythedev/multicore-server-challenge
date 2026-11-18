package challenge;

import java.util.Arrays;
import java.util.Random;

/** Every native kernel this CPU runs, at every width, against the Java kernels on random states. */
public final class NativeCostTest {
    public static void main(String[] args) {
        if (!NativeCost.AVAILABLE) {
            System.out.println("NativeCostTest: no native library, skipped");
            return;
        }
        Random random = new Random(42);
        int checked = 0;
        for (NativeCost.Kernel k : NativeCost.Kernel.values()) {
            if (!NativeCost.supports(k)) {
                continue;
            }
            for (int lanes = 1; lanes <= BCryptLanes.MAX; lanes++) {
                for (int trial = 0; trial < 3; trial++) {
                    int[][] p = new int[lanes][18];
                    int[][] s = new int[lanes][1024];
                    int[][] key = new int[lanes][18];
                    int[][] salt = new int[lanes][4];
                    for (int l = 0; l < lanes; l++) {
                        fill(random, p[l]);
                        fill(random, s[l]);
                        fill(random, key[l]);
                        fill(random, salt[l]);
                    }
                    int[][] jp = deep(p);
                    int[][] js = deep(s);
                    int[][] salt18 = new int[lanes][18];
                    for (int l = 0; l < lanes; l++) {
                        for (int i = 0; i < 18; i++) {
                            salt18[l][i] = salt[l][i & 3];
                        }
                    }
                    long rounds = 1 + trial * 3;
                    for (long r = 0; r < rounds; r++) {
                        BCryptLanes.expand(lanes, jp, js, key);
                        BCryptLanes.expand(lanes, jp, js, salt18);
                    }
                    new NativeCost().run(k, lanes, rounds, p, s, key, salt);
                    if (!Arrays.deepEquals(p, jp) || !Arrays.deepEquals(s, js)) {
                        throw new AssertionError(k + " x" + lanes + " differs from the Java kernel");
                    }
                    checked++;
                }
            }
        }
        System.out.println("NativeCostTest: " + checked + " kernel runs match");
    }

    private static void fill(Random random, int[] a) {
        for (int i = 0; i < a.length; i++) {
            a[i] = random.nextInt();
        }
    }

    private static int[][] deep(int[][] a) {
        int[][] b = new int[a.length][];
        for (int i = 0; i < a.length; i++) {
            b[i] = a[i].clone();
        }
        return b;
    }
}
