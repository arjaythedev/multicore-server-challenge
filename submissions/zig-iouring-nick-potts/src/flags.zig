//! Start-time flags, from one environment variable: CONDUIT_FLAGS, a comma-separated list of `name=on|off`. Unset
//! or empty, every flag keeps its default. main.zig reads it once before forking and runs the server built for that
//! combination: each combination is its own comptime-specialised copy of the code a flag reaches, so nothing on the
//! request path tests a flag.
const std = @import("std");

pub const Flags = struct {
    /// Overload shedding (shed.zig): while the CPU is saturated (a second below 3% idle, hasher CPU counted as idle)
    /// refuse sign-ups and logins with an immediate 503.
    shed: bool = false,
    /// Delayed ACK: each sent response puts its socket back in delayed-ACK mode (TCP_QUICKACK off), so the next
    /// request's ACK leaves with its response instead of alone.
    ackdelay: bool = true,
    /// gzip (pz.zig, a fixed code table) for responses that need 3+ TCP segments, when the client accepts it and
    /// it saves a segment: fewer segments draw fewer client ACKs on the receive CPU.
    gzip: bool = true,
};

const names = std.meta.fieldNames(Flags);

/// Every flag's name, for messages.
pub const known = blk: {
    var s: []const u8 = "";
    for (names, 0..) |name, i| s = s ++ (if (i == 0) "" else ", ") ++ name;
    break :blk s;
};

pub const Error = error{ UnknownFlag, BadValue };

/// Parses CONDUIT_FLAGS. On an error, `bad` is the unknown name or the entry with a bad value.
pub fn parse(text: []const u8, bad: *[]const u8) Error!Flags {
    var f: Flags = .{};
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " ");
        if (entry.len == 0) continue;
        bad.* = entry;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.BadValue;
        const value = entry[eq + 1 ..];
        const on = if (std.mem.eql(u8, value, "on")) true else if (std.mem.eql(u8, value, "off")) false else return error.BadValue;
        inline for (names) |name| {
            if (std.mem.eql(u8, entry[0..eq], name)) {
                @field(f, name) = on;
                break;
            }
        } else {
            bad.* = entry[0..eq];
            return error.UnknownFlag;
        }
    }
    return f;
}

/// "shed=on" and so on, every flag in declaration order.
pub fn format(f: Flags, out: []u8) []const u8 {
    var n: usize = 0;
    inline for (names, 0..) |name, i| {
        const s = (if (i == 0) "" else ",") ++ name ++ "=";
        const v = if (@field(f, name)) "on" else "off";
        @memcpy(out[n..][0..s.len], s);
        n += s.len;
        @memcpy(out[n..][0..v.len], v);
        n += v.len;
    }
    return out[0..n];
}

/// Calls `func(F, args...)` with `F` equal to `f` but comptime-known.
pub fn dispatch(f: Flags, comptime func: anytype, args: anytype) void {
    inline for (0..1 << names.len) |mask| {
        const c = comptime fromMask(mask);
        if (std.meta.eql(c, f)) return @call(.auto, func, .{c} ++ args);
    }
    unreachable;
}

fn fromMask(mask: usize) Flags {
    var f: Flags = undefined;
    for (names, 0..) |name, i| @field(f, name) = mask >> @intCast(i) & 1 == 1;
    return f;
}

const testing = std.testing;

test "defaults, overrides, and the errors that stop the server" {
    var bad: []const u8 = "";
    try testing.expectEqual(Flags{}, try parse("", &bad));
    try testing.expectEqual(Flags{ .shed = true }, try parse("shed=on", &bad));
    try testing.expectEqual(Flags{ .shed = true }, try parse(" shed=off , shed=on,", &bad));
    try testing.expectEqual(Flags{ .ackdelay = false }, try parse("ackdelay=off", &bad));
    try testing.expectError(error.UnknownFlag, parse("shed=on,sheds=off", &bad));
    try testing.expectEqualStrings("sheds", bad);
    try testing.expectError(error.BadValue, parse("shed=yes", &bad));
    try testing.expectError(error.BadValue, parse("shed", &bad));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("shed=off,ackdelay=on,gzip=on", format(.{}, &buf));
}

test "dispatch passes the runtime flags as a comptime value" {
    const Probe = struct {
        var got: ?bool = null;
        fn run(comptime F: Flags, x: u8) void {
            if (x != 7) return;
            got = comptime F.shed;
        }
    };
    dispatch(.{ .shed = false }, Probe.run, .{@as(u8, 7)});
    try testing.expectEqual(false, Probe.got);
    dispatch(.{ .shed = true }, Probe.run, .{@as(u8, 7)});
    try testing.expectEqual(true, Probe.got);
}
