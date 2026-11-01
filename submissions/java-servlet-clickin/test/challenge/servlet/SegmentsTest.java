package challenge.servlet;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.SplittableRandom;

public final class SegmentsTest {
    // The previous byte-at-a-time splitter, kept as the reference.
    private static int reference(Request r, int[] start, int[] end) {
        byte[] b = r.bytes();
        int p = r.pathOffset() + 1;
        int limit = r.pathOffset() + r.pathLength();
        int n = 0;
        while (p < limit) {
            if (n == start.length) {
                return -1;
            }
            int a = p;
            while (p < limit && b[p] != '/') {
                p++;
            }
            if (p == a) {
                return -1;
            }
            start[n] = a;
            end[n++] = p;
            if (p < limit && ++p == limit) {
                return -1;
            }
        }
        return n;
    }

    private static Request request(String path) {
        byte[] bytes = ("GET " + path + " HTTP/1.1\r\n\r\n").getBytes(StandardCharsets.UTF_8);
        Request r = new Request(null);
        r.data = bytes;
        r.pathStart = 4;
        r.pathEnd = 4 + path.length();
        return r;
    }

    private static void check(String path, SplittableRandom random) {
        Request r = request(path);
        int[] es = new int[6];
        int[] ee = new int[6];
        int expected = reference(r, es, ee);
        int[] start = r.segmentStarts;
        int[] end = r.segmentEnds;
        for (int k = 0; k < 6; k++) {
            start[k] = random.nextInt();
            end[k] = random.nextInt();
        }
        int actual = Container.segments(r, start, end);
        if (actual != expected) {
            throw new AssertionError(path + ": expected " + expected + ", got " + actual);
        }
        if (expected > 0 && (!Arrays.equals(es, 0, expected, start, 0, expected) || !Arrays.equals(ee, 0, expected, end, 0, expected))) {
            throw new AssertionError(path
                    + ": offsets "
                    + Arrays.toString(start)
                    + " "
                    + Arrays.toString(end)
                    + " vs "
                    + Arrays.toString(es)
                    + " "
                    + Arrays.toString(ee));
        }
    }

    public static void main(String[] args) {
        SplittableRandom random = new SplittableRandom(42);
        for (String path : new String[] {
            "/",
            "/a",
            "/a/",
            "//",
            "//a",
            "/a//b",
            "/api/tags",
            "/api/articles/how-to-train-your-dragon/comments/12",
            "/a/b/c/d/e/f",
            "/a/b/c/d/e/f/g",
            "/a/b/c/d/e/f/",
            "/abcdefg/",
            "/abcdefgh/i",
            "/a/b/c/d/",
            "/a////////b"
        }) {
            check(path, random);
        }
        char[] alphabet = {'/', '/', 'a', 'b', '-'};
        for (int i = 0; i < 300_000; i++) {
            int len = random.nextInt(48);
            StringBuilder path = new StringBuilder("/");
            for (int j = 0; j < len; j++) {
                path.append(alphabet[random.nextInt(random.nextInt(4) == 0 ? 2 : alphabet.length)]);
            }
            check(path.toString(), random);
        }
        System.out.println("challenge.servlet.SegmentsTest passed");
    }
}
