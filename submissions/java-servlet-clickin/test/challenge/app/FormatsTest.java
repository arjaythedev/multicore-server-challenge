package challenge.app;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Random;

import challenge.JsonWriter;

public final class FormatsTest {
    public static void main(String[] args) {
        slug("  Conformance -- Renamed Title!  ", "conformance-renamed-title");
        slug("Aé中🙂B", "a-b");
        slug("---é_", "");
        slug("A1b2", "a1b2");
        timestamp(0, "2000-01-01T00:00:00.000Z");
        timestamp(-1, "1999-12-31T23:59:59.999Z");
        timestamp(1234567, "2000-01-01T00:00:01.234Z");
        DateTimeFormatter formatter = DateTimeFormatter.ofPattern("uuuu-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC);
        Random random = new Random(0);
        for (int i = 0; i < 10000; i++) {
            long micros = random.nextLong(-63082281600000000L, 252455616000000000L);
            Instant instant = Instant.ofEpochSecond(Math.floorDiv(micros, 1000000) + 946684800L, Math.floorMod(micros, 1000000) * 1000);
            timestamp(micros, formatter.format(instant));
        }
    }

    private static void slug(String input, String expected) {
        String actual = Formats.slugify(input);
        if (!actual.equals(expected)) {
            throw new AssertionError(actual + " != " + expected);
        }
    }

    private static void timestamp(long micros, String expected) {
        JsonWriter out = new JsonWriter();
        Formats.timestamp(out, micros);
        String actual = new String(out.bytes(), 0, out.length(), StandardCharsets.UTF_8);
        if (!actual.equals('"' + expected + '"')) {
            throw new AssertionError(actual + " != " + expected);
        }
    }
}
