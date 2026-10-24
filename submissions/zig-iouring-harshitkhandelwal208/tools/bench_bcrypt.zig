const std = @import("std");
const bcrypt = @import("bcrypt");

pub fn main() !void {
    var jobs: [bcrypt.max_lanes]bcrypt.Job = undefined;
    for (&jobs, 0..) |*j, i| {
        j.* = .{ .password = "password123", .salt = @splat(@intCast(i + 1)), .cost = 10 };
    }
    // warm
    bcrypt.hashBatch(jobs[0..1]);
    for (1..bcrypt.max_lanes + 1) |n| {
        const t0 = nowNs();
        const reps: usize = 6;
        for (0..reps) |_| bcrypt.hashBatch(jobs[0..n]);
        const ns = nowNs() - t0;
        const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(reps * n)) / 1e6;
        std.debug.print("lanes={d}: {d:.2} ms per hash (cost 10)\n", .{ n, per });
    }
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
