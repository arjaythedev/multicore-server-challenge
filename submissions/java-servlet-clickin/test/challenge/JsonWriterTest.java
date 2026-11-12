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
        byte[] sliced = "xxprefix\"and\\\n한\u001f suffixyy".getBytes(StandardCharsets.UTF_8);
        writer.string(sliced, 2, sliced.length - 4);
        actual = new String(writer.bytes(), 0, writer.length(), StandardCharsets.UTF_8);
        if (!actual.equals("\"prefix\\\"and\\\\\\u000a한\\u001f suffix\"")) {
            throw new AssertionError(actual);
        }
        writer.reset();
        writer.string(sliced, 2, 0);
        if (!new String(writer.bytes(), 0, writer.length(), StandardCharsets.UTF_8).equals("\"\"")) {
            throw new AssertionError("empty string");
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
        writer.string(large, 0, large.length);
        if (writer.length() != large.length + 2 || writer.bytes()[0] != '"' || writer.bytes()[writer.length() - 1] != '"'
                || !Arrays.equals(large, Arrays.copyOfRange(writer.bytes(), 1, writer.length() - 1))) {
            throw new AssertionError("large escaped string");
        }
        writer.reset();
        if (writer.length() != 0) {
            throw new AssertionError("reset");
        }
        String text = "x".repeat(12000) + "한🙂\ud800x\udc00";
        writer.raw(text);
        if (!Arrays.equals(text.getBytes(StandardCharsets.UTF_8),
                Arrays.copyOf(writer.bytes(), writer.length()))) {
            throw new AssertionError("UTF-8");
        }
        // the eight-byte scan against a byte-at-a-time reference: every byte value, at every alignment and length
        java.util.Random random = new java.util.Random(7);
        byte[] alphabet = {0, 1, 0x1f, 0x20, 0x21, '"', '#', '[', '\\', ']', 'a', 0x7f, (byte) 0x80, (byte) 0x9f, (byte) 0xa2, (byte) 0xdc, (byte) 0xff};
        for (int round = 0; round < 20000; round++) {
            byte[] b = new byte[random.nextInt(40)];
            for (int i = 0; i < b.length; i++) {
                b[i] = random.nextInt(4) == 0 ? (byte) random.nextInt(256) : alphabet[random.nextInt(alphabet.length)];
            }
            int from = b.length == 0 ? 0 : random.nextInt(b.length);
            int n = random.nextInt(b.length - from + 1);
            writer.reset();
            writer.string(b, from, n);
            byte[] expected = referenceString(b, from, n);
            if (!Arrays.equals(expected, Arrays.copyOf(writer.bytes(), writer.length()))) {
                throw new AssertionError("escape scan " + Arrays.toString(Arrays.copyOfRange(b, from, from + n)));
            }
        }
        for (long value : new long[] {0, 1, -1, Long.MIN_VALUE, Long.MAX_VALUE}) {
            writer.reset();
            writer.number(value);
            if (!new String(writer.bytes(), 0, writer.length(), StandardCharsets.US_ASCII).equals(Long.toString(value))) {
                throw new AssertionError("number " + value);
            }
        }
    }

    private static byte[] referenceString(byte[] b, int from, int n) {
        java.io.ByteArrayOutputStream out = new java.io.ByteArrayOutputStream();
        out.write('"');
        for (int i = from; i < from + n; i++) {
            int c = b[i] & 0xff;
            if (c == '"' || c == '\\') {
                out.write('\\');
                out.write(c);
            } else if (c < 0x20) {
                out.writeBytes(String.format("\\u%04x", c).getBytes(StandardCharsets.US_ASCII));
            } else {
                out.write(c);
            }
        }
        out.write('"');
        return out.toByteArray();
    }
}
