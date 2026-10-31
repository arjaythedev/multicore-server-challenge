//! Kernel timing outside the server: thread-CPU ms per hash at cost 10 for each variant and width, the same
//! measure startup calibration uses, in interleaved rounds. Built by tools/bcbench.sh.
//! Usage: bcbench [rounds] [variant:width ...]   every candidate of `variants_shrx`, widths 4 to 8, by default
//!        bcbench --batches K variant:width       K batches of one kernel and nothing else, for `perf stat`
const std = @import("std");
const bc = @import("bcrypt.zig");

const Pick = struct { v: *const bc.Variant, n: usize, ms: [64]f64 = undefined };

fn parsePick(arg: []const u8) !Pick {
    const colon = std.mem.indexOfScalar(u8, arg, ':') orelse return error.BadPick;
    const v = bc.findVariant(arg[0..colon]) orelse return error.UnknownVariant;
    const n = try std.fmt.parseInt(usize, arg[colon + 1 ..], 10);
    if (n < 1 or n > bc.max_lanes) return error.BadWidth;
    return .{ .v = v, .n = n };
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.next();
    var picks: [64]Pick = undefined;
    var np: usize = 0;
    var rounds: usize = 5;
    var batches: ?usize = null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--batches")) {
            batches = try std.fmt.parseInt(usize, it.next() orelse return error.MissingCount, 10);
        } else if (std.mem.indexOfScalar(u8, arg, ':') != null) {
            picks[np] = try parsePick(arg);
            np += 1;
        } else rounds = try std.fmt.parseInt(usize, arg, 10);
    }
    var failure: bc.Failure = .{};
    if (batches) |k| {
        if (np != 1) return error.OnePickWithBatches;
        for (0..k) |_| _ = bc.timeWidth(picks[0].v, picks[0].n);
        return;
    }
    bc.selfTest(&bc.variants_shrx, &failure) catch |e| {
        std.debug.print("self-test failed: {s} width {d} case {d}\n", .{ failure.variant, failure.width, failure.case });
        return e;
    };
    if (np == 0) {
        for (&bc.variants_shrx) |*v| for (4..bc.max_lanes + 1) |n| {
            picks[np] = .{ .v = v, .n = n };
            np += 1;
        };
    }
    rounds = @min(rounds, 64);
    var brand_buf: [48]u8 = undefined;
    std.debug.print("{s}, {d} rounds\n", .{ bc.cpu.brand(&brand_buf), rounds });
    for (0..rounds) |r| for (picks[0..np]) |*p| {
        p.ms[r] = bc.timeWidth(p.v, p.n);
    };
    std.debug.print("{s:<10} {s:>5} {s:>8} {s:>8} {s:>8}\n", .{ "variant", "lanes", "min", "median", "max" });
    for (picks[0..np]) |*p| {
        const ms = p.ms[0..rounds];
        std.mem.sort(f64, ms, {}, lessThan);
        std.debug.print("{s:<10} {d:>5} {d:>8.3} {d:>8.3} {d:>8.3}\n", .{ p.v.name, p.n, ms[0], ms[rounds / 2], ms[rounds - 1] });
    }
}
