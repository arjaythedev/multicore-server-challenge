package conduit.json;

import io.netty.buffer.ByteBuf;

/** Formats Postgres timestamps as "yyyy-MM-ddTHH:mm:ss.SSSZ" (UTC, milliseconds truncated) without java.time. */
final class Timestamps {
    /** Days from 1970-01-01 to 2000-01-01, the epoch of Postgres's binary timestamps. */
    private static final long DAYS_1970_TO_2000 = 10_957;
    private static final long MICROS_PER_DAY = 86_400_000_000L;

    private Timestamps() {
    }

    static void writeIso(ByteBuf out, long microsSince2000) {
        long days = Math.floorDiv(microsSince2000, MICROS_PER_DAY);
        long microsOfDay = microsSince2000 - days * MICROS_PER_DAY;
        long millisOfDay = microsOfDay / 1000;                 // truncate, never round
        int hour = (int) (millisOfDay / 3_600_000);
        int minute = (int) (millisOfDay / 60_000 % 60);
        int second = (int) (millisOfDay / 1000 % 60);
        int milli = (int) (millisOfDay % 1000);

        // civil date from days since 1970-01-01 (Howard Hinnant's days_from_civil, inverted)
        long z = days + DAYS_1970_TO_2000 + 719_468;
        long era = Math.floorDiv(z, 146_097);
        long dayOfEra = z - era * 146_097;
        long yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365;
        long dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100);
        long monthIndex = (5 * dayOfYear + 2) / 153;                      // March = 0
        int day = (int) (dayOfYear - (153 * monthIndex + 2) / 5 + 1);
        int month = (int) (monthIndex < 10 ? monthIndex + 3 : monthIndex - 9);
        long year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0);

        digits(out, (int) year, 4);
        out.writeByte('-');
        digits(out, month, 2);
        out.writeByte('-');
        digits(out, day, 2);
        out.writeByte('T');
        digits(out, hour, 2);
        out.writeByte(':');
        digits(out, minute, 2);
        out.writeByte(':');
        digits(out, second, 2);
        out.writeByte('.');
        digits(out, milli, 3);
        out.writeByte('Z');
    }

    private static void digits(ByteBuf out, int value, int width) {
        int divisor = 1;
        for (int i = 1; i < width; i++) divisor *= 10;
        for (; divisor > 0; divisor /= 10) out.writeByte('0' + value / divisor % 10);
    }
}
