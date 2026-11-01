package challenge;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class JsonWriterTest {
    public static void main(String[] args) {
        JsonWriter writer = new JsonWriter();
        byte[] input = "한글\"\\\n\u0000".getBytes(StandardCharsets.UTF_8);
        writer.string(input, 0, input.length);
        String actual = new String(writer.bytes(), 0, writer.length(), StandardCharsets.UTF_8);
        if (!actual.equals("\"한글\\\"\\\\\\u000a\\u0000\"")) {
            throw new AssertionError(actual);
        }
        writer.reset();
        byte[] large = new byte[10000];
        Arrays.fill(large, (byte) 'x');
        writer.raw(large, 0, large.length);
        if (writer.length() != large.length || !Arrays.equals(large,
                Arrays.copyOf(writer.bytes(), writer.length()))) {
            throw new AssertionError("arena growth");
        }
        writer.reset();
        if (writer.length() != 0) {
            throw new AssertionError("reset");
        }
        String text = "a한🙂\ud800x\udc00";
        writer.raw(text);
        if (!Arrays.equals(text.getBytes(StandardCharsets.UTF_8),
                Arrays.copyOf(writer.bytes(), writer.length()))) {
            throw new AssertionError("UTF-8");
        }
        for (long value : new long[] {0, 1, -1, Long.MIN_VALUE, Long.MAX_VALUE}) {
            writer.reset();
            writer.number(value);
            if (!new String(writer.bytes(), 0, writer.length(), StandardCharsets.US_ASCII).equals(Long.toString(value))) {
                throw new AssertionError("number " + value);
            }
        }
    }
}
