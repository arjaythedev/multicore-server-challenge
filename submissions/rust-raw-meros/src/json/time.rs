//! Postgres timestamps (microseconds since 2000-01-01 UTC) as `YYYY-MM-DDTHH:MM:SS.mmmZ`.
//!
//! The calendar part is Howard Hinnant's `civil_from_days` (public domain algorithm): it works on 400-year eras
//! so leap years need no special cases. Sub-millisecond digits are truncated (floor, also before 2000), which
//! is what Go's `time.Time.Format("...000Z")` does and what the reference implementation expects.
//!
//! Range: years 0001 to 9999. Values outside are clamped to the nearest end instead of printing a five-digit
//! year (Postgres allows far wider; the application never stores such dates).

const MICROS_PER_MILLI: i64 = 1_000;
const MILLIS_PER_SEC: i64 = 1_000;
const SECS_PER_DAY: i64 = 86_400;
/// Days from 1970-01-01 to 2000-01-01.
const UNIX_TO_PG_EPOCH_DAYS: i64 = 10_957;
/// Days from 1970-01-01 to 0001-01-01 and to 9999-12-31 (the clamp range).
const MIN_DAYS_FROM_UNIX: i64 = -719_162;
const MAX_DAYS_FROM_UNIX: i64 = 2_932_896;
/// Output length: `2000-01-01T00:00:00.000Z`.
pub const TIMESTAMP_LEN: usize = 24;

/// Append the 24-byte timestamp text (without quotes) to `out`.
pub fn write_timestamp_micros(out: &mut Vec<u8>, micros_since_2000: i64) {
    let millis_total = micros_since_2000.div_euclid(MICROS_PER_MILLI);
    let secs_total = millis_total.div_euclid(MILLIS_PER_SEC);
    let (days_pg, secs_of_day) = (
        secs_total.div_euclid(SECS_PER_DAY),
        secs_total.rem_euclid(SECS_PER_DAY),
    );
    let days = days_pg + UNIX_TO_PG_EPOCH_DAYS;

    // Clamping a whole day to the range's first or last day would also clamp the time of day; use the end
    // of the range for out-of-range values so the result is a valid, ordered timestamp.
    let (days, secs_of_day, millis) = if days < MIN_DAYS_FROM_UNIX {
        (MIN_DAYS_FROM_UNIX, 0, 0)
    } else if days > MAX_DAYS_FROM_UNIX {
        (MAX_DAYS_FROM_UNIX, SECS_PER_DAY - 1, MILLIS_PER_SEC - 1)
    } else {
        (days, secs_of_day, millis_total.rem_euclid(MILLIS_PER_SEC))
    };

    let (year, month, day) = civil_from_days(days);
    let (hour, minute, second) = (secs_of_day / 3600, secs_of_day / 60 % 60, secs_of_day % 60);

    let mut text: [u8; TIMESTAMP_LEN] = *b"0000-00-00T00:00:00.000Z";
    put_digits(&mut text[0..4], year as u32);
    put_digits(&mut text[5..7], month);
    put_digits(&mut text[8..10], day);
    put_digits(&mut text[11..13], hour as u32);
    put_digits(&mut text[14..16], minute as u32);
    put_digits(&mut text[17..19], second as u32);
    put_digits(&mut text[20..23], millis as u32);
    out.extend_from_slice(&text);
}

/// Fill `dst` with `n` as zero-padded decimal (`n` must fit; callers pass calendar fields).
fn put_digits(dst: &mut [u8], mut n: u32) {
    for slot in dst.iter_mut().rev() {
        *slot = b'0' + (n % 10) as u8;
        n /= 10;
    }
}

/// (year, month 1-12, day 1-31) for a day count since 1970-01-01 in the proleptic Gregorian calendar.
fn civil_from_days(days: i64) -> (i64, u32, u32) {
    const ERA_DAYS: i64 = 146_097; // days in 400 years
    let z = days + 719_468; // shift the epoch to 0000-03-01, so the leap day is the last day of the year
    let era = z.div_euclid(ERA_DAYS);
    let day_of_era = z.rem_euclid(ERA_DAYS);
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153; // 0 = March
    let day = (day_of_year - (153 * shifted_month + 2) / 5 + 1) as u32;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    } as u32;
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fmt(micros: i64) -> String {
        let mut v = Vec::new();
        write_timestamp_micros(&mut v, micros);
        assert_eq!(v.len(), TIMESTAMP_LEN);
        String::from_utf8(v).unwrap()
    }

    /// Inverse of `civil_from_days`, written independently for the round-trip test.
    fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
        let y = if m <= 2 { y - 1 } else { y };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146_097 + doe - 719_468
    }

    const DAY_MICROS: i64 = SECS_PER_DAY * 1_000_000;

    #[test]
    fn epoch_is_2000_01_01() {
        assert_eq!(fmt(0), "2000-01-01T00:00:00.000Z");
    }

    #[test]
    fn before_2000() {
        assert_eq!(fmt(-1_000), "1999-12-31T23:59:59.999Z");
        assert_eq!(fmt(-DAY_MICROS), "1999-12-31T00:00:00.000Z");
        // 1970-01-01 is 10957 days before the Postgres epoch.
        assert_eq!(fmt(-10_957 * DAY_MICROS), "1970-01-01T00:00:00.000Z");
    }

    #[test]
    fn leap_day_2024() {
        let days = days_from_civil(2024, 2, 29) - UNIX_TO_PG_EPOCH_DAYS;
        let micros = days * DAY_MICROS + (12 * 3600 + 34 * 60 + 56) * 1_000_000 + 789_000;
        assert_eq!(fmt(micros), "2024-02-29T12:34:56.789Z");
        assert_eq!(fmt(micros + DAY_MICROS), "2024-03-01T12:34:56.789Z");
    }

    #[test]
    fn century_leap_rules() {
        let at = |y, m, d| (days_from_civil(y, m, d) - UNIX_TO_PG_EPOCH_DAYS) * DAY_MICROS;
        assert_eq!(fmt(at(2000, 2, 29)), "2000-02-29T00:00:00.000Z");
        assert_eq!(fmt(at(2100, 3, 1) - DAY_MICROS), "2100-02-28T00:00:00.000Z");
        assert_eq!(fmt(at(1900, 3, 1) - DAY_MICROS), "1900-02-28T00:00:00.000Z");
    }

    #[test]
    fn truncates_instead_of_rounding() {
        assert_eq!(fmt(999), "2000-01-01T00:00:00.000Z");
        assert_eq!(fmt(1_999), "2000-01-01T00:00:00.001Z");
        assert_eq!(fmt(999_999), "2000-01-01T00:00:00.999Z");
        // Floor for negatives: -1 microsecond is 23:59:59.999, not 00:00:00.000.
        assert_eq!(fmt(-1), "1999-12-31T23:59:59.999Z");
        assert_eq!(fmt(-1_001), "1999-12-31T23:59:59.998Z");
    }

    #[test]
    fn year_range_ends() {
        let last = (days_from_civil(9999, 12, 31) - UNIX_TO_PG_EPOCH_DAYS) * DAY_MICROS;
        assert_eq!(fmt(last + DAY_MICROS - 1), "9999-12-31T23:59:59.999Z");
        assert_eq!(fmt(last), "9999-12-31T00:00:00.000Z");
        let first = (days_from_civil(1, 1, 1) - UNIX_TO_PG_EPOCH_DAYS) * DAY_MICROS;
        assert_eq!(fmt(first), "0001-01-01T00:00:00.000Z");
        assert_eq!(fmt(first - 1), "0001-01-01T00:00:00.000Z"); // clamped
        assert_eq!(fmt(last + DAY_MICROS), "9999-12-31T23:59:59.999Z"); // clamped
        assert_eq!(fmt(i64::MAX), "9999-12-31T23:59:59.999Z");
        assert_eq!(fmt(i64::MIN), "0001-01-01T00:00:00.000Z");
    }

    #[test]
    fn range_constants_match_the_calendar() {
        assert_eq!(MIN_DAYS_FROM_UNIX, days_from_civil(1, 1, 1));
        assert_eq!(MAX_DAYS_FROM_UNIX, days_from_civil(9999, 12, 31));
    }

    #[test]
    fn every_day_round_trips() {
        for days in MIN_DAYS_FROM_UNIX..=MAX_DAYS_FROM_UNIX {
            let (y, m, d) = civil_from_days(days);
            assert_eq!(days_from_civil(y, i64::from(m), i64::from(d)), days);
        }
    }
}
