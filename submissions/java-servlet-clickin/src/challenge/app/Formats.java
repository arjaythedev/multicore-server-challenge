package challenge.app;

import challenge.JsonWriter;

public final class Formats {
    private Formats() {}

    public static String slugify(String title) {
        StringBuilder out = new StringBuilder(title.length());
        boolean separator = false;
        for (int i = 0; i < title.length(); i++) {
            char c = title.charAt(i);
            if (c >= 'A' && c <= 'Z') {
                c += 'a' - 'A';
            }
            if (c >= 'a' && c <= 'z'
                    || c >= '0' && c <= '9') {
                if (separator && !out.isEmpty()) {
                    out.append('-');
                }
                out.append(c);
                separator = false;
            } else {
                separator = true;
            }
        }
        return out.toString();
    }

    /**
     * Writes a quoted UTC timestamp, truncating PostgreSQL microseconds to
     * milliseconds.
     */
    public static void timestamp(JsonWriter out, long micros) {
        long millis = Math.floorDiv(micros, 1000) + 946684800000L;
        long days = Math.floorDiv(millis, 86400000L);
        int ms = (int) Math.floorMod(millis, 86400000L);
        long z = days + 719468;
        long era = Math.floorDiv(z, 146097);
        int doe = (int) (z - era * 146097);
        int yoe = (doe
                - doe / 1460
                + doe / 36524
                - doe / 146096)
                / 365;
        long year = yoe + era * 400;
        int doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        int mp = (5 * doy + 2) / 153;
        int day = doy - (153 * mp + 2) / 5 + 1;
        int month = mp + (mp < 10 ? 3 : -9);
        if (month <= 2) {
            year++;
        }
        if (year < 0 || year > 9999) {
            throw new IllegalArgumentException("timestamp year outside four digits");
        }
        out.put('"');
        digits(out, (int) year, 4);
        out.put('-');
        digits(out, month, 2);
        out.put('-');
        digits(out, day, 2);
        out.put('T');
        digits(out, ms / 3600000, 2);
        out.put(':');
        digits(out, ms / 60000 % 60, 2);
        out.put(':');
        digits(out, ms / 1000 % 60, 2);
        out.put('.');
        digits(out, ms % 1000, 3);
        out.put('Z');
        out.put('"');
    }

    private static void digits(JsonWriter out, int value, int width) {
        int divisor = 1;
        for (int i = 1; i < width; i++) {
            divisor *= 10;
        }
        while (divisor > 0) {
            out.put('0' + value / divisor % 10);
            divisor /= 10;
        }
    }
}
