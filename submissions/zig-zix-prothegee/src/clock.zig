//! Wall clock helpers.

const std = @import("std");

// --------------------------------------------------------- //

/// Unix seconds from the realtime clock.
pub fn unixSeconds(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toSeconds();
}

// --------------------------------------------------------- //

test "clock: unix seconds is past 2024" {
    const io = std.testing.io;

    try std.testing.expect(unixSeconds(io) > 1_700_000_000);
}

test "clock: two calls do not go backwards" {
    const io = std.testing.io;

    const first = unixSeconds(io);
    const second = unixSeconds(io);

    try std.testing.expect(second >= first);
}
