package challenge.pg;

import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class QueryTest {
    public static void main(String[] args) throws Exception {
        Query q = new Query(1, false);
        q.int4(-2)
         .int8(0x1020304050607080L)
         .bool(true)
         .text("hi")
         .nullParam()
         .textArray(new String[] {"x", "한"});
        if (q.parameterCount() != 6 || q.parameterBytes()[3] != 4) {
            throw new AssertionError("parameters");
        }
        var output = new ByteArrayOutputStream();
        var d = new DataOutputStream(output);
        d.writeShort(5);
        d.writeInt(4);
        d.writeInt(-42);
        d.writeInt(8);
        d.writeLong(-1);
        d.writeInt(1);
        d.writeByte(1);
        d.writeInt(-1);
        d.writeInt(29);
        d.writeInt(1);
        d.writeInt(0);
        d.writeInt(25);
        d.writeInt(1);
        d.writeInt(1);
        d.writeInt(5);
        d.write("hello".getBytes(StandardCharsets.UTF_8));
        byte[] data = output.toByteArray();
        q.appendRow(data, 0, data.length);
        if (q.int4At(0, 0) != -42
                || q.int8At(0, 1) != -1
                || !q.boolAt(0, 2)
                || !q.isNull(0, 3)) {
            throw new AssertionError("decode");
        }
        if (!q.timestampAt(0, 1).equals("1999-12-31T23:59:59.999Z")) {
            throw new AssertionError(q.timestampAt(0, 1));
        }
        int off = q.arrayElementOffset(0, 4, 0);
        if (q.arrayCount(0, 4) != 1 || q.arrayElementLength(off) != 5 || !Arrays.equals(Arrays.copyOfRange(q.bytes(), off, off + 5),
                "hello".getBytes(StandardCharsets.UTF_8))) {
            throw new AssertionError("array");
        }
        try {
            q.appendRow(data, 0, data.length - 1);
            throw new AssertionError("short row accepted");
        } catch (IllegalArgumentException expected) {
        }
        q.prepare(42, true);
        if (q.rowCount() != 0
                || q.parameterCount() != 0
                || q.statementId != 42
                || !q.write) {
            throw new AssertionError("prepare");
        }
        q.int8Array(new long[] {1, -2});
        byte[] expected = {
            0,
            0,
            0,
            44,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            20,
            0,
            0,
            0,
            2,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            8,
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            8,
            -1,
            -1,
            -1,
            -1,
            -1,
            -1,
            -1,
            -2
        };
        if (!Arrays.equals(Arrays.copyOf(q.parameterBytes(), q.parameterLength()),
                expected)) {
            throw new AssertionError("int8 array");
        }
        q.reset();
        byte[] utf8 = "x한y".getBytes(StandardCharsets.UTF_8);
        q.text(utf8, 1, 3);
        if (!Arrays.equals(
                Arrays.copyOf(q.parameterBytes(), q.parameterLength()),
                new byte[] {0, 0, 0, 3, utf8[1], utf8[2],
                        utf8[3]})) {
            throw new AssertionError("text slice");
        }
    }
}
