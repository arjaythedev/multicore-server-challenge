//! Timestamps as the API writes them: RFC 3339 in UTC with exactly three
//! fractional digits, truncated: `2025-04-01T12:00:00.000Z`. Postgres sends
//! a timestamptz in binary as microseconds since 2000-01-01T00:00:00Z.

const std = @import("std");
const assert = std.debug.assert;

pub const text_bytes = "2025-04-01T12:00:00.000Z".len;

/// Days from 1970-01-01 to 2000-01-01.
const epoch_2000_days = 10957;

pub fn format(microseconds_since_2000: i64, out: *[text_bytes]u8) void {
    const milliseconds = @divFloor(microseconds_since_2000, 1000);
    const seconds = @divFloor(milliseconds, 1000);
    const millisecond: u32 = @intCast(@mod(milliseconds, 1000));
    const days = @divFloor(seconds, 86400) + epoch_2000_days;
    const second_of_day: u32 = @intCast(@mod(seconds, 86400));
    const civil = civil_from_days(days);
    assert(civil.year >= 0 and civil.year <= 9999);
    write_digits(out[0..4], @intCast(civil.year));
    out[4] = '-';
    write_digits(out[5..7], civil.month);
    out[7] = '-';
    write_digits(out[8..10], civil.day);
    out[10] = 'T';
    write_digits(out[11..13], second_of_day / 3600);
    out[13] = ':';
    write_digits(out[14..16], second_of_day / 60 % 60);
    out[16] = ':';
    write_digits(out[17..19], second_of_day % 60);
    out[19] = '.';
    write_digits(out[20..23], millisecond);
    out[23] = 'Z';
}

fn write_digits(out: []u8, value: u32) void {
    var rest = value;
    var index = out.len;
    for (0..out.len) |_| {
        index -= 1;
        out[index] = @intCast('0' + rest % 10);
        rest /= 10;
    }
    assert(rest == 0);
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// Howard Hinnant's `civil_from_days`: days since 1970-01-01 to a date of
/// the proleptic Gregorian calendar.
fn civil_from_days(days_since_1970: i64) Civil {
    const z = days_since_1970 + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year = yoe + era * 400 + @intFromBool(month <= 2);
    return .{ .year = year, .month = month, .day = day };
}

test "time: microseconds since 2000 as the API's text" {
    var out: [text_bytes]u8 = undefined;
    format(0, &out);
    try std.testing.expectEqualStrings("2000-01-01T00:00:00.000Z", &out);
    // 2025-04-01T12:00:00.123999Z: truncated, not rounded.
    format(796_824_000_123_999, &out);
    try std.testing.expectEqualStrings("2025-04-01T12:00:00.123Z", &out);
    format(-1, &out);
    try std.testing.expectEqualStrings("1999-12-31T23:59:59.999Z", &out);
    // 2024-02-29T23:59:59.000Z: a leap day.
    format(762_566_399_000_000, &out);
    try std.testing.expectEqualStrings("2024-02-29T23:59:59.000Z", &out);
}
