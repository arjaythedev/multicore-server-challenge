const std = @import("std");
const builtin = @import("builtin");
const lanes = @import("bcrypt_lanes");
const total = 60;

fn sample(io: std.Io, comptime width: usize, comptime scalar: bool, trial: usize) void {
    var checksum: u8 = 0;
    const start = std.Io.Clock.awake.now(io).toMilliseconds();
    var index: usize = 0;
    while (index < total) : (index += width) {
        var buffers: [width][24]u8 = undefined;
        var passwords: [width][]const u8 = undefined;
        var salts: [width][16]u8 = undefined;
        inline for (0..width) |lane| {
            for (&buffers[lane], 0..) |*byte, position| byte.* = @intCast(33 + (position + index + lane + trial) % 90);
            passwords[lane] = buffers[lane][0 .. 12 + (index + lane) % 13];
            for (&salts[lane], 0..) |*byte, position| byte.* = @truncate(position * 29 + (index + lane) * 71 + trial * 17);
        }
        const digests = if (scalar) [1][23]u8{std.crypto.pwhash.bcrypt.bcrypt(passwords[0], &salts[0], .{ .rounds_log = 10, .silently_truncate_password = true })} else lanes.derive(width, passwords, salts, 10);
        for (digests) |digest| checksum ^= digest[0];
        std.mem.doNotOptimizeAway(&digests);
    }
    const milliseconds = std.Io.Clock.awake.now(io).toMilliseconds() - start;
    const per_hash = @as(f64, @floatFromInt(milliseconds)) / total;
    std.debug.print("{{\"variant\":\"{s}\",\"width\":{d},\"trial\":{d},\"cost\":10,\"hashes\":{d},\"wall_ms_per_hash\":{d:.3},\"checksum\":{d}}}\n", .{ if (scalar) "stdlib" else "lanes", width, trial, total, per_hash, checksum });
}

pub fn main(init: std.process.Init) void {
    if (builtin.mode != .fast) @panic("use -Doptimize=ReleaseFast for password measurements");
    std.debug.print("{{\"architecture\":\"{s}\",\"scope\":\"Single-thread cost-ten CPU comparison, not server capacity\"}}\n", .{@tagName(builtin.cpu.arch)});
    for (0..3) |trial| {
        if (trial % 2 == 0) {
            sample(init.io, 1, true, trial);
            sample(init.io, 1, false, trial);
            sample(init.io, 2, false, trial);
            sample(init.io, 3, false, trial);
            sample(init.io, 4, false, trial);
            sample(init.io, 5, false, trial);
            sample(init.io, 6, false, trial);
        } else {
            sample(init.io, 6, false, trial);
            sample(init.io, 5, false, trial);
            sample(init.io, 4, false, trial);
            sample(init.io, 3, false, trial);
            sample(init.io, 2, false, trial);
            sample(init.io, 1, false, trial);
            sample(init.io, 1, true, trial);
        }
    }
}
