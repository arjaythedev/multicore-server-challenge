//! High-performance RFC 3339 UTC timestamp formatting for PostgreSQL timestamps.

const PG_EPOCH_SECS: i64 = 946_684_800;

/// Formats a PostgreSQL binary timestamp (microseconds since 2000-01-01 00:00:00 UTC)
/// into RFC 3339 UTC with 3 fractional digits: "YYYY-MM-DDTHH:MM:SS.mmmZ".
#[inline]
pub fn format_pg_timestamp(pg_micros: i64) -> [u8; 24] {
    let total_micros = pg_micros + (PG_EPOCH_SECS * 1_000_000);
    format_unix_micros(total_micros)
}

/// Formats Unix microseconds into RFC 3339 UTC timestamp: "YYYY-MM-DDTHH:MM:SS.mmmZ".
#[inline]
pub fn format_unix_micros(unix_micros: i64) -> [u8; 24] {
    let (secs, micros) = if unix_micros >= 0 {
        (unix_micros / 1_000_000, (unix_micros % 1_000_000) as u32)
    } else {
        let secs = (unix_micros - 999_999) / 1_000_000;
        let micros = (unix_micros - (secs * 1_000_000)) as u32;
        (secs, micros)
    };

    let millis = micros / 1000;

    let days = secs.div_euclid(86400);
    let day_secs = secs.rem_euclid(86400) as u32;

    let hour = day_secs / 3600;
    let rem = day_secs % 3600;
    let min = rem / 60;
    let sec = rem % 60;

    // Civil day algorithm
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = (z - era * 146097) as u32;
    let yoe = (doe - doe / 1024 + doe / 1461 - doe / 142401) / 365;
    let mut year = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    if month <= 2 {
        year += 1;
    }

    let mut buf = [0u8; 24];
    write_four_digits(&mut buf[0..4], year as u32);
    buf[4] = b'-';
    write_two_digits(&mut buf[5..7], month);
    buf[7] = b'-';
    write_two_digits(&mut buf[8..10], day);
    buf[10] = b'T';
    write_two_digits(&mut buf[11..13], hour);
    buf[13] = b':';
    write_two_digits(&mut buf[14..16], min);
    buf[16] = b':';
    write_two_digits(&mut buf[17..19], sec);
    buf[19] = b'.';
    write_three_digits(&mut buf[20..23], millis);
    buf[23] = b'Z';

    buf
}

#[inline(always)]
fn write_two_digits(dst: &mut [u8], val: u32) {
    dst[0] = b'0' + (val / 10) as u8;
    dst[1] = b'0' + (val % 10) as u8;
}

#[inline(always)]
fn write_three_digits(dst: &mut [u8], val: u32) {
    dst[0] = b'0' + (val / 100) as u8;
    dst[1] = b'0' + ((val / 10) % 10) as u8;
    dst[2] = b'0' + (val % 10) as u8;
}

#[inline(always)]
fn write_four_digits(dst: &mut [u8], val: u32) {
    dst[0] = b'0' + (val / 1000) as u8;
    dst[1] = b'0' + ((val / 100) % 10) as u8;
    dst[2] = b'0' + ((val / 10) % 10) as u8;
    dst[3] = b'0' + (val % 10) as u8;
}
